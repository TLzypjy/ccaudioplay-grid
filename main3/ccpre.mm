/**
 * CCALLCustomController — 自定义设置页 (全模块): 预览 + 模块大小切换 + 滑条
 *
 * 替换原 "3x2自定义" (CCAudio3x2ListController) 页面。repack 时把 Root.plist 的
 * detail 指到本类 (类在 CCAudioPlayPres loader 二进制里, 设置进程可直接用)。
 *
 * 功能:
 *  1. 顶部实时预览: 按所选模块大小 (2x2/2x3/3x2/4x2/4x3) 等比缩放的模块形状,
 *     9 个元素占位物按当前 frame 值摆放, 滑条一动立即重摆。
 *  2. 位置滑条: 9 元素 x (X/Y/高/宽), 与原 CCFrameCell 同键同格式 ——
 *     读取现有值后只替换其中的数字 (模板保持, 兼容任意显示格式);
 *     无既有值时用默认模板 "X:%.1f Y:%.1f 高度:%.1f 宽度:%.1f"。
 *  3. 字体滑条: 复用 titleFont/subtitleFont/elapsedTitleFont/durationTitleFont。
 *  4. 每次改动: 写 NSUserDefaults domain com.thefool.ccaudioplaypres + 同步 +
 *     发 Darwin 通知 com.thefool.ccaudioplaypres/updateCustomFrameNotificationt
 *     (字体走 updateCustomFontNotificationt), 真机 CC 模块实时刷新。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 与 bundle_struct 一致的最小声明 (Preferences 私有框架, 运行时动态解析)
@interface PSListController : UIViewController
@property (retain, nonatomic) id specifier;
@end

#define DOMAIN @"com.thefool.ccaudioplaypres"
#define NOTE_FRAME @"com.thefool.ccaudioplaypres/updateCustomFrameNotificationt"
#define NOTE_FONT  @"com.thefool.ccaudioplaypres/updateCustomFontNotificationt"

static char _ccp_assoc_key;
static char _ccp_assoc_font_idx;

static NSString *CCPDefaultTemplate(void) {
    return @"X:%.1f Y:%.1f 高度:%.1f 宽度:%.1f";
}

// 从模板串提取前 4 个数字 (按出现顺序); 返回 NO 表示没有模板
static BOOL CCPExtract4(NSString *s, double out4[4]) {
    if (![s isKindOfClass:[NSString class]] || ![s length]) return NO;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [[NSRegularExpression alloc] initWithPattern:@"-?[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
    });
    NSArray *ms = [re matchesInString:s options:0 range:NSMakeRange(0, [s length])];
    if ([ms count] < 4) return NO;
    for (int i = 0; i < 4; i++) {
        NSTextCheckingResult *m = ms[i];
        NSString *n = [s substringWithRange:[m range]];
        out4[i] = [n doubleValue];
    }
    return YES;
}

// 用 4 个新数字替换模板串里的前 4 个数字 (没有 4 个数字则视为无模板, 返回用默认模板生成)
static NSString *CCPSubstitute4(NSString *tpl, double x, double y, double h, double w) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [[NSRegularExpression alloc] initWithPattern:@"-?[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
    });
    if (![tpl isKindOfClass:[NSString class]] || ![tpl length]) {
        return [NSString stringWithFormat:CCPDefaultTemplate(), x, y, h, w];
    }
    NSArray *ms = [re matchesInString:tpl options:0 range:NSMakeRange(0, [tpl length])];
    if ([ms count] < 4) {
        return [NSString stringWithFormat:CCPDefaultTemplate(), x, y, h, w];
    }
    NSMutableString *s = [tpl mutableCopy];
    // 从后往前替换, 避免 range 失效
    double vals[4] = {x, y, h, w};
    for (int i = 3; i >= 0; i--) {
        NSTextCheckingResult *m = ms[i];
        [s replaceCharactersInRange:[m range] withString:[NSString stringWithFormat:@"%.1f", vals[i]]];
    }
    return s;
}

@interface CCALLPreviewView : UIView
- (void)updateWithModule:(int)module frames:(NSDictionary<NSString *, NSValue *> *)frames;
@end

@implementation CCALLPreviewView {
    UIView *_mod;
    NSMutableArray *_els;   // dicts: view, key
    int _module;
    double _sx, _sy, _ox, _oy;  // 缩放/偏移
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

// 模块像素尺寸估算: 单元 82 x 79.5, 命名 = 列x行 (3x2 = 246x159 与作者注释吻合)
- (CGSize)moduleSize:(int)m {
    switch (m) {
        case 0: return CGSizeMake(164.0, 159.0);   // 2x2
        case 1: return CGSizeMake(164.0, 238.5);   // 2x3
        case 2: return CGSizeMake(246.0, 159.0);   // 3x2
        case 3: return CGSizeMake(328.0, 159.0);   // 4x2
        default:return CGSizeMake(328.0, 238.5);   // 4x3
    }
}

- (void)updateWithModule:(int)module frames:(NSDictionary<NSString *, NSValue *> *)frames {
    _module = module;
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
            scaled.size.height = 2.5;   // 进度条最小可见厚度
        }
        [v setFrame:scaled];
    }
}

@end

@interface CCALLCustomController : PSListController
@end

@implementation CCALLCustomController {
    UIScrollView *_scroll;
    CCALLPreviewView *_preview;
    UISegmentedControl *_seg;
    NSMutableDictionary *_frames;          // key -> NSValue(CGRect)
    NSMutableDictionary *_templates;       // key -> 原始模板串 (可能 nil)
    NSMutableArray *_sliderRows;           // dicts: slider, label, key, idx(0-3)
    UILabel *_fontVal[4];
    double _fontVals[4];
    NSTimer *_saveTimer;
    BOOL _frameDirty;
}

- (NSString *)cc_title {
    return @"自定义设置(全模块)";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setTitle:[self cc_title]];
    [[self view] setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];

    _frames = [NSMutableDictionary dictionary];
    _templates = [NSMutableDictionary dictionary];
    _sliderRows = [NSMutableArray array];

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:DOMAIN] ?: @{};
    NSArray *keys = @[@"iconFrame", @"titleFrame", @"subTitleFrame", @"elapsedTitleFrame",
                      @"durationTitleFrame", @"progressFrame", @"leftButtonFrame",
                      @"centerButtonFrame", @"rightButtonFrame"];
    for (NSString *k in keys) {
        id v = [dom objectForKey:k];
        double a[4] = {0, 0, 0, 0};
        if ([v isKindOfClass:[NSString class]]) {
            [_templates setObject:v forKey:k];
            CCPExtract4(v, a);
        }
        [_frames setObject:[NSValue valueWithBytes:&a objCType:@encode(CGRect)] forKey:k];
    }

    CGFloat W = [[self view] bounds].size.width;
    if (W < 100) W = [UIScreen mainScreen].bounds.size.width - 32.0;

    _scroll = [[UIScrollView alloc] initWithFrame:[[self view] bounds]];
    [_scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [_scroll setAlwaysBounceVertical:YES];
    [[self view] addSubview:_scroll];

    CGFloat y = 16;
    CGFloat inner = W - 32;

    // ---- 预览 ----
    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 18)];
    [pt setText:@"实时预览 (占位示意, 数值随滑条变化)"];
    [pt setFont:[UIFont systemFontOfSize:12.0]];
    [pt setTextColor:[UIColor grayColor]];
    [_scroll addSubview:pt];
    y += 24;

    _preview = [[CCALLPreviewView alloc] initWithFrame:CGRectMake(16, y, inner, 170.0)];
    [_scroll addSubview:_preview];
    y += 182;

    // ---- 模块大小切换 ----
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 18)];
    [st setText:@"预览模块大小"];
    [st setFont:[UIFont systemFontOfSize:12.0]];
    [st setTextColor:[UIColor grayColor]];
    [_scroll addSubview:st];
    y += 22;

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"2x2", @"2x3", @"3x2", @"4x2", @"4x3"]];
    [_seg setFrame:CGRectMake(16, y, inner, 32)];
    [_seg setSelectedSegmentIndex:2];
    [_seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_seg];
    y += 44;

    // ---- 开关 ----
    y = [self addSwitchRow:y label:@"启用自定义" key:@"isEnableCustomFrame" def:NO];
    y = [self addSwitchRow:y label:@"启用颜色调试" key:@"isEnableColor" def:NO];

    // ---- 位置滑条 ----
    NSArray *names = @[@"专辑", @"歌词", @"歌曲", @"当前时间", @"总时间",
                       @"进度条", @"左边按钮", @"中间按钮", @"右边按钮"];
    NSArray *dims = @[@"X", @"Y", @"高", @"宽"];
    for (int e = 0; e < 9; e++) {
        NSString *k = keys[e];
        UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
        [h setText:[NSString stringWithFormat:@"%@  (%@)", names[e], k]];
        [h setFont:[UIFont boldSystemFontOfSize:13.0]];
        [_scroll addSubview:h];
        y += 24;
        CGRect cur;
        [[_frames objectForKey:k] getValue:&cur];
        for (int d = 0; d < 4; d++) {
            double val = (d == 0) ? cur.origin.x : (d == 1) ? cur.origin.y
                       : (d == 2) ? cur.size.height : cur.size.width;
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, y, inner - 78, 30)];
            [sl setMinimumValue:0.0];
            [sl setMaximumValue:(d <= 1) ? 340.0 : 260.0];
            [sl setContinuous:YES];
            [sl setValue:(float)val];
            NSDictionary *info = @{@"key": k, @"idx": @(d)};
            objc_setAssociatedObject(sl, &_ccp_assoc_key, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_scroll addSubview:sl];

            UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 5, 70, 20)];
            [vl setText:[NSString stringWithFormat:@"%@ %.1f", dims[d], val]];
            [vl setFont:[UIFont systemFontOfSize:12.0]];
            [vl setTextAlignment:NSTextAlignmentRight];
            [vl setTextColor:[UIColor darkGrayColor]];
            [_scroll addSubview:vl];

            [_sliderRows addObject:@{@"slider": sl, @"label": vl, @"key": k, @"idx": @(d), @"dim": dims[d]}];
            y += 34;
        }
        y += 6;
    }

    // ---- 字体滑条 ----
    UILabel *fh = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
    [fh setText:@"字体自定义设置"];
    [fh setFont:[UIFont boldSystemFontOfSize:13.0]];
    [_scroll addSubview:fh];
    y += 24;
    NSArray *fkeys = @[@"titleFont", @"subtitleFont", @"elapsedTitleFont", @"durationTitleFont"];
    NSArray *fnames = @[@"歌词字体", @"歌曲字体", @"当前时长字体", @"总时长字体"];
    for (int i = 0; i < 4; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 4, 110, 22)];
        [l setText:fnames[i]];
        [l setFont:[UIFont systemFontOfSize:13.0]];
        [_scroll addSubview:l];
        double v = [[dom objectForKey:fkeys[i]] doubleValue];
        if (v < 4.0 || v > 30.0) v = 10.0;
        _fontVals[i] = v;
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(130, y, inner - 210, 30)];
        [sl setMinimumValue:5.0];
        [sl setMaximumValue:17.0];
        [sl setValue:(float)v];
        objc_setAssociatedObject(sl, &_ccp_assoc_font_idx, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sl addTarget:self action:@selector(fontChanged:) forControlEvents:UIControlEventValueChanged];
        [_scroll addSubview:sl];
        _fontVal[i] = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 4, 70, 22)];
        [_fontVal[i] setText:[NSString stringWithFormat:@"%.2f", v]];
        [_fontVal[i] setFont:[UIFont systemFontOfSize:12.0]];
        [_fontVal[i] setTextAlignment:NSTextAlignmentRight];
        [_fontVal[i] setTextColor:[UIColor darkGrayColor]];
        [_scroll addSubview:_fontVal[i]];
        y += 38;
    }

    y += 20;
    _scroll.contentSize = CGSizeMake(W, y + 40);
    [self refreshPreview];
}

- (CGFloat)addSwitchRowY:(CGFloat)y label:(NSString *)label key:(NSString *)key def:(BOOL)def {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 6, 180, 24)];
    [l setText:label];
    [l setFont:[UIFont systemFontOfSize:14.0]];
    [_scroll addSubview:l];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:DOMAIN] ?: @{};
    BOOL on = def;
    id v = [dom objectForKey:key];
    if (v) on = [v boolValue];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake([[self view] bounds].size.width - 68, y + 3, 51, 31)];
    [sw setOn:on animated:NO];
    objc_setAssociatedObject(sw, &_ccp_assoc_key, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:sw];
    return y + 44;
}

// 上面声明写成 (CGFloat)y label:... 的形式不方便 objc method 查找, 统一用这个包装
- (CGFloat)addSwitchRow:(CGFloat)y label:(NSString *)label key:(NSString *)key def:(BOOL)def {
    return [self addSwitchRowY:y label:label key:key def:def];
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, &_ccp_assoc_key);
    [self cc_write:key value:@([sw isOn])];
    [self cc_postNote:NOTE_FRAME];
}

- (void)segChanged:(UISegmentedControl *)seg {
    [self refreshPreview];
}

- (void)sliderChanged:(UISlider *)sl {
    NSDictionary *info = objc_getAssociatedObject(sl, &_ccp_assoc_key);
    NSString *key = info[@"key"];
    int idx = [info[@"idx"] intValue];
    double val = [sl value];

    // 更新 label
    for (NSDictionary *row in _sliderRows) {
        if ([row[@"slider"] isEqual:sl]) {
            [[row[@"label"]] setText:[NSString stringWithFormat:@"%@ %.1f", row[@"dim"], val]];
            break;
        }
    }

    // 更新 _frames
    CGRect cur;
    [[_frames objectForKey:key] getValue:&cur];
    if (idx == 0) cur.origin.x = val;
    else if (idx == 1) cur.origin.y = val;
    else if (idx == 2) cur.size.height = val;
    else cur.size.width = val;
    [_frames setObject:[NSValue valueWithBytes:&cur objCType:@encode(CGRect)] forKey:key];

    [self refreshPreview];
    _frameDirty = YES;
    [self scheduleFrameSave];
}

- (void)fontChanged:(UISlider *)sl {
    int i = [objc_getAssociatedObject(sl, &_ccp_assoc_font_idx) intValue];
    double v = [sl value];
    _fontVals[i] = v;
    [_fontVal[i] setText:[NSString stringWithFormat:@"%.2f", v]];
    NSArray *fkeys = @[@"titleFont", @"subtitleFont", @"elapsedTitleFont", @"durationTitleFont"];
    [self cc_write:fkeys[i] @(v)];
    [self cc_postNote:NOTE_FONT];
}

- (void)scheduleFrameSave {
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
        if (!tpl) {
            // 沿用已知模板 (任一元素有值即用其模板), 否则默认模板
            for (NSString *other in keys) {
                NSString *t2 = [_templates objectForKey:other];
                if ([t2 length]) { tpl = t2; break; }
            }
        }
        NSString *val = CCPSubstitute4(tpl, cur.origin.x, cur.origin.y, cur.size.height, cur.size.width);
        [self cc_write:k val];
    }
    [self cc_postNote:NOTE_FRAME];
}

- (void)refreshPreview {
    [_preview updateWithModule:(int)[_seg selectedSegmentIndex] frames:_frames];
}

- (void)cc_write:(NSString *)key value:(id)val {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *dom = [[ud persistentDomainForName:DOMAIN] mutableCopy] ?: [NSMutableDictionary dictionary];
        [dom setObject:val forKey:key];
        [ud setPersistentDomain:dom forName:DOMAIN];
        [ud synchronize];
    } @catch (id e) {}
}

- (void)cc_postNote:(NSString *)name {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name, NULL, NULL, YES);
    } @catch (id e) {}
}

@end
