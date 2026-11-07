//
//  CCALLCustomPage — 自定义设置页 (全模块): 共享视图实时预览 + 模块大小切换 + 分组滑条
//
//  v131 (共享层架构, 指令化改造):
//  - 预览 = TLPXPlayerContentView (Shared/ 共享视图, 与真机同一引擎 TLPXLayoutEngine
//    计算的 rectMap 驱动), 不再使用手绘复刻 CCPReplicaView (已删除)。
//  - 模块尺寸 = metrics.plist 真机实测值 (伴随 tweak 布局后回写), 不写死常数;
//    未同步时显示"请先去控制中心打开一次播放器以同步尺寸"并退回兜底尺寸。
//  - 预览缩放: 真实 point 尺寸建视图 + 外层容器 CGAffineTransformMakeScale,
//    禁止把缩放后尺寸再喂给引擎。
//  - 滑条 5 组: 专辑 / 歌词 / 歌曲 / 播放按钮(三键一体) / 进度条(含两边时间);
//    时间固定 34pt 宽不随组宽压扁。
//  - 对齐检查开关: 模块描边 + 每元素边框与 x,y,w,h 标注 + 10pt 网格;
//    开启时输出真机/预览逐元素对照表 (差值 >0.5pt 标记 FAIL)。
//  - 背景为当前选中素材的静态首帧 (不播视频, 不打断音乐); 歌名/封面/时间由
//    TLPXMediaSnapshot 统一取数 (真机侧导出 + MPNowPlayingInfoCenter + 样本兜底)。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "TLPXConstants.h"
#import "TLPXLayoutEngine.h"
#import "TLPXMediaSnapshot.h"
#import "TLPXPlayerContentView.h"

static char _ccp_assoc_key;
static char _ccp_assoc_font_idx;
static char _ccp_assoc_info;
static char _ccp_assoc_built;

// ---------------- 容器 (强制布局, 免疫构建时机) ----------------
@interface CCPContainerView : UIView
@property (nonatomic, retain) UIView *header;
@property (nonatomic, retain) UIScrollView *scroll;
@property (nonatomic, assign) CGFloat headerH;
- (void)ccpForceLayout;
@end

