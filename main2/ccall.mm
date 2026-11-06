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

static void CCALLApplyToFrame(UIView *npv, NSString *frameKey, NSString *viewKey, id self) {
    @try {
        NSValue *fv = [self valueForKey:frameKey];
        if (!fv) return;
        CGRect fr = [fv CGRectValue];
        if (fr.origin.x == 0 && fr.origin.y == 0 && fr.size.width == 0 && fr.size.height == 0) return;
        UIView *v = [npv valueForKey:viewKey];
        if ([v isKindOfClass:[UIView class]]) [v setFrame:fr];
    } @catch (id e) {}
}

static void CCALLApplyFont(UILabel *lab, NSString *fontKey, id self) {
    @try {
        if (!lab) return;
        double fs = [[self valueForKey:fontKey] doubleValue];
        if (fs >= 4.0 && fs <= 30.0) [lab setFont:[UIFont systemFontOfSize:fs]];
    } @catch (id e) {}
}

static void CCALLApply(id self) {
    @try {
        // 3x2 由原实现自己处理
        int type = [[self valueForKey:@"type"] intValue];
        if (type == 2) return;
        if (![[self valueForKey:@"IsEnableCustomFrame"] boolValue]) return;

        // ---- 直属元素 (CCCustomView 自己的属性) ----
        NSDictionary *direct = @{
            @"iconFrame"         : @"playingIconView",
            @"elapsedTitleFrame" : @"elapsedTitleLabel",
            @"durationTitleFrame": @"durationTitleLabel",
            @"progressFrame"     : @"progressView",
        };
        for (NSString *fk in direct) {
            @try {
                NSValue *fv = [self valueForKey:fk];
                if (!fv) continue;
                CGRect fr = [fv CGRectValue];
                if (fr.origin.x == 0 && fr.origin.y == 0 && fr.size.width == 0 && fr.size.height == 0) continue;
                UIView *v = [self valueForKey:direct[fk]];
                if ([v isKindOfClass:[UIView class]]) [v setFrame:fr];
            } @catch (id e) {}
        }
        // 自定义进度条容器跟随进度条框
        @try {
            NSValue *pf = [self valueForKey:@"progressFrame"];
            UIView *pcv = [self valueForKey:@"progressCustomView"];
            if (pf && pcv) {
                CGRect fr = [pf CGRectValue];
                if (fr.size.width > 0 && fr.size.height > 0) [pcv setFrame:fr];
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
        if (!c) return;
        Method m = class_getInstanceMethod(c, sel_registerName("layoutSubviews"));
        if (!m) return;
        if (method_getImplementation(m) == (IMP)CCALLLayoutSubviews) return;  // 已装
        ccal_orig_layoutSubviews = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)CCALLLayoutSubviews);
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
