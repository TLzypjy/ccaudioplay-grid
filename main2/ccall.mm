/**
 * CCAudioPlayAllLayout — 让"自定义位置/字体"功能支持全部 5 种模块
 *
 * 背景: 原插件只在 3x2 (type==2) 的布局代码里应用自定义 frame/字体,
 *       2x2/2x3/4x2/4x3 四种布局完全没读这套设置 (isEnableCustomFrame /
 *       iconFrame / titleFrame / ... / titleFont 等, 存于 com.thefool.ccaudioplaypres)。
 *       运行时 CCCustomView 在加载配置后会把解析好的值放进同名属性
 *       (iconFrame 等均有 getter, 见逆向), 但只有 3x2 路径把它画出来。
 *
 * 原理: swizzle -[CCCustomView layoutSubviews] (该方法为静态注册, 可稳定挂钩;
 *       五个 layoutSubviews2x2/2x3/4x2/4x3 是运行时解包注册的, 无法静态挂):
 *       原始布局跑完后, 若 type != 2 且启用自定义, 把 9 个 frame 属性 + 4 个字体
 *       直接应用到对应视图上。frame 全零视为"未设置该项", 跳过不动。
 *       所有取值/取视图均走 KVC + @try, 任一环失败只跳过该元素, 绝不崩 CC。
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*ccal_orig_layoutSubviews)(id, SEL) = NULL;
static int ccal_install_tries = 0;
static char _ccp_sig_key = 0;   // 防拉锯: 每实例记录上次应用的存储值签名

// 快照预览: 最近的真实 CCCustomView (SpringBoard 侧) + 采集端前向声明

// ---------- 调试日志: /var/mobile/Documents/ccall_debug.log ----------
static void CCALLLog(NSString *line) {
    @try {
        NSString *p = @"/var/mobile/Documents/ccall_debug.log";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        NSMutableString *existing = nil;
        unsigned long long sz = [attr fileSize];
        if (sz > 0 && sz < 100000) {
            existing = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        }
        NSMutableString *next = existing ?: [NSMutableString string];
        [next appendFormat:@"[%@] %@\n", [NSDate date], line];
        [next writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

static BOOL cc_did_dump_prefs = NO;
static int cc_last_type = -999;
static BOOL cc_last_en = NO;
static NSMutableSet *cc_logged_fails = nil;

static void CCALLLogOnce(NSString *key, NSString *line) {
    @try {
        if (!cc_logged_fails) cc_logged_fails = [NSMutableSet set];
        if ([cc_logged_fails containsObject:key]) return;
        [cc_logged_fails addObject:key];
        CCALLLog(line);
    } @catch (id e) {}
}

static void CCALLApplyToFrame(UIView *npv, NSString *frameKey, NSString *viewKey, id self) {    @try {
        NSValue *fv = [self valueForKey:frameKey];
        if (!fv) { CCALLLogOnce([@"nf" stringByAppendingString:frameKey], [NSString stringWithFormat:@"%@: frame ivar nil", frameKey]); return; }
        CGRect fr = [fv CGRectValue];
        if (fr.origin.x == 0 && fr.origin.y == 0 && fr.size.width == 0 && fr.size.height == 0) {
            return;
        }
        UIView *v = [npv valueForKey:viewKey];
        if ([v isKindOfClass:[UIView class]]) {
            // 关键防卡顿: 只有 frame 真的变化才写入。
            // 每次布局都 setFrame 会触发下一次布局 -> 无限布局循环把整机拖卡 (v122 教训)。
            CGRect cur = [v frame];
            if (CGRectEqualToRect(cur, fr)) return;
            [v setFrame:fr];
            CCALLLogOnce([@"ok" stringByAppendingString:frameKey],
                [NSString stringWithFormat:@"%@ -> %@ ok fr=%@", frameKey, viewKey, NSStringFromCGRect(fr)]);
        } else {
            CCALLLogOnce([@"miss" stringByAppendingString:frameKey],
                [NSString stringWithFormat:@"%@: KVC %@ -> %@ (not UIView)", frameKey, viewKey, v]);
        }
    } @catch (id e) {
        CCALLLogOnce([@"exc" stringByAppendingString:frameKey],
            [NSString stringWithFormat:@"%@: KVC exception %@", frameKey, e]);
    }
}

static void CCALLApplyFont(UILabel *lab, NSString *fontKey, id self) {
    @try {
        if (!lab) return;
        double fs = [[self valueForKey:fontKey] doubleValue];
        if (fs >= 4.0 && fs <= 30.0) {
            if (fabs([lab font].pointSize - fs) > 0.01) [lab setFont:[UIFont systemFontOfSize:fs]];
        }
    } @catch (id e) {}
}

// ---- 真机信息导出 (供设置页预览对齐): 模块 bounds + 各元素实际 frame + 正在播放信息 ----
static NSString *ccp_lastBoundsStr = nil;
static NSString *ccp_lastFramesStr = nil;
static double ccp_lastNowFetch = 0;

static void CCPExportNowPlaying(void) {
    @try {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!mr) return;
        void (*MRGNI)(dispatch_queue_t, void (^)(CFDictionaryRef)) =
            (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        if (!MRGNI) return;
        MRGNI(dispatch_get_global_queue(0, 0), ^(CFDictionaryRef info) {
            @try {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                UIImage *art = nil;
                if (info) {
                    NSDictionary *d = (__bridge NSDictionary *)info;
                    NSString *t = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoTitle"];
                    NSString *a = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtist"];
                    double e = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                    double du = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
                    NSData *ad = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([t length]) out[@"title"] = t;
                    if ([a length]) out[@"artist"] = a;
                    out[@"elapsed"] = @(e);
                    out[@"duration"] = @(du);
                    if (ad) art = [UIImage imageWithData:ad];
                }
                [out writeToFile:@"/var/mobile/Documents/ccnow.plist" atomically:YES];
                if (art) {
                    NSData *png = UIImagePNGRepresentation(art);
                    if (png) [png writeToFile:@"/var/mobile/Documents/ccart.png" atomically:YES];
                }
            } @catch (id e) {}
        });
    } @catch (id e) {}
}

static void CCALLApply(id self) {
    @try {
        // 真机模块 bounds 导出 (设置页预览按真实尺寸对齐); 变化时才写
        NSString *bs = NSStringFromCGRect([(UIView *)self bounds]);
        if (![bs isEqualToString:ccp_lastBoundsStr]) {
            ccp_lastBoundsStr = bs;
            [bs writeToFile:@"/var/mobile/Documents/ccbounds.txt" atomically:YES];
            double now = [NSDate date].timeIntervalSince1970;
            if (now - ccp_lastNowFetch > 5.0) {
                ccp_lastNowFetch = now;
                CCPExportNowPlaying();
            }
        }

        // 真机各元素实际 frame 导出 (设置页预览 WYSIWYG 对齐; npv 内部元素换算到模块坐标系)
        @try {
            NSMutableDictionary *rf = [NSMutableDictionary dictionary];
            [rf setObject:bs forKey:@"bounds"];
            UIView *iv = [self valueForKey:@"playingIconView"];
            if ([iv isKindOfClass:[UIView class]]) [rf setObject:NSStringFromCGRect([iv frame]) forKey:@"icon"];
            UILabel *el = [self valueForKey:@"elapsedTitleLabel"];
            if ([el isKindOfClass:[UIView class]]) [rf setObject:NSStringFromCGRect([el frame]) forKey:@"elapsed"];
            UILabel *dl = [self valueForKey:@"durationTitleLabel"];
            if ([dl isKindOfClass:[UIView class]]) [rf setObject:NSStringFromCGRect([dl frame]) forKey:@"duration"];
            UIView *pv = [self valueForKey:@"progressView"];
            if ([pv isKindOfClass:[UIView class]]) [rf setObject:NSStringFromCGRect([pv frame]) forKey:@"progress"];
            UIView *npv = [self valueForKey:@"nowPlayingView"];
            if ([npv isKindOfClass:[UIView class]]) {
                CGPoint no = [(UIView *)npv frame].origin;
                NSArray *pairs = @[@[@"titleMarqueeView", @"title"], @[@"subtitleMarqueeView", @"subtitle"],
                                   @[@"leftButton", @"left"], @[@"centerButton", @"center"], @[@"rightButton", @"right"]];
                for (NSArray *pr in pairs) {
                    @try {
                        UIView *sv = [npv valueForKey:pr[0]];
                        if ([sv isKindOfClass:[UIView class]]) {
                            CGRect f = [sv frame];
                            [rf setObject:NSStringFromCGRect(CGRectMake(no.x + f.origin.x, no.y + f.origin.y, f.size.width, f.size.height))
                                   forKey:pr[1]];
                        }
                    } @catch (id e) {}
                }
            }
            NSString *ser = [NSString stringWithFormat:@"%@", rf];
            if (![ser isEqualToString:ccp_lastFramesStr]) {
                ccp_lastFramesStr = ser;
                [rf writeToFile:@"/var/mobile/Documents/ccreal_frames.plist" atomically:YES];
            }
        } @catch (id e) {}

        // 3x2 由原实现自己处理
        int type = [[self valueForKey:@"type"] intValue];
        BOOL en = [[self valueForKey:@"IsEnableCustomFrame"] boolValue];
        if (type != cc_last_type || en != cc_last_en) {
            cc_last_type = type;
            cc_last_en = en;
            CCALLLog([NSString stringWithFormat:@"layout pass: type=%d custom=%d", type, en]);
            CCALLLog([NSString stringWithFormat:@"ivars icon=%@ title=%@ sub=%@ elapsed=%@ dur=%@ progress=%@ left=%@ center=%@ right=%@",
                      [self valueForKey:@"iconFrame"], [self valueForKey:@"titleFrame"],
                      [self valueForKey:@"subTitleFrame"], [self valueForKey:@"elapsedTitleFrame"],
                      [self valueForKey:@"durationTitleFrame"], [self valueForKey:@"progressFrame"],
                      [self valueForKey:@"leftButtonFrame"], [self valueForKey:@"centerButtonFrame"],
                      [self valueForKey:@"rightButtonFrame"]]);
            if (!cc_did_dump_prefs) {
                cc_did_dump_prefs = YES;
                NSDictionary *pd = [NSDictionary dictionaryWithContentsOfFile:
                    @"/var/mobile/Library/Preferences/com.thefool.ccaudioplaypres.plist"];
                if (pd) {
                    CCALLLog([NSString stringWithFormat:@"prefs keys: %@", [pd allKeys]]);
                    for (NSString *k in @[@"isEnableCustomFrame", @"iconFrame", @"titleFrame",
                                          @"subTitleFrame", @"elapsedTitleFrame", @"durationTitleFrame",
                                          @"progressFrame", @"leftButtonFrame", @"centerButtonFrame",
                                          @"rightButtonFrame", @"titleFont", @"subtitleFont"]) {
                        CCALLLog([NSString stringWithFormat:@"prefs[%@] = %@ (class %@)",
                                  k, [pd objectForKey:k] ?: @"<nil>",
                                  [[pd objectForKey:k] class]]);
                    }
                } else {
                    CCALLLog(@"prefs file MISSING at /var/mobile/Library/Preferences/com.thefool.ccaudioplaypres.plist");
                }
            }
        }
        if (type == 2) return;   // 3x2 由原实现自己处理
        if (!en) return;

        // 防拉锯 (v122 卡顿根因): 原版布局每轮写它的缩放值, 我们再覆盖成存储值点数,
        // 互相触发布局 -> 无限拉锯。存储值没变化就不再写, 拉锯自然停止。
        NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|t%d",
            [self valueForKey:@"iconFrame"], [self valueForKey:@"titleFrame"],
            [self valueForKey:@"subTitleFrame"], [self valueForKey:@"elapsedTitleFrame"],
            [self valueForKey:@"durationTitleFrame"], [self valueForKey:@"progressFrame"],
            [self valueForKey:@"leftButtonFrame"], [self valueForKey:@"centerButtonFrame"],
            [self valueForKey:@"rightButtonFrame"], (int)type];
        NSString *lastSig = objc_getAssociatedObject(self, &_ccp_sig_key);
        if ([sig isEqualToString:lastSig]) return;
        objc_setAssociatedObject(self, &_ccp_sig_key, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // ---- 直属元素 (CCCustomView 自己的属性) ----
        NSDictionary *direct = @{
            @"iconFrame"         : @"playingIconView",
            @"elapsedTitleFrame" : @"elapsedTitleLabel",
            @"durationTitleFrame": @"durationTitleLabel",
            @"progressFrame"     : @"progressView",
        };
        for (NSString *fk in direct) {
            CCALLApplyToFrame(self, fk, direct[fk], self);
        }
        // 自定义进度条容器跟随进度条框
        @try {
            NSValue *pf = [self valueForKey:@"progressFrame"];
            UIView *pcv = [self valueForKey:@"progressCustomView"];
            if (pf && pcv) {
                CGRect fr = [pf CGRectValue];
                if (fr.size.width > 0 && fr.size.height > 0 && !CGRectEqualToRect([pcv frame], fr)) {
                    [pcv setFrame:fr];
                }
            }
        } @catch (id e) {}

        // ---- 系统播放视图内部元素 (歌词/歌曲/三个按钮) ----
        UIView *npv = [self valueForKey:@"nowPlayingView"];
        if ([npv isKindOfClass:[UIView class]]) {
            CCALLApplyToFrame(npv, @"titleFrame",        @"titleMarqueeView",      self);
            CCALLApplyToFrame(npv, @"subTitleFrame",     @"subtitleMarqueeView",   self);
            CCALLApplyToFrame(npv, @"leftButtonFrame",   @"leftButton",            self);
            CCALLApplyToFrame(npv, @"centerButtonFrame", @"centerButton",          self);
            CCALLApplyToFrame(npv, @"rightButtonFrame",  @"rightButton",           self);

            // 字体 (跑马灯内部的 label)
            @try {
                double fs = [[self valueForKey:@"titleFont"] doubleValue];
                UILabel *lab = [[npv valueForKey:@"titleMarqueeView"] valueForKey:@"label"];
                if (lab && fs >= 4.0 && fs <= 30.0) [lab setFont:[UIFont systemFontOfSize:fs]];
            } @catch (id e) {}
            @try {
                double fs = [[self valueForKey:@"subtitleFont"] doubleValue];
                UILabel *lab = [[npv valueForKey:@"subtitleMarqueeView"] valueForKey:@"label"];
                if (lab && fs >= 4.0 && fs <= 30.0) [lab setFont:[UIFont systemFontOfSize:fs]];
            } @catch (id e) {}
        }

        // ---- 两个时间标签字体 ----
        CCALLApplyFont([self valueForKey:@"elapsedTitleLabel"],  @"elapsedTitleFont",  self);
        CCALLApplyFont([self valueForKey:@"durationTitleLabel"], @"durationTitleFont", self);
    } @catch (id e) {}
}

static void CCALLLayoutSubviews(id self, SEL _cmd) {
    if (ccal_orig_layoutSubviews) ccal_orig_layoutSubviews(self, _cmd);
    CCALLApply(self);
}

static void CCALLTryInstall(void) {
    @try {
        Class c = objc_getClass("CCCustomView");
        if (!c) {
            CCALLLogOnce(@"noClass", @"install: CCCustomView class not found yet");
            return;
        }
        Method m = class_getInstanceMethod(c, sel_registerName("layoutSubviews"));
        if (!m) {
            CCALLLogOnce(@"noMethod", @"install: layoutSubviews method missing");
            return;
        }
        if (method_getImplementation(m) == (IMP)CCALLLayoutSubviews) return;  // 已装
        ccal_orig_layoutSubviews = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)CCALLLayoutSubviews);
        CCALLLog([NSString stringWithFormat:@"hook installed on -[CCCustomView layoutSubviews], orig=%p", (void *)ccal_orig_layoutSubviews]);
    } @catch (id e) {}
}

static void CCALLRetry(void) {
    CCALLTryInstall();
    if (!ccal_orig_layoutSubviews && ccal_install_tries < 120) {
        ccal_install_tries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CCALLRetry();
        });
    }
}

@interface CCALLBootstrap : NSObject
@end
@implementation CCALLBootstrap
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCALLRetry();
    });
}
@end