static void CCPLog(NSString *tag, NSString *line) {
    @try {
        NSString *p = @"/var/mobile/Documents/ccpre_debug.log";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        NSMutableString *existing = nil;
        unsigned long long sz = [attr fileSize];
        if (sz > 0 && sz < 200000) {
            existing = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        }
        NSMutableString *next = existing ?: [NSMutableString string];
        [next appendFormat:@"[%@] [%@] %@\n", [NSDate date], tag, line];
        [next writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

// ---------------- 存储格式模板工具 (写入与原 CCFrameCell 兼容的字符串) ----------------
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
    NSArray *ms = [CCPNumRe() matchesInString:s options:0 range:NSMakeRange(0, [s length])];
    if ([ms count] < 4) return NO;
    for (int i = 0; i < 4; i++) out4[i] = [[s substringWithRange:[ms[i] range]] doubleValue];
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

// 素材静态首帧 (网格素材库提供, 带 .ccthumbs 磁盘缓存)
extern UIImage *CCGLoadMaterialThumb(NSString *path);

// ---------------- 页面 ----------------
@interface CCPPageHelper : NSObject
@property (nonatomic, retain) TLPXPlayerContentView *playerView;
@property (nonatomic, retain) UISegmentedControl *seg;
@property (nonatomic, retain) UILabel *sizeHint;
@property (nonatomic, retain) NSMutableDictionary *frames;      // 配置键 → NSValue(模块点坐标)
@property (nonatomic, retain) NSMutableDictionary *templates;   // 配置键 → 原始模板串
@property (nonatomic, retain) NSMutableArray *groupRects;       // 5 组滑条框 (模块点坐标)
@property (nonatomic, retain) NSMutableArray *sliderRows;
@property (nonatomic, retain) NSMutableDictionary *sizeTable;   // @(tier) → NSValue(实测尺寸)
@property (nonatomic, retain) NSMutableSet *touchedGroups;
@property (nonatomic, retain) NSTimer *saveTimer;
@property (nonatomic, assign) BOOL frameDirty;
@property (nonatomic, assign) BOOL metricsLoaded;               // 已读到 metrics.plist
@end

@implementation CCPPageHelper

// ---- 档位尺寸: metrics.plist 优先, 缺失退回兜底尺寸并提示 ----
- (CGSize)sizeForTier:(NSInteger)tier {
    NSValue *v = [_sizeTable objectForKey:@(tier)];
    if (v) return [v CGSizeValue];
    return [TLPXLayoutEngine fallbackSizeForTier:(TLPXTier)tier];
}

- (void)loadMetricsAndSizes {
    _sizeTable = [NSMutableDictionary dictionary];
    _metricsLoaded = NO;
    @try {
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:TLPXMetricsPathRootless]
                          ?: [NSDictionary dictionaryWithContentsOfFile:TLPXMetricsPathRootfs];
        if ([m count]) {
            for (int t = 0; t < 5; t++) {
                NSDictionary *e = [m objectForKey:[@(t) stringValue]];
                if ([e objectForKey:@"width"] && [e objectForKey:@"height"]) {
                    CGSize sz = CGSizeMake([[e objectForKey:@"width"] doubleValue],
                                           [[e objectForKey:@"height"] doubleValue]);
                    [_sizeTable setObject:[NSValue valueWithCGSize:sz] forKey:@(t)];
                    _metricsLoaded = YES;
                }
            }
        }
        if (_metricsLoaded) {
            CCPLog(@"metrics", [NSString stringWithFormat:@"loaded %@",
                   NSStringFromClass(_sizeTable.class)] ? [NSString stringWithFormat:@"tiers=%@", [m allKeys]] : @"-");
        } else {
            CCPLog(@"metrics", @"metrics.plist missing/empty — fallback sizes in effect");
        }
    } @catch (id e) {
        CCPLog(@"metrics", [NSString stringWithFormat:@"read exception %@", e]);
    }
}

- (void)buildOnHost:(CCPContainerView *)host {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:TLPXPrefsDomain] ?: @{};
    NSArray *keys = @[TLPXKeyIconFrame, TLPXKeyTitleFrame, TLPXKeySubTitleFrame, TLPXKeyElapsedTitleFrame,
                      TLPXKeyDurationTitleFrame, TLPXKeyProgressFrame, TLPXKeyLeftButtonFrame,
                      TLPXKeyCenterButtonFrame, TLPXKeyRightButtonFrame];
    _frames = [NSMutableDictionary dictionary];
    _templates = [NSMutableDictionary dictionary];
    _sliderRows = [NSMutableArray array];
    _groupRects = [NSMutableArray array];
    _touchedGroups = [NSMutableSet set];
    for (int i = 0; i < 5; i++) [_groupRects addObject:[NSValue valueWithCGRect:CGRectZero]];
    for (NSString *k in keys) {
        id v = [dom objectForKey:k];
        double a[4] = {0, 0, 0, 0};
        if ([v isKindOfClass:[NSString class]]) {
            [_templates setObject:v forKey:k];
            CCPExtract4(v, a);
        }
        [_frames setObject:[NSValue valueWithBytes:&a objCType:@encode(CGRect)] forKey:k];
    }

    [self loadMetricsAndSizes];

    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat inner = W - 32.0;

    // ---- 固定 header: 预览 + 同步提示 + 模块大小 + 对齐检查 ----
    CGFloat headerH = 16 + 18 + 4 + 190 + 8 + 18 + 2 + 32 + 8 + 30 + 10;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, headerH)];
    [header setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];
    [header setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [host addSubview:header];
    [host setHeader:header];
    [host setHeaderH:headerH];

    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, inner, 18)];
    [pt setText:@"实时预览 (真机同源引擎, 数值随滑条变化)"];
    [pt setFont:[UIFont systemFontOfSize:12.0]];
    [pt setTextColor:[UIColor grayColor]];
    [header addSubview:pt];

    // 预览卡片: 固定可视区, 内容按真机实测尺寸 1:1 建视图后 transform 缩放
    CGFloat cardW = inner, cardH = 190.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 36, cardW, cardH)];
    [card setClipsToBounds:YES];
    [card layer].cornerRadius = 12.0;
    [card layer].masksToBounds = YES;
    [card setBackgroundColor:[UIColor colorWithWhite:0.85 alpha:1.0]];
    [header addSubview:card];

    NSInteger curTier = [[dom objectForKey:TLPXKeyLayoutType] integerValue];
    if (curTier < 0 || curTier > 4) curTier = 2;
    CGSize realSize = [self sizeForTier:curTier];

    _playerView = [[TLPXPlayerContentView alloc] initWithFrame:CGRectMake(0, 0, realSize.width, realSize.height)];
    double s = MIN(cardW / realSize.width, cardH / realSize.height);
    [_playerView setTransform:CGAffineTransformMakeScale((CGFloat)s, (CGFloat)s)];
    [_playerView setCenter:CGPointMake(cardW / 2.0, cardH / 2.0)];
    [card addSubview:_playerView];

    if (!_metricsLoaded) {
        UILabel *warn = [[UILabel alloc] initWithFrame:CGRectMake(8, cardH - 22, cardW - 16, 18)];
        [warn setText:@"⚠ 请先去控制中心打开一次播放器以同步尺寸 (当前为兜底尺寸)"];
        [warn setFont:[UIFont systemFontOfSize:10.0]];
        [warn setTextColor:[UIColor colorWithRed:0.9 green:0.3 blue:0.1 alpha:1.0]];
        [warn setTextAlignment:NSTextAlignmentCenter];
        [card addSubview:warn];
    }

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, 232, inner, 18)];
    [st setText:@"预览模块大小"];
    [st setFont:[UIFont systemFontOfSize:12.0]];
    [st setTextColor:[UIColor grayColor]];
    [header addSubview:st];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"2x2", @"2x3", @"3x2", @"4x2", @"4x3"]];
    [_seg setFrame:CGRectMake(16, 252, inner, 32)];
    [_seg setSelectedSegmentIndex:curTier];
    [_seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:_seg];

    // 对齐检查开关 (阶段三)
    UILabel *al = [[UILabel alloc] initWithFrame:CGRectMake(16, 288, 120, 22)];
    [al setText:@"对齐检查"];
    [al setFont:[UIFont systemFontOfSize:13.0]];
    [header addSubview:al];
    UISwitch *alsw = [[UISwitch alloc] initWithFrame:CGRectMake(W - 68, 286, 51, 31)];
    objc_setAssociatedObject(alsw, &_ccp_assoc_key, @"__align__", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [alsw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:alsw];
    // 复用 _alignSwitch 引用便于开关时输出对照表
    objc_setAssociatedObject(self, &_ccp_align_switch, alsw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // ---- 滚动区 ----
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, headerH, W, host.bounds.size.height - headerH)];
    [scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [scroll setAlwaysBounceVertical:YES];
    [scroll setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];
    [host addSubview:scroll];
    [host setScroll:scroll];

    CGFloat y = 14;
    y = [self addSwitchRowIn:scroll y:y label:@"启用自定义" key:TLPXKeyIsEnableCustomFrame def:NO width:W];
    y = [self addSwitchRowIn:scroll y:y label:@"启用颜色调试" key:TLPXKeyIsEnableColor def:NO width:W];

    // ---- 位置滑条: 5 组 ----
    NSArray *groupNames = @[@"专辑", @"歌词", @"歌曲", @"播放按钮 (三键一体)", @"进度条 (含两边时间)"];
    NSArray *groupKeys = @[
        @[TLPXKeyIconFrame],
        @[TLPXKeyTitleFrame],
        @[TLPXKeySubTitleFrame],
        @[TLPXKeyLeftButtonFrame, TLPXKeyCenterButtonFrame, TLPXKeyRightButtonFrame],
        @[TLPXKeyProgressFrame, TLPXKeyElapsedTitleFrame, TLPXKeyDurationTitleFrame],
    ];
    NSArray *dims = @[@"X", @"Y", @"高", @"宽"];
    for (int g = 0; g < 5; g++) {
        NSArray *ks = groupKeys[g];
        UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
        [h setText:[NSString stringWithFormat:@"%@  (%@)", groupNames[g], [ks componentsJoinedByString:@", "]]];
        [h setFont:[UIFont boldSystemFontOfSize:13.0]];
        [scroll addSubview:h];
        y += 24;

        CGRect gr = CGRectNull;
        for (NSString *k in ks) {
            CGRect cur;
            [[_frames objectForKey:k] getValue:&cur];
            if (cur.size.width <= 0.5 && cur.size.height <= 0.5 &&
                cur.origin.x <= 0.5 && cur.origin.y <= 0.5) continue;
            gr = CGRectIsNull(gr) ? cur : CGRectUnion(gr, cur);
        }
        if (CGRectIsNull(gr)) gr = [self defaultGroupFrame:g size:[self sizeForSelectedTier]];
        [_groupRects replaceObjectAtIndex:g withObject:[NSValue valueWithBytes:&gr objCType:@encode(CGRect)]];

        for (int d = 0; d < 4; d++) {
            double val = (d == 0) ? gr.origin.x : (d == 1) ? gr.origin.y
                       : (d == 2) ? gr.size.height : gr.size.width;
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, y, inner - 78, 30)];
            [sl setMinimumValue:0.0];
            [sl setMaximumValue:(d <= 1) ? 340.0 : 260.0];
            [sl setValue:(float)val];
            UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 5, 70, 20)];
            [vl setText:[NSString stringWithFormat:@"%@ %.1f", dims[d], val]];
            [vl setFont:[UIFont systemFontOfSize:12.0]];
            [vl setTextAlignment:NSTextAlignmentRight];
            [vl setTextColor:[UIColor darkGrayColor]];
            objc_setAssociatedObject(sl, &_ccp_assoc_info,
                                     @{@"gi": @(g), @"idx": @(d), @"dim": dims[d], @"vlabel": vl},
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [scroll addSubview:sl];
            [scroll addSubview:vl];
            y += 34;
        }
        y += 6;
    }

    [self applyAllGroupRects];

    UILabel *fh = [[UILabel alloc] initWithFrame:CGRectMake(16, y, inner, 20)];
    [fh setText:@"字体自定义设置"];
    [fh setFont:[UIFont boldSystemFontOfSize:13.0]];
    [scroll addSubview:fh];
    y += 24;
    NSArray *fkeys = @[TLPXKeyTitleFont, TLPXKeySubtitleFont, TLPXKeyElapsedTitleFont, TLPXKeyDurationTitleFont];
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
        UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 4, 70, 22)];
        [vl setText:[NSString stringWithFormat:@"%.2f", v]];
        [vl setFont:[UIFont systemFontOfSize:12.0]];
        [vl setTextAlignment:NSTextAlignmentRight];
        [vl setTextColor:[UIColor darkGrayColor]];
        objc_setAssociatedObject(sl, &_ccp_assoc_font_idx, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sl, &_ccp_assoc_key, vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sl addTarget:self action:@selector(fontChanged:) forControlEvents:UIControlEventValueChanged];
        [scroll addSubview:sl];
        [scroll addSubview:vl];
        y += 38;
    }

    y += 90;
    [scroll setContentSize:CGSizeMake(W, y + 40)];

    // 主题遮罩同源加载 (Mask/Underlay/Vinyl)
    NSString *maskName = [dom objectForKey:TLPXKeyMaskName];
    if ([maskName length]) {
        NSString *dir = [NSString stringWithFormat:TLPXMaskBundleDirFormat, maskName];
        [_playerView setMaskBundlePath:dir];
    }

    // 背景 = 当前选中素材静态首帧
    NSString *sel = [dom objectForKey:TLPXKeyPlayingAsset] ?: @"";
    NSString *path = [self resolveMaterial:sel];
    if (path) {
        UIImage *thumb = CCGLoadMaterialThumb(path);
        [_playerView.backgroundImageView setImage:thumb];
        CCPLog(@"bg", [NSString stringWithFormat:@"material: %@", path]);
    }

    [self refreshPreview];
}

