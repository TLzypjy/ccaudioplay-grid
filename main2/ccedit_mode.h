//
//  CCEditMode.h — 控制中心内直接编辑元素位置
//
//  双击 CCCustomView → 进入/退出编辑模式。
//  编辑模式: 每个可调元素显示彩色半透明覆盖层 + pan 拖动。
//  拖动释放 → 写回 prefs → 发通知刷新。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char cce_edit_key = 0;
static char cce_ovl_key = 0;
static char cce_drag_key = 0;

// 可编辑元素: key → (viewKey, color, label)
static NSDictionary *cceElements(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"iconFrame":          @[@"playingIconView",    [UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:0.30], @"专辑"],
            @"elapsedTitleFrame":  @[@"elapsedTitleLabel",  [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:0.30], @"时间"],
            @"durationTitleFrame": @[@"durationTitleLabel", [UIColor colorWithRed:0.2 green:0.4 blue:1.0 alpha:0.30], @"总时长"],
            @"progressFrame":      @[@"progressView",       [UIColor colorWithRed:1.0 green:0.8 blue:0.1 alpha:0.30], @"进度条"],
        };
    });
    return d;
}

// ---------------- 手势处理类 ----------------
@interface CCEditGestureTarget : NSObject
+ (instancetype)shared;
- (void)onDoubleTap:(UITapGestureRecognizer *)gr;
- (void)onDrag:(UIPanGestureRecognizer *)gr;
@end

static char cce_helper_key = 0;

@implementation CCEditGestureTarget

+ (instancetype)shared {
    static id s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)onDoubleTap:(UITapGestureRecognizer *)gr {
    @try {
        UIView *widget = [gr view];
        if (!widget) return;
        BOOL editing = [objc_getAssociatedObject(widget, &cce_edit_key) boolValue];
        BOOL next = !editing;
        objc_setAssociatedObject(widget, &cce_edit_key, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 清旧覆盖层
        NSArray *old = objc_getAssociatedObject(widget, &cce_ovl_key);
        for (UIView *ov in old) [ov removeFromSuperview];
        objc_setAssociatedObject(widget, &cce_ovl_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (!next) return;

        // 创建覆盖层
        NSMutableArray *ovs = [NSMutableArray array];
        NSDictionary *elems = [self class] == [CCEditGestureTarget class] ? [self cceElements] : nil;
        [elems enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray *info, BOOL *stop) {
            @try {
                id v = [widget valueForKey:info[0]];
                if (![v isKindOfClass:[UIView class]]) return;
                UIView *tv = v;

                UIView *ov = [[UIView alloc] initWithFrame:
                    [widget convertRect:tv.frame fromView:tv.superview]];
                [ov setBackgroundColor:info[1]];
                [ov.layer setBorderColor:[UIColor whiteColor].CGColor];
                [ov.layer setBorderWidth:1.5];
                [ov.layer setCornerRadius:4.0];
                [ov setUserInteractionEnabled:YES];

                UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(2, 0, 80, 14)];
                [lb setText:info[2]];
                [lb setFont:[UIFont boldSystemFontOfSize:9.0]];
                [lb setTextColor:[UIColor whiteColor]];
                [lb.layer setShadowColor:[UIColor blackColor].CGColor];
                [lb.layer setShadowOpacity:0.8];
                [lb.layer setShadowOffset:CGSizeMake(0, 0.5)];
                [ov addSubview:lb];

                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                    initWithTarget:[CCEditGestureTarget shared]
                    action:@selector(onDrag:)];
                objc_setAssociatedObject(pan, &cce_drag_key, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [ov addGestureRecognizer:pan];

                [widget addSubview:ov];
                [ovs addObject:ov];
            } @catch (id e) {}
        }];
        objc_setAssociatedObject(widget, &cce_ovl_key, ovs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (id e) {}
}

- (NSDictionary *)cceElements {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"iconFrame":          @[@"playingIconView",    [UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:0.30], @"专辑"],
            @"elapsedTitleFrame":  @[@"elapsedTitleLabel",  [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:0.30], @"时间"],
            @"durationTitleFrame": @[@"durationTitleLabel", [UIColor colorWithRed:0.2 green:0.4 blue:1.0 alpha:0.30], @"总时长"],
            @"progressFrame":      @[@"progressView",       [UIColor colorWithRed:1.0 green:0.8 blue:0.1 alpha:0.30], @"进度条"],
        };
    });
    return d;
}

- (void)onDrag:(UIPanGestureRecognizer *)gr {
    @try {
        NSString *key = objc_getAssociatedObject(gr, &cce_drag_key);
        if (!key) return;
        UIView *ov = [gr view];
        if (!ov) return;
        UIView *widget = [ov superview];
        if (!widget) return;

        if (gr.state == UIGestureRecognizerStateChanged) {
            CGPoint t = [gr translationInView:widget];
            CGPoint c = [ov center];
            [ov setCenter:CGPointMake(c.x + t.x, c.y + t.y)];
            [gr setTranslation:CGPointZero inView:widget];
        } else if (gr.state == UIGestureRecognizerStateEnded) {
            // 保存新位置: 覆盖层 frame (widget坐标) → 元素父坐标系
            CGRect nfWidget = [ov frame];
            NSString *viewKey = [self cceElements][key][0];
            UIView *tv = [widget valueForKey:viewKey];
            if ([tv isKindOfClass:[UIView class]]) {
                CGRect nfLocal = [widget convertRect:nfWidget toView:tv.superview];
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                NSMutableDictionary *dom = [[ud persistentDomainForName:@"com.thefool.ccaudioplaypres"]
                                            mutableCopy] ?: [NSMutableDictionary dictionary];
                NSString *tpl = [dom objectForKey:key];
                if (![tpl length]) tpl = @"X:%.1f Y:%.1f 高度:%.1f 宽度:%.1f";
                NSRegularExpression *re = [[NSRegularExpression alloc]
                    initWithPattern:@"-?[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
                NSArray *ms = [re matchesInString:tpl options:0 range:NSMakeRange(0, [tpl length])];
                NSMutableString *sv = [tpl mutableCopy];
                double vals[4] = {nfLocal.origin.x, nfLocal.origin.y, nfLocal.size.height, nfLocal.size.width};
                if ([ms count] >= 4) {
                    for (int i = 3; i >= 0; i--) {
                        [sv replaceCharactersInRange:[ms[i] range]
                             withString:[NSString stringWithFormat:@"%.1f", vals[i]]];
                    }
                }
                [dom setObject:sv forKey:key];
                [ud setPersistentDomain:dom forName:@"com.thefool.ccaudioplaypres"];
                [ud synchronize];
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFSTR("com.thefool.ccaudioplaypres/updateCustomFrameNotificationt"),
                    NULL, NULL, YES);
            }
        }
    } @catch (id e) {}
}

@end

// ---------------- 安装入口 ----------------
static void CCEInstallEditMode(UIView *widget) {
    @try {
        if (![widget isKindOfClass:[UIView class]]) return;
        // 检查是否已装 (已有 UITapGestureRecognizer 双击)
        for (UIGestureRecognizer *gr in [widget gestureRecognizers] ?: @[]) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]] &&
                [(UITapGestureRecognizer *)gr numberOfTapsRequired] == 2) return;
        }
        UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc]
            initWithTarget:[CCEditGestureTarget shared]
            action:@selector(onDoubleTap:)];
        [dt setNumberOfTapsRequired:2];
        [dt setDelaysTouchesEnded:NO];
        [widget addGestureRecognizer:dt];
    } @catch (id e) {}
}
