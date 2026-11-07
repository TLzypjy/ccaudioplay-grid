/**
 * CCALLCustomPage — 自定义设置页 (全模块): 真实内容预览 + 模块大小切换 + 滑条
 *
 * v118:
 *  - 预览 = 真实内容复刻:
 *      背景 = 素材目录里"当前选中"的真实视频/图片 (AVPlayerLooper 循环播放);
 *      专辑 = 黑胶复刻 (主题包有 Vinyl.png/Underlay.png 就用图, 否则画深色圆盘),
 *             圆心贴当前歌曲封面 (MediaRemote, 取不到画蓝色盘标);
 *      进度环/进度条 = 真实进度 (MediaRemote elapsed/duration), 没播放画 35%;
 *      歌词/歌名 = MediaRemote 标题/歌手, 没有则画示例文本; 字体大小走字体滑条;
 *      时间 = 真实 elapsed/duration, 没有画 1:23 / 3:45; 三按钮 = 系统图标。
 *  - 预览+模块大小选择固定在页面顶部 (header), 滑条区独立滚动, 不再有黑边
 *    (不再套深色容器, 直接渲染模块圆角矩形)。
 *  - MediaRemote 在 loader 里嵌入了 com.apple.mediaremote.get-now-playing-info
 *    entitlement (repack 时 ldid -S 签入), iOS16 未授权进程拿不到时自动走自绘。
 *  - 调试日志: /var/mobile/Documents/ccpre_debug.log
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define CCP_DOMAIN @"com.thefool.ccaudioplaypres"
#define CCP_NOTE_FRAME @"com.thefool.ccaudioplaypres/updateCustomFrameNotificationt"
#define CCP_NOTE_FONT  @"com.thefool.ccaudioplaypres/updateCustomFontNotificationt"
#define CCP_BG_DIR_PLAY @"/var/mobile/CCAudioPlay-BackGround/PlayingAsset"
#define CCP_BG_DIR_BACK @"/var/mobile/CCAudioPlay-BackGround/BackAsset"
#define CCP_MASK_DIR    @"/var/mobile/Library/Application Support/CCAudioPlay/CCAudioPlay-Mask-N95"

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

// ---------------- AVF (dlopen + 运行时调用, 不做静态引用) ----------------
static void *ccp_avf = NULL;
static void CCPEnsureAVF(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
        ccp_avf = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    });
}

// ---------------- MediaRemote (dlopen + dlsym; 拿不到返回 NO) ----------------
static void *ccp_mr = NULL;
static void CCPEnsureMR(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ccp_mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
}

// ---------------- 素材解析 ----------------
// 依据 prefs 里选中的素材名, 在素材目录中定位真实文件 (视频或图片); 找不到取第一个媒体文件
static NSString *CCPResolveMaterial(NSString *dir, NSString *selName, BOOL *isVideo) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *all = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSArray *vidExts = @[@"mp4", @"mov", @"m4v"];
    NSArray *imgExts = @[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"bmp", @"tiff"];
    NSString *first = nil;
    BOOL firstIsVideo = NO;
    for (NSString *f in all) {
        if (![f length] || [f hasPrefix:@"."]) continue;
        NSString *ext = [[f pathExtension] lowercaseString];
        BOOL isV = [vidExts containsObject:ext];
        BOOL isI = [imgExts containsObject:ext];
        if (!isV && !isI) continue;
        if (!first) { first = f; firstIsVideo = isV; }
        if ([selName length]) {
            if ([f isEqualToString:selName] ||
                [[f stringByDeletingPathExtension] isEqualToString:selName] ||
                [f hasPrefix:selName]) {
                if (isVideo) *isVideo = isV;
                return [dir stringByAppendingPathComponent:f];
            }
        }
    }
    if (first) { if (isVideo) *isVideo = firstIsVideo; return [dir stringByAppendingPathComponent:first]; }
    return nil;
}

// 网格素材库 (ccgrid.mm) 提供的素材静态首帧加载 (带磁盘缓存)
extern UIImage *CCGLoadMaterialThumb(NSString *path);

// ---------------- 复刻预览视图 ----------------
@interface CCPReplicaView : UIView
- (void)updateWithModule:(int)module frames:(NSDictionary *)frames fonts:(NSDictionary *)fonts;
- (void)setNowTitle:(NSString *)t artist:(NSString *)a elapsed:(double)e duration:(double)d artwork:(UIImage *)img live:(BOOL)live;
- (void)loadBackgroundMaterial;
@end

@implementation CCPReplicaView {
    UIView *_mod;
    UIView *_bgHolder;          // 背景视频/图片
    id _player;                 // AVQueuePlayer (retain)
    id _looper;                 // AVPlayerLooper
    id _playerLayer;            // AVPlayerLayer
    UIImageView *_bgImageView;

    UIView *_iconView;          // 专辑 = 黑胶 + 封面 + 进度环
    UIImageView *_themeImg;     // 主题包 Vinyl.png / Underlay.png (若有)
    UIView *_discView;          // 画的深色圆盘
    UIImageView *_artView;      // 封面圆
    CAShapeLayer *_ringTrack;
    CAShapeLayer *_ringProg;

    UILabel *_titleLabel;       // 歌词
    UILabel *_subtitleLabel;    // 歌曲
    UILabel *_elapsedLabel;     // 当前时间
    UILabel *_durationLabel;    // 总时间
    UIView *_progTrack;
    UIView *_progFill;
    UIImageView *_btnL;
    UIImageView *_btnC;
    UIImageView *_btnR;

    int _module;
    double _fraction;           // 0..1
}

- (id)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        [self setBackgroundColor:[UIColor clearColor]];
        _mod = [[UIView alloc] initWithFrame:f];
        [_mod.layer setCornerRadius:12.0];
        [_mod.layer setMasksToBounds:YES];
        [_mod.layer setBorderWidth:1.0];
        [_mod.layer setBorderColor:[UIColor colorWithWhite:0.75 alpha:1.0].CGColor];
        [_mod setBackgroundColor:[UIColor colorWithWhite:0.30 alpha:1.0]];
        [self addSubview:_mod];

        _bgHolder = [[UIView alloc] initWithFrame:_mod.bounds];
        [_bgHolder setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [_mod addSubview:_bgHolder];

        _iconView = [[UIView alloc] initWithFrame:CGRectZero];
        [_mod addSubview:_iconView];

        _themeImg = [[UIImageView alloc] initWithFrame:_iconView.bounds];
        [_themeImg setContentMode:UIViewContentModeScaleAspectFit];
        [_iconView addSubview:_themeImg];

        _discView = [[UIView alloc] initWithFrame:CGRectZero];
        [_discView setBackgroundColor:[UIColor colorWithWhite:0.10 alpha:1.0]];
        [_discView.layer setCornerRadius:1000.0];
        [_discView.layer setBorderWidth:1.0];
        [_discView.layer setBorderColor:[UIColor colorWithWhite:1.0 alpha:0.25].CGColor];
        [_iconView addSubview:_discView];

        _artView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [_artView setContentMode:UIViewContentModeScaleAspectFill];
        [_artView setClipsToBounds:YES];
        [_artView.layer setCornerRadius:1000.0];
        [_artView setBackgroundColor:[UIColor colorWithRed:0.15 green:0.45 blue:0.95 alpha:1.0]];
        [_iconView addSubview:_artView];

        _ringTrack = [CAShapeLayer layer];
        [_ringTrack setStrokeColor:[UIColor colorWithWhite:1.0 alpha:0.30].CGColor];
        [_ringTrack setFillColor:[UIColor clearColor].CGColor];
        [_ringTrack setLineWidth:2.5];
        [_iconView.layer addSublayer:_ringTrack];

        _ringProg = [CAShapeLayer layer];
        [_ringProg setStrokeColor:[UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0].CGColor];
        [_ringProg setFillColor:[UIColor clearColor].CGColor];
        [_ringProg setLineWidth:2.5];
        [_ringProg setLineCap:kCALineCapRound];
        [_iconView.layer addSublayer:_ringProg];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_titleLabel setText:@"歌名示例文本"];
        [_titleLabel setTextColor:[UIColor whiteColor]];
        [_titleLabel setFont:[UIFont systemFontOfSize:10.0]];
        [_titleLabel.layer setShadowColor:[UIColor blackColor].CGColor];
        [_titleLabel.layer setShadowOpacity:0.6];
        [_titleLabel.layer setShadowRadius:2.0];
        [_titleLabel.layer setShadowOffset:CGSizeMake(0, 1)];
        [_mod addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_subtitleLabel setText:@"歌手名示例"];
        [_subtitleLabel setTextColor:[UIColor colorWithWhite:1.0 alpha:0.9]];
        [_subtitleLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_subtitleLabel.layer setShadowColor:[UIColor blackColor].CGColor];
        [_subtitleLabel.layer setShadowOpacity:0.6];
        [_subtitleLabel.layer setShadowRadius:2.0];
        [_subtitleLabel.layer setShadowOffset:CGSizeMake(0, 1)];
        [_mod addSubview:_subtitleLabel];

        _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_elapsedLabel setText:@"1:23"];
        [_elapsedLabel setTextColor:[UIColor whiteColor]];
        [_elapsedLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_mod addSubview:_elapsedLabel];

        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_durationLabel setText:@"3:45"];
        [_durationLabel setTextColor:[UIColor whiteColor]];
        [_durationLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_mod addSubview:_durationLabel];

        _progTrack = [[UIView alloc] initWithFrame:CGRectZero];
        [_progTrack setBackgroundColor:[UIColor colorWithWhite:1.0 alpha:0.30]];
        [_progTrack.layer setCornerRadius:1.4];
        [_mod addSubview:_progTrack];
        _progFill = [[UIView alloc] initWithFrame:CGRectZero];
        [_progFill setBackgroundColor:[UIColor whiteColor]];
        [_progFill.layer setCornerRadius:1.4];
        [_mod addSubview:_progFill];

        NSArray *syms = @[@"backward.fill", @"pause.fill", @"forward.fill"];
        UIImageView *b1 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *b2 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *b3 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *btns[3] = {b1, b2, b3};
        for (int i = 0; i < 3; i++) {
            UIImageView *iv = btns[i];
            UIImage *img = [UIImage systemImageNamed:syms[i]];
            [iv setImage:img];
            [iv setContentMode:UIViewContentModeScaleAspectFit];
            [iv setTintColor:[UIColor whiteColor]];
            if (i == 0) _btnL = iv;
            else if (i == 1) _btnC = iv;
            else _btnR = iv;
            [_mod addSubview:iv];
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

- (void)loadBackgroundMaterial {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:CCP_DOMAIN] ?: @{};
    NSString *sel = [dom objectForKey:@"PlayingAsset"];
    BOOL isVideo = NO;
    NSString *path = CCPResolveMaterial(CCP_BG_DIR_PLAY, sel, &isVideo);
    if (!path) path = CCPResolveMaterial(CCP_BG_DIR_BACK, nil, &isVideo);
    CCPLog(@"bg", path ? [NSString stringWithFormat:@"material: %@", path] : @"no material found");

    // 清掉旧背景
    for (UIView *sv in [_bgHolder subviews]) [sv removeFromSuperview];
    _player = nil;
    _looper = nil;
    _playerLayer = nil;

    if (!path) return;

    // v124: 只显示当前选中素材的静态首帧/图片, 不再播视频
    // (设置进程里起 AVPlayer 激活音频会话会打断正在放的歌; 静态图由网格库的缓存逻辑秒出)
    UIImage *img = CCGLoadMaterialThumb(path);
    if (!img) {
        CCPLog(@"bg", @"thumb decode failed");
        return;
    }
    UIImageView *iv = [[UIImageView alloc] initWithFrame:_bgHolder.bounds];
    [iv setImage:img];
    [iv setContentMode:UIViewContentModeScaleAspectFill];
    [iv setClipsToBounds:YES];
    [iv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [_bgHolder addSubview:iv];
}

- (void)setThemeImage:(UIImage *)img {
    [_themeImg setImage:img];
}

- (void)setNowTitle:(NSString *)t artist:(NSString *)a elapsed:(double)e duration:(double)d artwork:(UIImage *)img live:(BOOL)live {
    [_titleLabel setText:([t length] ? t : @"歌名示例文本")];
    [_subtitleLabel setText:([a length] ? a : @"歌手名示例")];
    if (live && d > 0.5) {
        int em = (int)e, dm = (int)d;
        [_elapsedLabel setText:[NSString stringWithFormat:@"%d:%02d", em / 60, em % 60]];
        [_durationLabel setText:[NSString stringWithFormat:@"%d:%02d", dm / 60, dm % 60]];
        _fraction = (e > 0 && d > 0) ? MIN(1.0, e / d) : 0.0;
    } else {
        [_elapsedLabel setText:@"1:23"];
        [_durationLabel setText:@"3:45"];
        _fraction = 0.35;
    }
    if (img) [_artView setImage:img];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)updateWithModule:(int)module frames:(NSDictionary *)frames fonts:(NSDictionary *)fonts {
    _module = module;
    CGSize ms = [self moduleSize:module];
    double availW = [self bounds].size.width - 16.0;
    double availH = [self bounds].size.height - 16.0;
    double sc = MIN(availW / ms.width, availH / ms.height);
    CGSize show = CGSizeMake(ms.width * sc, ms.height * sc);
    [_mod setFrame:CGRectMake(([self bounds].size.width - show.width) / 2.0,
                              ([self bounds].size.height - show.height) / 2.0,
                              show.width, show.height)];
    if (_playerLayer) {
        [(CALayer *)_playerLayer setFrame:_bgHolder.bounds];
    }

    NSArray *order = @[@"iconFrame", @"titleFrame", @"subTitleFrame", @"elapsedTitleFrame",
                       @"durationTitleFrame", @"progressFrame", @"leftButtonFrame",
                       @"centerButtonFrame", @"rightButtonFrame"];
    UIView *views[9] = {_iconView, _titleLabel, _subtitleLabel, _elapsedLabel, _durationLabel,
                        _progTrack, _btnL, _btnC, _btnR};
    for (int i = 0; i < 9; i++) {
        NSValue *fv = frames[order[i]];
        UIView *v = views[i];
        CGRect fr;
        BOOL unset = NO;
        if (!fv) {
            unset = YES;
        } else {
            fr = [fv CGRectValue];
            if (fr.size.width <= 0.5 && fr.size.height <= 0.5 &&
                fr.origin.x <= 0.5 && fr.origin.y <= 0.5) unset = YES;
        }
        // 全部元素常驻显示: 未设置位置的用默认排布, 方便用户看到要调的东西
        if (unset) fr = [self defaultFrame:i size:ms];
        [v setHidden:NO];
        CGRect scaled = CGRectMake(fr.origin.x * sc, fr.origin.y * sc,
                                   fr.size.width * sc, fr.size.height * sc);
        [v setFrame:scaled];

        if (i == 0) {
            // 黑胶布局: 盘 + 封面 + 环 (取短边画圆)
            double side = MIN(scaled.size.width, scaled.size.height);
            double cx = scaled.origin.x + scaled.size.width / 2.0;
            double cy = scaled.origin.y + scaled.size.height / 2.0;
            double discSide = side * 0.72;
            [_discView setFrame:CGRectMake(cx - discSide / 2, cy - discSide / 2, discSide, discSide)];
            [_themeImg setFrame:CGRectMake(0, 0, scaled.size.width, scaled.size.height)];
            double artSide = discSide * 0.42;
            [_artView setFrame:CGRectMake(cx - artSide / 2, cy - artSide / 2, artSide, artSide)];
            // 环: path 用 _mod 坐标系, layer frame 对齐 _mod
            // 注意: 不要 release layer.path 的旧值 (getter 返回非持有引用),
            // v118 每秒刷新时对它 CGPathRelease 造成过度释放 -> setPath CFEqual 野指针崩溃
            CGMutablePathRef path = CGPathCreateMutable();
            double r = side / 2.0 - 1.5;
            CGPathAddEllipseInRect(path, NULL, CGRectMake(cx - r, cy - r, r * 2, r * 2));
            [_ringTrack setPath:path];
            [_ringProg setPath:path];
            CGPathRelease(path);
            [_ringTrack setFrame:CGRectMake(0, 0, _mod.bounds.size.width, _mod.bounds.size.height)];
            [_ringProg setFrame:CGRectMake(0, 0, _mod.bounds.size.width, _mod.bounds.size.height)];
            double frac = (_fraction > 0.001) ? _fraction : 0.0;
            [_ringProg setStrokeStart:0.0];
            [_ringProg setStrokeEnd:(CGFloat)MAX(frac, 0.02)];
        } else if (i == 5) {
            // 进度条: 轨道 + 填充
            [_progTrack setFrame:scaled];
            [_progFill setFrame:CGRectMake(scaled.origin.x, scaled.origin.y,
                                           scaled.size.width * _fraction, scaled.size.height)];
        }
    }

    // 进度条填充在轨道之上
    [_mod bringSubviewToFront:_progFill];

    // 字体
    double tf = [fonts[@"titleFont"] doubleValue];
    double sf = [fonts[@"subtitleFont"] doubleValue];
    double ef = [fonts[@"elapsedTitleFont"] doubleValue];
    double df = [fonts[@"durationTitleFont"] doubleValue];
    if (tf >= 4) [_titleLabel setFont:[UIFont systemFontOfSize:tf]];
    if (sf >= 4) [_subtitleLabel setFont:[UIFont systemFontOfSize:sf]];
    if (ef >= 4) [_elapsedLabel setFont:[UIFont systemFontOfSize:ef]];
    if (df >= 4) [_durationLabel setFont:[UIFont systemFontOfSize:df]];
}

// 未设置 frame 时的默认排布 (按模块尺寸比例), 让所有元素都可见可调
- (CGRect)defaultFrame:(int)i size:(CGSize)ms {
    CGFloat W = ms.width, H = ms.height;
    switch (i) {
        case 0: return CGRectMake(0.04 * W, 0.26 * H, 0.26 * W, 0.42 * H);   // 专辑
        case 1: return CGRectMake(0.34 * W, 0.10 * H, 0.60 * W, 0.22 * H);   // 歌词
        case 2: return CGRectMake(0.34 * W, 0.36 * H, 0.58 * W, 0.16 * H);   // 歌曲
        case 3: return CGRectMake(0.34 * W, 0.76 * H, 0.15 * W, 0.12 * H);   // 当前时间
        case 4: return CGRectMake(0.81 * W, 0.76 * H, 0.15 * W, 0.12 * H);   // 总时间
        case 5: return CGRectMake(0.34 * W, 0.64 * H, 0.60 * W, 3.0);        // 进度条
        case 6: return CGRectMake(0.34 * W, 0.86 * H, 0.10 * W, 0.12 * H);   // 左按钮
        case 7: return CGRectMake(0.45 * W, 0.86 * H, 0.10 * W, 0.12 * H);   // 中按钮
        case 8: return CGRectMake(0.56 * W, 0.86 * H, 0.10 * W, 0.12 * H);   // 右按钮
    }
    return CGRectZero;
}

@end

// ---------------- 页面 ----------------
@interface CCPPageHelper : NSObject
@property (nonatomic, retain) CCPReplicaView *replica;
@property (nonatomic, retain) UISegmentedControl *seg;
@property (nonatomic, retain) NSMutableDictionary *frames;
@property (nonatomic, retain) NSMutableDictionary *templates;
@property (nonatomic, retain) NSMutableArray *sliderRows;
@property (nonatomic, retain) NSTimer *saveTimer;
@property (nonatomic, retain) NSTimer *nowTimer;
@property (nonatomic, assign) BOOL frameDirty;
@property (nonatomic, assign) BOOL nowLive;
@property (nonatomic, copy) NSString *nowTitle;
@property (nonatomic, copy) NSString *nowArtist;
@property (nonatomic, assign) double nowElapsed;
@property (nonatomic, assign) double nowDuration;
@property (nonatomic, retain) UIImage *nowArt;
@end

@implementation CCPPageHelper

- (NSDictionary *)currentFonts {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dom = [ud persistentDomainForName:CCP_DOMAIN] ?: @{};
    return @{@"titleFont": [dom objectForKey:@"titleFont"] ?: @10.0,
             @"subtitleFont": [dom objectForKey:@"subtitleFont"] ?: @10.0,
             @"elapsedTitleFont": [dom objectForKey:@"elapsedTitleFont"] ?: @10.0,
             @"durationTitleFont": [dom objectForKey:@"durationTitleFont"] ?: @10.0};
}

- (void)buildOnHost:(CCPContainerView *)host {
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

    // ---- 固定 header: 预览 + 模块大小 ----
    CGFloat headerH = 16 + 18 + 4 + 190 + 8 + 18 + 2 + 32 + 10;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, headerH)];
    [header setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];
    [header setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [host addSubview:header];
    [host setHeader:header];
    [host setHeaderH:headerH];

    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, inner, 18)];
    [pt setText:@"实时预览 (真实素材/主题/字体, 数值随滑条变化)"];
    [pt setFont:[UIFont systemFontOfSize:12.0]];
    [pt setTextColor:[UIColor grayColor]];
    [header addSubview:pt];

    _replica = [[CCPReplicaView alloc] initWithFrame:CGRectMake(16, 36, inner, 190)];
    [header addSubview:_replica];
    [_replica loadBackgroundMaterial];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, 232, inner, 18)];
    [st setText:@"预览模块大小"];
    [st setFont:[UIFont systemFontOfSize:12.0]];
    [st setTextColor:[UIColor grayColor]];
    [header addSubview:st];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"2x2", @"2x3", @"3x2", @"4x2", @"4x3"]];
    [_seg setFrame:CGRectMake(16, 252, inner, 32)];
    // 默认显示当前实际使用的模块尺寸 (LayoutType), 而不是固定 3x2
    NSInteger lt = [[dom objectForKey:@"LayoutType"] integerValue];
    if (lt < 0 || lt > 4) lt = 2;
    [_seg setSelectedSegmentIndex:lt];
    [_seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:_seg];

    // ---- 滚动区: 开关 + 滑条 ----
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, headerH, W, host.bounds.size.height - headerH)];
    [scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [scroll setAlwaysBounceVertical:YES];
    [scroll setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];
    [host addSubview:scroll];
    [host setScroll:scroll];

    CGFloat y = 14;
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
            UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner - 70, y + 5, 70, 20)];
            [vl setText:[NSString stringWithFormat:@"%@ %.1f", dims[d], val]];
            [vl setFont:[UIFont systemFontOfSize:12.0]];
            [vl setTextAlignment:NSTextAlignmentRight];
            [vl setTextColor:[UIColor darkGrayColor]];
            objc_setAssociatedObject(sl, &_ccp_assoc_info,
                                     @{@"key": k, @"idx": @(d), @"dim": dims[d], @"vlabel": vl},
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [scroll addSubview:sl];
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

    y += 90;   // 底部大余量, 保证最后一行完整可见
    [scroll setContentSize:CGSizeMake(W, y + 40)];

    // 主题图 (Vinyl.png 若有)
    NSString *maskName = [dom objectForKey:@"MaskName"];
    if ([maskName length]) {
        NSString *bundleDir = [NSString stringWithFormat:@"%@/%@.bundle", CCP_MASK_DIR, maskName];
        NSString *vinyl = [bundleDir stringByAppendingPathComponent:@"Vinyl.png"];
        NSString *under = [bundleDir stringByAppendingPathComponent:@"Underlay.png"];
        NSString *use = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:vinyl]) use = vinyl;
        else if ([[NSFileManager defaultManager] fileExistsAtPath:under]) use = under;
        if (use) {
            UIImage *img = [UIImage imageWithContentsOfFile:use];
            [_replica setThemeImage:img];
            CCPLog(@"theme", [NSString stringWithFormat:@"theme image: %@", use]);
        }
    }

    [self refreshReplica];
    [self fetchNowPlaying];
    // 播放进度不刷新 (用户要求): 只在进入页面时取一次播放信息, 不再起定时器
}

- (void)fetchNowPlaying {
    @try {
        CCPEnsureMR();
        if (!ccp_mr) { [self applyNow:NO]; return; }
        void (*MRGNI)(dispatch_queue_t, void (^)(CFDictionaryRef)) =
            (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(ccp_mr, "MRMediaRemoteGetNowPlayingInfo");
        if (!MRGNI) { [self applyNow:NO]; return; }
        dispatch_queue_t q = dispatch_get_global_queue(0, 0);
        MRGNI(q, ^(CFDictionaryRef info) {
            @try {
                if (!info) { dispatch_async(dispatch_get_main_queue(), ^{ [self applyNow:NO]; }); return; }
                NSDictionary *d = (__bridge NSDictionary *)info;
                NSString *title = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSString *artist = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtist"];
                double elapsed = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                double duration = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
                NSData *art = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                UIImage *img = art ? [UIImage imageWithData:art] : nil;
                BOOL live = ([title length] > 0 || duration > 0.5);
                dispatch_async(dispatch_get_main_queue(), ^{
                    _nowTitle = title ?: @"";
                    _nowArtist = artist ?: @"";
                    _nowElapsed = elapsed;
                    _nowDuration = duration;
                    _nowArt = img;
                    [self applyNow:live];
                });
            } @catch (id e) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self applyNow:NO]; });
            }
        });
    } @catch (id e) {
        [self applyNow:NO];
    }
}

- (void)applyNow:(BOOL)live {
    _nowLive = live;
    [self refreshReplica];
}

- (void)refreshReplica {
    if (!_replica) return;
    BOOL live = _nowLive && (_nowDuration > 0.5 || [_nowTitle length] > 0);
    [_replica setNowTitle:_nowTitle artist:_nowArtist
                  elapsed:_nowElapsed duration:_nowDuration
                  artwork:_nowArt live:live];
    [_replica updateWithModule:(int)[_seg selectedSegmentIndex] frames:_frames fonts:[self currentFonts]];
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
    [self refreshReplica];
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
    [self refreshReplica];
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
    [self refreshReplica];
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

@end

// ---------------- swizzle: CCAudio3x2ListController viewDidLoad ----------------
static void (*ccp_orig_vdl)(id, SEL) = NULL;
static BOOL ccp_via_super = NO;
static int ccp_tries = 0;

// ---------------- 容器实现 ----------------
@implementation CCPContainerView
- (void)layoutSubviews {
    [super layoutSubviews];
    [self ccpForceLayout];
}
- (void)ccpForceLayout {
    CGRect b = self.bounds;
    // 安全区: 设置页视图全屏, 状态栏+导航条是半透明压在上面的, header 要让开
    CGFloat top = [self safeAreaInsets].top;
    if (top < 20.0) top = 20.0;
    [_header setFrame:CGRectMake(0, top, b.size.width, _headerH)];
    [_scroll setFrame:CGRectMake(0, top + _headerH, b.size.width, MAX(b.size.height - top - _headerH, 100))];
}
@end

static void CCPBuildOver(id self) {
    @try {
        if (objc_getAssociatedObject(self, &_ccp_assoc_built)) return;
        UIView *host = nil;
        if ([self respondsToSelector:@selector(view)]) {
            host = ((UIView *(*)(id, SEL))objc_msgSend)(self, sel_registerName("view"));
        }
        objc_setAssociatedObject(self, &_ccp_assoc_built, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // v121: 容器用自定义布局类, header/scroll 几何在每次 layoutSubviews 强制摆放;
        // 内容尺寸取屏幕绝对值, 不依赖构建时 host 的状态。
        CCPContainerView *container = [[CCPContainerView alloc] initWithFrame:
            CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height)];
        [container setBackgroundColor:[UIColor colorWithWhite:0.94 alpha:1.0]];

        CCPPageHelper *helper = [[CCPPageHelper alloc] init];
        objc_setAssociatedObject(self, &_ccp_assoc_key, helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [helper buildOnHost:container];

        ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setView:"), container);

        CCPLog(@"page", [NSString stringWithFormat:@"view replaced; self.view=%@ frame=%@ header=%@ scroll=%@",
               [[self view] class], NSStringFromCGRect([[self view] frame]),
               NSStringFromCGRect([container.header frame]), NSStringFromCGRect([container.scroll frame])]);

        // 0.6s 后复查: 视图层级真相 (self.view 是否还是我们的容器, 在不在窗口上)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(self, sel_registerName("view"));
                UIView *sup = [container superview];
                CCPLog(@"diag", [NSString stringWithFormat:@"t+0.6s self.view=%@ frame=%@ window=%@ "
                                 @"containerInWindow=%d container.super=%@ header.frame=%@ scroll.frame=%@ scroll.offset=%@ content=%@",
                                 [v class], NSStringFromCGRect(v.frame), v.window,
                                 container.window != nil,
                                 sup ? NSStringFromClass([sup class]) : @"nil",
                                 NSStringFromCGRect([container.header frame]),
                                 NSStringFromCGRect([container.scroll frame]),
                                 NSStringFromCGPoint([container.scroll contentOffset]),
                                 NSStringFromCGSize([container.scroll contentSize])]);
            } @catch (id e) {}
        });
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

@interface CCPBootstrap : NSObject
@end
@implementation CCPBootstrap
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCPRetry();
    });
}
@end