static char _ccp_align_switch;

- (NSString *)resolveMaterial:(NSString *)selName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *vidExts = @[@"mp4", @"mov", @"m4v"];
    NSArray *imgExts = @[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"bmp", @"tiff"];
    for (NSString *dir in @[TLPXBgDirPlaying, TLPXBgDirBack]) {
        NSArray *all = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSString *first = nil;
        for (NSString *f in all) {
            if (![f length] || [f hasPrefix:@"."]) continue;
            NSString *ext = [[f pathExtension] lowercaseString];
            BOOL isMedia = [vidExts containsObject:ext] || [imgExts containsObject:ext];
            if (!isMedia) continue;
            if (!first) first = f;
            if ([selName length] &&
                ([f isEqualToString:selName] ||
                 [[f stringByDeletingPathExtension] isEqualToString:selName] ||
                 [f hasPrefix:selName])) {
                return [dir stringByAppendingPathComponent:f];
            }
        }
        if (first) return [dir stringByAppendingPathComponent:first];
    }
    return nil;
}

- (CGRect)defaultGroupFrame:(int)g size:(CGSize)ms {
    CGFloat W = ms.width, H = ms.height;
    switch (g) {
        case 0: return CGRectMake(0.04 * W, 0.26 * H, 0.26 * W, 0.42 * H);
        case 1: return CGRectMake(0.34 * W, 0.10 * H, 0.60 * W, 0.22 * H);
        case 2: return CGRectMake(0.34 * W, 0.36 * H, 0.58 * W, 0.16 * H);
        case 3: return CGRectMake(0.28 * W, 0.80 * H, 0.44 * W, 0.14 * H);
        default:return CGRectMake(0.24 * W, 0.62 * H, 0.52 * W, 0.10 * H);
    }
}

