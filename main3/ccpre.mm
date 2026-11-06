/**
 * CCALLCustomPage — 自定义设置页 (全模块): 预览 + 模块大小切换 + 滑条
 *
 * v115/v116 的教训: 让 Preferences 直接实例化我们自己的 detail 控制器类
 * (PSLinkCell detail -> CCALLCustomController) 会在 PSListController
 * controllerForSpecifier: 的实例化协议上崩 (两次 .ips 同一位置)。
 *
 * v117 思路: Root.plist 保持原样 (detail = CCAudio3x2ListController, 原本就能正常
 * 打开), 在 loader 里给 CCAudio3x2ListController 的 viewDidLoad 加覆盖
 * (class_addMethod 优先, 失败说明它自己实现了则换 IMP), 原逻辑跑完后把
 * 预览+分段+滑条界面盖在整个 view 上面 (不透明, 盖住原表格)。
 * 安装结果写 /var/mobile/Documents/ccpre_debug.log 便于诊断。
 *
 * 写值: 与原 CCFrameCell 同键; 模板保持 —— 读现有值只替换其中数字,
 * 无既有值时用默认模板 "X:%.1f Y:%.1f 高度:%.1f 宽度:%.1f"。
 * 每次改动发 Darwin 通知 com.thefool.ccaudioplaypres/updateCustomFrameNotificationt
 * (字体走 updateCustomFontNotificationt), 真机 CC 模块实时刷新。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CCP_DOMAIN @"com.thefool.ccaudioplaypres"
#define CCP_NOTE_FRAME @"com.thefool.ccaudioplaypres/updateCustomFrameNotificationt"
#define CCP_NOTE_FONT  @"com.thefool.ccaudioplaypres/updateCustomFontNotificationt"

static char _ccp_assoc_key;
static char _ccp_assoc_font_idx;
static char _ccp_assoc_info;
static char _ccp_assoc_built;

// ---------------- 日志 ----------------
static void CCPLog(NSString *tag, NSString *line) {
    @try {
        NSString *p = @"/var/mobile/Documents/ccpre_debug.log";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        NSMutableString *existing = nil;
        unsigned long long sz = [attr fileSize];
        if (sz > 0 && sz < 100000) {
            existing = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        }
        NSMutableString *next = existing ?: [NSMutableString string];
        [next appendFormat:@"[%@] [%@] %@\n", [NSDate date], tag, line];
        [next writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

// ---------------- 模板工具 ----------------
static NSString *CCPDefaultTemplate(void) {
    return @"X:%.1f Y:%.1f 高度:%.1f 宽度:%.1f";
}

static NSRegularExpression *CCPNumRe(void) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [[NSRegularExpression alloc] initWithPattern:@"-?[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
    });
    return re;
}

static BOOL CCPExtract4(NSString *s, double out4[4]) {
    if (![s isKindOfClass:[NSString class]] || ![s length]) return NO;
    NSArray *ms = [[CCPNumRe() matchesInString:s options:0 range:NSMakeRange(0, [s length])]];
    if ([ms count] < 4) return NO;
    for (int i = 0; i < 4; i++) {
        out4[i] = [[s substringWithRange:[ms[i] range]] doubleValue];
    }
    return YES;
}

static NSString *CCPSubstitute4(NSString *tpl, double x, double y, double h, double w) {
    if (![tpl isKindOfClass:[NSString class]] || ![tpl length]) {
        return [NSString stringWithFormat:CCPDefaultTemplate(), x, y, h, w];
    }
    NSArray *ms = [CCPNumRe() matchesInString:tpl options:0 range:NSMakeRange(0, [tpl length])];
    if ([ms count] < 4) {
        return [NSString stringWithFormat:CCPDefaultTemplate(), x, y, h, w];
    }
    NSMutableString *s = [tpl mutableCopy];
    double vals[4] = {x, y, h, w};
    for (int i = 3; i >= 0; i--) {
        [s replaceCharactersInRange:[ms[i] range]
                         withString:[NSString stringWithFormat:@"%.1f", vals[i]]];
    }
    return s;
}

// ---------------- 预览视图 ----------------
@interface CCPPreviewView : UIView
- (void)updateWithModule:(int)module frames:(NSDictionary *)frames;
@end

@implementation CCPPreviewView {
    UIView *_mod;
    NSMutableArray *_els;
}

- (id)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        [self.layer setCornerRadius:14.0];
        [self.layer setMasksToBounds:YES];
        [self setBackgroundColor:[UIColor colorWithWhite:0.13 alpha:1.0]];
        _mod = [[UIView alloc] initWithFrame:f];
        [_mod.layer setCornerRadius:12.0];
        [_mod.layer setMasksToBounds:YES];
        [_mod.layer setBorderWidth:1.0];
        [_mod.layer setBorderColor:[UIColor colorWithWhite:1.0 alpha:0.35].CGColor];
        [_mod setBackgroundColor:[UIColor colorWithWhite:0.9 alpha:1.0]];
        [self addSubview:_mod];
        _els = [NSMutableArray array];
        struct {
            __unsafe_unretained NSString *key;
            __unsafe_unretained NSString *text;
            CGFloat r;
        } defs[] = {
            {@"iconFrame",         @"专辑",  8},
            {@"titleFrame",        @"歌词",  0},
            {@"subTitleFrame",     @"歌曲",  0},
            {@"elapsedTitleFrame", @"1:23",  0},
            {@"durationTitleFrame",@"3:45",  0},
            {@"progressFrame",     @"",      0},
            {@"leftButtonFrame",   @"⏮",   12},
            {@"centerButtonFrame", @"▶",    14},
            {@"rightButtonFrame",  @"⏭",   12},
        };
        for (int i = 0; i < 9; i++) {
            UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
            if (i == 0) {
                [v.layer setCornerRadius:8.0];
                [v setBackgroundColor:[UIColor colorWithWhite:0.35 alpha:1.0]];
            } else if (i == 5) {
                [v setBackgroundColor:[UIColor colorWithWhite:0.2 alpha:1.0]];
            } else if (i >= 6) {
                [v.layer setCornerRadius:defs[i].r];
                [v setBackgroundColor:[UIColor colorWithWhite:0.55 alpha:1.0]];
            }
            if ([defs[i].text length]) {
                UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
                [l setText:defs[i].text];
                [l setTextAlignment:NSTextAlignmentCenter];
                [l setTextColor:[UIColor whiteColor]];
                [l setFont:[UIFont systemFontOfSize:9.0]];
                [l setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
                [v addSubview:l];
            }
            [v setUserInteractionEnabled:NO];
            [_mod addSubview:v];
            [_els addObject:@{@"view": v, @"key": defs[i].key}];
        }
    }
    return self;
}

- (CGSize)moduleSize:(int)m {
    switch (m) {
        case 0: return CGSizeMake(164.0, 159.0);
        case 1: return CGSizeMake(164.0, 238.5);
        case 2: return CGSizeMake(246.0, 159.0);
        case 3: return CGSizeMake(328.0, 159.0);
        default:return CGSizeMake(328.0, 238.5);
    }
}

- (void)updateWithModule:(int)module frames:(NSDictionary *)frames {
    CGSize ms = [self moduleSize:module];
    double availW = [self bounds].size.width - 24.0;
    double availH = [self bounds].size.height - 24.0;
    double sc = MIN(availW / ms.width, availH / ms.height);
    CGSize show = CGSizeMake(ms.width * sc, ms.height * sc);
    [_mod setFrame:CGRectMake(([self bounds].size.width - show.width) / 2.0,
                              ([self bounds].size.height - show.height) / 2.0,
                              show.width, show.height)];
    for (NSDictionary *d in _els) {
        UIView *v = d[@"view"];
        NSValue *fv = frames[d[@"key"]];
        if (!fv) { [v setHidden:YES]; continue; }
        CGRect fr = [fv CGRectValue];
        if (fr.size.width <= 0.5 && fr.size.height <= 0.5) { [v setHidden:YES]; continue; }
        [v setHidden:NO];
        CGRect scaled = CGRectMake(fr.origin.x * sc, fr.origin.y * sc,
                                   fr.size.width * sc, fr.size.height * sc);
        if (scaled.size.height < 2.0 && [d[@"key"] isEqualToString:@"progressFrame"]) {
            scaled.size.height = 2.5;
        }
        [v setFrame:scaled];
    }
}

@end

// ---------------- 页面状态与动作 ----------------
@interface CCPPageHelper : NSObject
@property (nonatomic, retain) CCPPreviewView *preview;
@property (nonatomic, retain) UISegmentedControl *seg;
@property (nonatomic, retain) NSMutableDictionary *frames;
@property (nonatomic, retain) NSMutableDictionary *templates;
@property (nonatomic, retain) NSMutableArray *sliderRows;
@property (nonatomic, retain) NSTimer *saveTimer;
@property (nonatomic, assign) BOOL frameDirty;
@end

@implementation CCPPageHelper

- (void)buildOnHost:(UIView *)host {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:CCP_DOMAIN] ?: @{};
    NSArray *keys = @[@"iconFrame", @"titleFrame", @"subTitleFrame", @"elapsedTitleFrame",
                      @"durationTitleFrame", @"progressFrame", @"leftButtonFrame",
                      @"centerButtonFrame", @"rightButtonFrame"];
    _frames = [NSMutableDictionary dictionary];
    _templates = [NSMutableDictionary dictionary];
    _sliderRows = [NSMutableArray array];
    for (NSString *k in keys) {
        id v = [dom objectForKey:k];
        double a[4] = {0, 0, 0, 0};
        if ([v isKindOfClass:[NSString class]]) {
            [_templates setObject:v forKey:k];
            CCPExtract4(v, a);
        }
        [_frames setObject:[NSValue valueWithBytes:&a objCType:@encode(CGRect)] forKey:k];
    }

    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat inner = W - 32.0;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:host.bounds];
    [scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [scroll setAlwaysBounceVertical:YES];
    [scroll setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];
    [host addSubview:scroll];

    CGFloat y = 16;

    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 18)];
    [pt setText:@"实时预览 (占位示意, 数值随滑条变化)"];
    [pt setFont:[UIFont systemFontOfSize:12.0]];
    [pt setTextColor:[UIColor grayColor]];
    [scroll addSubview:pt];
    y += 24;

    _preview = [[CCPPreviewView alloc] initWithFrame:CGRectMake(16, y, inner, 170.0)];
    [scroll addSubview:_preview];
    y += 182;

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 18)];
    [st setText:@"预览模块大小"];
    [st setFont:[UIFont systemFontOfSize:12.0]];
    [st setTextColor:[UIColor grayColor]];
    [scroll addSubview:st];
    y += 22;

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"2x2", @"2x3", @"3x2", @"4x2", @"4x3"]];
    [_seg setFrame:CGRectMake(16, y, inner, 32)];
    [_seg setSelectedSegmentIndex:2];
    [_seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:_seg];
    y += 44;

    y = [self addSwitchRowIn:scroll y:y label:@"启用自定义" key:@"isEnableCustomFrame" def:NO width:W];
    y = [self addSwitchRowIn:scroll y:y label:@"启用颜色调试" key:@"isEnableColor" def:NO width:W];

    NSArray *names = @[@"专辑", @"歌词", @"歌曲", @"当前时间", @"总时间",
                       @"进度条", @"左边按钮", @"中间按钮", @"右边按钮"];
    NSArray *dims = @[@"X", @"Y", @"高", @"宽"];
    for (int e = 0; e < 9; e++) {
        NSString *k = keys[e];
        UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
        [h setText:[NSString stringWithFormat:@"%@  (%@)", names[e], k]];
        [h setFont:[UIFont boldSystemFontOfSize:13.0]];
        [scroll addSubview:h];
        y += 24;
        CGRect cur;
        [[_frames objectForKey:k] getValue:&cur];
        for (int d = 0; d < 4; d++) {
            double val = (d == 0) ? cur.origin.x : (d == 1) ? cur.origin.y
                       : (d == 2) ? cur.size.height : cur.size.width;
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, y, inner - 78, 30)];
            [sl setMinimumValue:0.0];
            [sl setMaximumValue:(d <= 1) ? 340.0 : 260.0];
            [sl setValue:(float)val];
            objc_setAssociatedObject(sl, &_ccp_assoc_info,
                                     @{@"key": k, @"idx": @(d), @"dim": dims[d], @"vlabel": vl},
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [scroll addSubview:sl];

            UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 5, 70, 20)];
            [vl setText:[NSString stringWithFormat:@"%@ %.1f", dims[d], val]];
            [vl setFont:[UIFont systemFontOfSize:12.0]];
            [vl setTextAlignment:NSTextAlignmentRight];
            [vl setTextColor:[UIColor darkGrayColor]];
            [scroll addSubview:vl];
            y += 34;
        }
        y += 6;
    }

    UILabel *fh = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
    [fh setText:@"字体自定义设置"];
    [fh setFont:[UIFont boldSystemFontOfSize:13.0]];
    [scroll addSubview:fh];
    y += 24;
    NSArray *fkeys = @[@"titleFont", @"subtitleFont", @"elapsedTitleFont", @"durationTitleFont"];
    NSArray *fnames = @[@"歌词字体", @"歌曲字体", @"当前时长字体", @"总时长字体"];
    for (int i = 0; i < 4; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 4, 110, 22)];
        [l setText:fnames[i]];
        [l setFont:[UIFont systemFontOfSize:13.0]];
        [scroll addSubview:l];
        double v = [[dom objectForKey:fkeys[i]] doubleValue];
        if (v < 4.0 || v > 30.0) v = 10.0;
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(130, y, inner - 210, 30)];
        [sl setMinimumValue:5.0];
        [sl setMaximumValue:17.0];
        [sl setValue:(float)v];
        objc_setAssociatedObject(sl, &_ccp_assoc_font_idx, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sl addTarget:self action:@selector(fontChanged:) forControlEvents:UIControlEventValueChanged];
        [scroll addSubview:sl];
        UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 4, 70, 22)];
        [vl setText:[NSString stringWithFormat:@"%.2f", v]];
        [vl setFont:[UIFont systemFontOfSize:12.0]];
        [vl setTextAlignment:NSTextAlignmentRight];
        [vl setTextColor:[UIColor darkGrayColor]];
        objc_setAssociatedObject(sl, &_ccp_assoc_key, vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scroll addSubview:vl];
        y += 38;
    }

    y += 20;
    [scroll setContentSize:CGSizeMake(W, y + 40)];
    [self refreshPreview];
}

- (CGFloat)addSwitchRowIn:(UIScrollView *)scroll y:(CGFloat)y label:(NSString *)label
                      key:(NSString *)key def:(BOOL)def width:(CGFloat)W {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 6, 180, 24)];
    [l setText:label];
    [l setFont:[UIFont systemFontOfSize:14.0]];
    [scroll addSubview:l];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:CCP_DOMAIN] ?: @{};
    BOOL on = def;
    id v = [dom objectForKey:key];
    if (v) on = [v boolValue];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(W - 68, y + 3, 51, 31)];
    [sw setOn:on animated:NO];
    objc_setAssociatedObject(sw, &_ccp_assoc_key, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:sw];
    return y + 44;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, &_ccp_assoc_key);
    [self cc_write:key value:@([sw isOn])];
    [self cc_postNote:CCP_NOTE_FRAME];
}

- (void)segChanged:(UISegmentedControl *)seg {
    [self refreshPreview];
}

- (void)sliderChanged:(UISlider *)sl {
    NSDictionary *info = objc_getAssociatedObject(sl, &_ccp_assoc_info);
    if (!info) return;
    NSString *key = info[@"key"];
    int idx = [info[@"idx"] intValue];
    double val = [sl value];

    UILabel *vl = info[@"vlabel"];
    if ([vl isKindOfClass:[UILabel class]]) {
        [vl setText:[NSString stringWithFormat:@"%@ %.1f", info[@"dim"], val]];
    }

    CGRect cur;
    [[_frames objectForKey:key] getValue:&cur];
    if (idx == 0) cur.origin.x = val;
    else if (idx == 1) cur.origin.y = val;
    else if (idx == 2) cur.size.height = val;
    else cur.size.width = val;
    [_frames setObject:[NSValue valueWithBytes:&cur objCType:@encode(CGRect)] forKey:key];

    [self refreshPreview];
    _frameDirty = YES;
    [_saveTimer invalidate];
    _saveTimer = [NSTimer timerWithTimeInterval:0.35 target:self selector:@selector(flushFrameSave)
                                       userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_saveTimer forMode:NSRunLoopCommonModes];
}

- (void)flushFrameSave {
    if (!_frameDirty) return;
    _frameDirty = NO;
    NSArray *keys = @[@"iconFrame", @"titleFrame", @"subTitleFrame", @"elapsedTitleFrame",
                      @"durationTitleFrame", @"progressFrame", @"leftButtonFrame",
                      @"centerButtonFrame", @"rightButtonFrame"];
    for (NSString *k in keys) {
        CGRect cur;
        [[_frames objectForKey:k] getValue:&cur];
        NSString *tpl = [_templates objectForKey:k];
        if (![tpl length]) {
            for (NSString *other in keys) {
                NSString *t2 = [_templates objectForKey:other];
                if ([t2 length]) { tpl = t2; break; }
            }
        }
        NSString *val = CCPSubstitute4(tpl, cur.origin.x, cur.origin.y, cur.size.height, cur.size.width);
        [self cc_write:k value:val];
    }
    [self cc_postNote:CCP_NOTE_FRAME];
}

- (void)fontChanged:(UISlider *)sl {
    int i = [objc_getAssociatedObject(sl, &_ccp_assoc_font_idx) intValue];
    double v = [sl value];
    UILabel *vl = objc_getAssociatedObject(sl, &_ccp_assoc_key);
    if ([vl isKindOfClass:[UILabel class]]) [vl setText:[NSString stringWithFormat:@"%.2f", v]];
    NSArray *fkeys = @[@"titleFont", @"subtitleFont", @"elapsedTitleFont", @"durationTitleFont"];
    [self cc_write:fkeys[i] value:@(v)];
    [self cc_postNote:CCP_NOTE_FONT];
}

- (void)cc_write:(NSString *)key value:(id)val {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *dom = [[ud persistentDomainForName:CCP_DOMAIN] mutableCopy] ?: [NSMutableDictionary dictionary];
        [dom setObject:val forKey:key];
        [ud setPersistentDomain:dom forName:CCP_DOMAIN];
        [ud synchronize];
    } @catch (id e) {}
}

- (void)cc_postNote:(NSString *)name {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name, NULL, NULL, YES);
    } @catch (id e) {}
}

- (void)refreshPreview {
    [_preview updateWithModule:(int)[_seg selectedSegmentIndex] frames:_frames];
}

@end

// ---------------- swizzle: CCAudio3x2ListController viewDidLoad ----------------
static void (*ccp_orig_vdl)(id, SEL) = NULL;
static BOOL ccp_via_super = NO;
static int ccp_tries = 0;

static void CCPBuildOver(id self) {
    @try {
        if (objc_getAssociatedObject(self, &_ccp_assoc_built)) return;
        UIView *host = nil;
        if ([self respondsToSelector:@selector(view)]) {
            host = ((UIView *(*)(id, SEL))objc_msgSend)(self, sel_registerName("view"));
        }
        if (!host) return;
        objc_setAssociatedObject(self, &_ccp_assoc_built, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CCPPageHelper *helper = [[CCPPageHelper alloc] init];
        objc_setAssociatedObject(self, &_ccp_assoc_key, helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [helper buildOnHost:host];
        CCPLog(@"page", @"overlay UI built");
    } @catch (id e) {
        CCPLog(@"page", [NSString stringWithFormat:@"build exception %@", e]);
    }
}

static void ccp_viewDidLoad(id self, SEL _cmd) {
    @try {
        if (ccp_via_super) {
            struct objc_super sup = {self, class_getSuperclass(object_getClass(self))};
            ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
        } else if (ccp_orig_vdl) {
            ccp_orig_vdl(self, _cmd);
        }
    } @catch (id e) {}
    CCPBuildOver(self);
}

static void CCPTryInstall(void) {
    @try {
        Class cls = objc_getClass("CCAudio3x2ListController");
        if (!cls) {
            if (ccp_tries == 0) CCPLog(@"install", @"CCAudio3x2ListController not found yet");
            return;
        }
        SEL vs = sel_registerName("viewDidLoad");
        Method m = class_getInstanceMethod(cls, vs);
        if (!m) {
            CCPLog(@"install", @"viewDidLoad method missing");
            return;
        }
        if (class_addMethod(cls, vs, (IMP)ccp_viewDidLoad, "v@:")) {
            ccp_via_super = YES;
            ccp_orig_vdl = NULL;
            CCPLog(@"install", @"hook installed via class_addMethod (super call)");
        } else {
            ccp_orig_vdl = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)ccp_viewDidLoad);
            ccp_via_super = NO;
            CCPLog(@"install", @"hook installed via exchange");
        }
    } @catch (id e) {
        CCPLog(@"install", [NSString stringWithFormat:@"install exception %@", e]);
    }
}

static void CCPRetry(void) {
    CCPTryInstall();
    // 装好了就不再重试
    BOOL done = ccp_via_super || ccp_orig_vdl != NULL;
    if (!done && ccp_tries < 120) {
        ccp_tries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CCPRetry();
        });
    }
}

@interface CCPBootstrap : NSObject
@end
@implementation CCPBootstrap
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCPRetry();
    });
}
@end
