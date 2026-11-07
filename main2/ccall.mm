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
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*ccal_orig_layoutSubviews)(id, SEL) = NULL;
static int ccal_install_tries = 0;

// 快照预览: 最近的真实 CCCustomView (SpringBoard 侧) + 采集端前向声明
@class CCPCapture;
static __weak UIView *ccp_lastCV = nil;
static NSTimer *ccp_capTimer = nil;
static double ccp_expireAt = 0;

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

static void CCALLApplyToFrame(UIView *npv, NSString *frameKey, NSString *viewKey, id self) {
    @try {
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

static void CCALLApply(id self) {
    @try {
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
    ccp_lastCV = self;   // 记录最近的真实模块实例 (快照预览用)
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

// ---------------- 真机模块快照 (SpringBoard 侧, 供设置页实时预览) ----------------
// 设置页每 0.6s 发 Darwin 通知 ccaudioplay.grid/preview-need 续约;
// 本侧 0.7s 一次把最近的真实 CCCustomView 截图写到 /var/mobile/Documents/ccpreview.jpg;
// 5s 内没有续约就自动停。设置页只显示新鲜快照 (mtime < 4s), 否则回退自绘复刻。
static void CCPWriteSnapshot(void) {
    @try {
        UIView *v = ccp_lastCV;
        if (!v || v.bounds.size.width < 10) return;
        UIGraphicsBeginImageContextWithOptions(v.bounds.size, NO, [UIScreen mainScreen].scale);
        BOOL ok = NO;
        @try {
            ok = [(id)v drawViewHierarchyInRect:v.bounds afterScreenUpdates:NO];
        } @catch (id e) {
            ok = NO;
        }
        UIImage *img = ok ? UIGraphicsGetImageFromCurrentImageContext() : nil;
        UIGraphicsEndImageContext();
        if (!img) return;
        NSData *jpg = UIImageJPEGRepresentation(img, 0.85);
        if (jpg) [jpg writeToFile:@"/var/mobile/Documents/ccpreview.jpg" atomically:YES];
    } @catch (id e) {}
}

static void CCPReqCB(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ccp_expireAt = [NSDate date].timeIntervalSince1970 + 5.0;
        if (!ccp_capTimer) {
            ccp_capTimer = [NSTimer timerWithTimeInterval:0.7 target:[CCPCapture shared]
                                                 selector:@selector(tick) userInfo:nil repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:ccp_capTimer forMode:NSRunLoopCommonModes];
            CCPLog(@"snap", @"capture started");
        }
    });
}

@interface CCPCapture : NSObject
+ (instancetype)shared;
- (void)tick;
@end

@implementation CCPCapture
+ (instancetype)shared {
    static id s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}
- (id)init {
    if ((self = [super init])) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        CCPReqCB, CFSTR("ccaudioplay.grid/preview-need"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CCPLog(@"snap", @"capture listener ready");
    }
    return self;
}
- (void)tick {
    if ([NSDate date].timeIntervalSince1970 > ccp_expireAt) {
        [ccp_capTimer invalidate];
        ccp_capTimer = nil;
        CCPLog(@"snap", @"capture stopped (no renewal)");
        return;
    }
    CCPWriteSnapshot();
}
@end

@interface CCALLBootstrap : NSObject
@end
@implementation CCALLBootstrap
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCALLRetry();
        [CCPCapture shared];   // 装快照请求监听
    });
}
@end