- (CGSize)sizeForSelectedTier {
    NSInteger t = [_seg selectedSegmentIndex];
    return [self sizeForTier:t];
}

// 组框 -> 组内各键 frame (模块点坐标; 进度组三键为容器局部坐标)
- (void)applyGroupRect:(int)g {
    NSArray *groupKeys = @[
        @[TLPXKeyIconFrame],
        @[TLPXKeyTitleFrame],
        @[TLPXKeySubTitleFrame],
        @[TLPXKeyLeftButtonFrame, TLPXKeyCenterButtonFrame, TLPXKeyRightButtonFrame],
        @[TLPXKeyProgressFrame, TLPXKeyElapsedTitleFrame, TLPXKeyDurationTitleFrame],
    ];
    CGRect gr;
    [[_groupRects objectAtIndex:g] getValue:&gr];
    CGFloat gx = gr.origin.x, gy = gr.origin.y, gw = gr.size.width, gh = gr.size.height;
    if (g == 3) {
        NSArray *vk = groupKeys[3];
        [self ccpSetKey:vk[0] value:CGRectMake(gx,             gy, gw * 0.28, gh)];
        [self ccpSetKey:vk[1] value:CGRectMake(gx + gw * 0.34, gy, gw * 0.30, gh)];
        [self ccpSetKey:vk[2] value:CGRectMake(gx + gw * 0.70, gy, gw * 0.28, gh)];
        return;
    }
    if (g == 4) {
        // 时间固定 34pt 宽 (不随组宽压扁), 拉伸只作用于进度条
        CGFloat tw = (gw >= 120.0) ? 34.0 : (gw * 0.22);
        CGFloat gap = 4.0;
        [self ccpSetKey:groupKeys[4][0] value:CGRectMake(gx + tw + gap, gy, MAX(gw - 2 * (tw + gap), 10.0), gh)];
        [self ccpSetKey:groupKeys[4][1] value:CGRectMake(gx,             gy, tw, gh)];
        [self ccpSetKey:groupKeys[4][2] value:CGRectMake(gx + gw - tw,   gy, tw, gh)];
        return;
    }
    [self ccpSetKey:groupKeys[g][0] value:gr];
}

- (void)ccpSetKey:(NSString *)k value:(CGRect)v {
    [_frames setObject:[NSValue valueWithCGRect:v] forKey:k];
}

- (void)applyAllGroupRects {
    for (int g = 0; g < 5; g++) [self applyGroupRect:g];
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, &_ccp_assoc_key);
    if ([key isEqualToString:@"__align__"]) {
        [_playerView setAlignmentOverlayVisible:[sw isOn]];
        if ([sw isOn]) [self logDiffTable];
        return;
    }
    [self cc_write:key value:@([sw isOn])];
    [self cc_postNote:TLPXNoteFrameUpdate];
}

- (void)segChanged:(UISegmentedControl *)seg {
    // 切换档位: 重设真机实测尺寸 (无该档位实测则兜底+提示), 重建内容视图
    NSInteger t = [seg selectedSegmentIndex];
    CGSize sz = [self sizeForTier:t];
    [_playerView setFrame:CGRectMake(0, 0, sz.width, sz.height)];
    UIView *card = [_playerView superview];
    if (card) {
        double s = MIN(card.bounds.size.width / sz.width, card.bounds.size.height / sz.height);
        [_playerView setTransform:CGAffineTransformMakeScale((CGFloat)s, (CGFloat)s)];
        [_playerView setCenter:CGPointMake(card.bounds.size.width / 2.0, card.bounds.size.height / 2.0)];
    }
    [self refreshPreview];
}

- (void)sliderChanged:(UISlider *)sl {
    NSDictionary *info = objc_getAssociatedObject(sl, &_ccp_assoc_info);
    if (!info) return;
    int gi = [info[@"gi"] intValue];
    int d = [info[@"idx"] intValue];
    double val = [sl value];
    UILabel *vl = info[@"vlabel"];
    if ([vl isKindOfClass:[UILabel class]]) {
        [vl setText:[NSString stringWithFormat:@"%@ %.1f", info[@"dim"], val]];
    }
    CGRect gr;
    [[_groupRects objectAtIndex:gi] getValue:&gr];
    if (d == 0) gr.origin.x = val;
    else if (d == 1) gr.origin.y = val;
    else if (d == 2) gr.size.height = val;
    else gr.size.width = val;
    [_groupRects replaceObjectAtIndex:gi withObject:[NSValue valueWithBytes:&gr objCType:@encode(CGRect)]];
    [_touchedGroups addObject:@(gi)];
    [self applyGroupRect:gi];
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
    NSArray *groupKeys = @[
        @[TLPXKeyIconFrame],
        @[TLPXKeyTitleFrame],
        @[TLPXKeySubTitleFrame],
        @[TLPXKeyLeftButtonFrame, TLPXKeyCenterButtonFrame, TLPXKeyRightButtonFrame],
        @[TLPXKeyProgressFrame, TLPXKeyElapsedTitleFrame, TLPXKeyDurationTitleFrame],
    ];
    for (int g = 0; g < 5; g++) {
        if (![_touchedGroups containsObject:@(g)]) continue;
        for (NSString *k in groupKeys[g]) {
            CGRect cur;
            [[_frames objectForKey:k] getValue:&cur];
            NSString *tpl = [_templates objectForKey:k];
            if (![tpl length]) {
                for (NSArray *gk in groupKeys) {
                    for (NSString *other in gk) {
                        NSString *t2 = [_templates objectForKey:other];
                        if ([t2 length]) { tpl = t2; break; }
                    }
                    if ([tpl length]) break;
                }
            }
            NSString *val = CCPSubstitute4(tpl, cur.origin.x, cur.origin.y, cur.size.height, cur.size.width);
            [self cc_write:k value:val];
        }
    }
    [self cc_postNote:TLPXNoteFrameUpdate];
}

- (void)fontChanged:(UISlider *)sl {
    int i = [objc_getAssociatedObject(sl, &_ccp_assoc_font_idx) intValue];
    double v = [sl value];
    UILabel *vl = objc_getAssociatedObject(sl, &_ccp_assoc_key);
    if ([vl isKindOfClass:[UILabel class]]) [vl setText:[NSString stringWithFormat:@"%.2f", v]];
    NSArray *fkeys = @[TLPXKeyTitleFont, TLPXKeySubtitleFont, TLPXKeyElapsedTitleFont, TLPXKeyDurationTitleFont];
    [self cc_write:fkeys[i] value:@(v)];
    [self cc_postNote:TLPXNoteFontUpdate];
    [self refreshPreview];
}

- (NSDictionary *)currentFonts {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:TLPXPrefsDomain] ?: @{};
    return @{TLPXKeyTitleFont: [dom objectForKey:TLPXKeyTitleFont] ?: @10.0,
             TLPXKeySubtitleFont: [dom objectForKey:TLPXKeySubtitleFont] ?: @10.0,
             TLPXKeyElapsedTitleFont: [dom objectForKey:TLPXKeyElapsedTitleFont] ?: @10.0,
             TLPXKeyDurationTitleFont: [dom objectForKey:TLPXKeyDurationTitleFont] ?: @10.0};
}

// ---- 预览刷新: 引擎 rectMap → 共享视图; 媒体快照同源取数 ----
- (void)refreshPreview {
    if (!_playerView) return;
    NSInteger tier = [_seg selectedSegmentIndex];
    NSDictionary *rm = [TLPXLayoutEngine rectMapWithSize:[self sizeForSelectedTier]
                                                   tier:(TLPXTier)tier
                                                 frames:_frames
                                            textSamples:nil];
    [_playerView applyLayoutWithRectMap:rm];
    [_playerView applyFonts:[self currentFonts]];
    [_playerView applyMediaSnapshot:[TLPXMediaSnapshot currentSnapshot]];
}

// ---- 对照表: 引擎 rectMap (预览) vs 真机实际 frame (伴随 tweak 导出) ----
- (void)logDiffTable {
    @try {
        NSDictionary *rf = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Documents/ccreal_frames.plist"] ?: @{};
        NSInteger tier = [_seg selectedSegmentIndex];
        NSDictionary *rm = [TLPXLayoutEngine rectMapWithSize:[self sizeForSelectedTier]
                                                       tier:(TLPXTier)tier
                                                     frames:_frames
                                                textSamples:nil];
        NSArray *pKeys = @[TLPXKeyIconFrame, TLPXKeyTitleFrame, TLPXKeySubTitleFrame, TLPXKeyElapsedTitleFrame,
                           TLPXKeyDurationTitleFrame, TLPXKeyProgressFrame, TLPXKeyLeftButtonFrame,
                           TLPXKeyCenterButtonFrame, TLPXKeyRightButtonFrame];
        NSArray *rKeys = @[@"icon", @"title", @"subtitle", @"elapsed", @"duration",
                           @"progress", @"left", @"center", @"right"];
        CCPLog(@"table", [NSString stringWithFormat:@"=== 对照表 (tier %ld) ===", (long)tier]);
        for (int i = 0; i < 9; i++) {
            CGRect real = CGRectFromString([rf objectForKey:rKeys[i]] ?: @"");
            CGRect prev = [[rm objectForKey:pKeys[i]] CGRectValue];
            double dx = fabs(real.origin.x - prev.origin.x);
            double dy = fabs(real.origin.y - prev.origin.y);
            double dw = fabs(real.size.width - prev.size.width);
            double dh = fabs(real.size.height - prev.size.height);
            NSString *verdict = (dx <= 0.5 && dy <= 0.5 && dw <= 0.5 && dh <= 0.5) ? @"OK" : @"FAIL(>0.5)";
            CCPLog(@"table", [NSString stringWithFormat:@"%@ real=%@ prev=%@ d=(%.1f,%.1f,%.1f,%.1f) %@",
                             pKeys[i], NSStringFromCGRect(real), NSStringFromCGRect(prev), dx, dy, dw, dh, verdict]);
        }
        CCPLog(@"table", @"=== 对照表结束 ===");
    } @catch (id e) {}
}

- (CGFloat)addSwitchRowIn:(UIScrollView *)scroll y:(CGFloat)y label:(NSString *)label
                      key:(NSString *)key def:(BOOL)def width:(CGFloat)W {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 6, 180, 24)];
    [l setText:label];
    [l setFont:[UIFont systemFontOfSize:14.0]];
    [scroll addSubview:l];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:TLPXPrefsDomain] ?: @{};
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

- (void)cc_write:(NSString *)key value:(id)val {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *dom = [[ud persistentDomainForName:TLPXPrefsDomain] mutableCopy] ?: [NSMutableDictionary dictionary];
        [dom setObject:val forKey:key];
        [ud setPersistentDomain:dom forName:TLPXPrefsDomain];
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
        objc_setAssociatedObject(self, &_ccp_assoc_built, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        CCPContainerView *container = [[CCPContainerView alloc] initWithFrame:
            CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height)];
        [container setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];

        CCPPageHelper *helper = [[CCPPageHelper alloc] init];
        objc_setAssociatedObject(self, &_ccp_assoc_key, helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [helper buildOnHost:container];

        ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setView:"), container);
        CCPLog(@"page", @"v131 view replaced (shared TLPXPlayerContentView)");
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
    BOOL done = ccp_via_super || ccp_orig_vdl != NULL;
    if (!done && ccp_tries < 120) {
        ccp_tries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CCPRetry();
        });
    }
}

// ---------------- 容器实现 (header/scroll 强制布局 + 安全区) ----------------
@implementation CCPContainerView
- (void)layoutSubviews {
    [super layoutSubviews];
    [self ccpForceLayout];
}
- (void)ccpForceLayout {
    CGRect b = self.bounds;
    CGFloat top = [self safeAreaInsets].top;
    if (top < 20.0) top = 20.0;
    [_header setFrame:CGRectMake(0, top, b.size.width, _headerH)];
    [_scroll setFrame:CGRectMake(0, top + _headerH, b.size.width, MAX(b.size.height - top - _headerH, 100))];
}
@end

@interface CCPBootstrap : NSObject
@end
@implementation CCPBootstrap
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCPRetry();
    });
}
@end
