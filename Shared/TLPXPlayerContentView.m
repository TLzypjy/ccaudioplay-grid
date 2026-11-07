//
//  TLPXPlayerContentView.m
//  数据驱动的内容视图: 全部子视图 frame 只来自 applyLayoutWithRectMap: (引擎输出)。
//  字体统一 systemFontOfSize:, 关闭 adjustsFontSizeToFitWidth / minimumScaleFactor /
//  allowsDefaultTighteningForTruncation; 跑马灯速度按 pt/s (TLPXMarqueeSpeed)。
//

#import "TLPXPlayerContentView.h"
#import "TLPXMediaSnapshot.h"
#import "TLPXConstants.h"

@interface TLPXPlayerContentView ()

// 层级顺序 = 真机渲染顺序
@property (nonatomic, retain) UIImageView *backgroundImageView;   // 背景 (静态素材帧)
@property (nonatomic, retain) CALayer *bgMaskLayer;               // 主题 Mask.png (背景蒙版)
@property (nonatomic, retain) UIImageView *underlayImageView;     // 主题 Underlay.png
@property (nonatomic, retain) UIView *iconContainer;              // 专辑容器
@property (nonatomic, retain) UIImageView *vinylDiscView;         // 黑胶盘 (Vinyl.png 或画盘)
@property (nonatomic, retain) UIImageView *vinylArtView;          // 黑胶中心封面 (圆)
@property (nonatomic, retain) CAShapeLayer *ringTrack;
@property (nonatomic, retain) CAShapeLayer *ringProg;
@property (nonatomic, retain) UIView *titleMarquee;               // 歌词跑马灯容器
@property (nonatomic, retain) UILabel *titleLabel;
@property (nonatomic, retain) UIView *subtitleMarquee;            // 歌曲跑马灯容器
@property (nonatomic, retain) UILabel *subtitleLabel;
@property (nonatomic, retain) UILabel *elapsedLabel;
@property (nonatomic, retain) UILabel *durationLabel;
@property (nonatomic, retain) UIView *barTrack;
@property (nonatomic, retain) UIView *barFill;
@property (nonatomic, retain) UIImageView *btnLeft;
@property (nonatomic, retain) UIImageView *btnCenter;
@property (nonatomic, retain) UIImageView *btnRight;
@property (nonatomic, retain) UIView *overlay;                    // 对齐检查叠加层
@property (nonatomic, assign) double fraction;                    // 播放进度 0..1
@property (nonatomic, retain) NSMutableDictionary *lastRectMap;   // 上次布局 (叠加层重建用)

- (void)ccpSetupMarquee:(UIView *)container label:(UILabel *)lab;
- (void)ccpRebuildOverlay;

@end

@implementation TLPXPlayerContentView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setClipsToBounds:YES];

        _backgroundImageView = [[UIImageView alloc] initWithFrame:frame];
        [_backgroundImageView setContentMode:UIViewContentModeScaleAspectFill];
        [_backgroundImageView setClipsToBounds:YES];
        [_backgroundImageView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [self addSubview:_backgroundImageView];

        _underlayImageView = [[UIImageView alloc] initWithFrame:frame];
        [_underlayImageView setContentMode:UIViewContentModeScaleAspectFit];
        [_underlayImageView setClipsToBounds:YES];
        [_underlayImageView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [self addSubview:_underlayImageView];

        _iconContainer = [[UIView alloc] initWithFrame:CGRectZero];
        [self addSubview:_iconContainer];

        _vinylDiscView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [_vinylDiscView setContentMode:UIViewContentModeScaleAspectFill];
        [_vinylDiscView setClipsToBounds:YES];
        [_vinylDiscView.layer setCornerRadius:1000.0];
        [_vinylDiscView setBackgroundColor:[UIColor colorWithWhite:0.10 alpha:1.0]];
        [_iconContainer addSubview:_vinylDiscView];

        _vinylArtView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [_vinylArtView setContentMode:UIViewContentModeScaleAspectFill];
        [_vinylArtView setClipsToBounds:YES];
        [_vinylArtView.layer setCornerRadius:1000.0];
        [_vinylArtView setBackgroundColor:[UIColor colorWithRed:0.15 green:0.45 blue:0.95 alpha:1.0]];
        [_iconContainer addSubview:_vinylArtView];

        _ringTrack = [CAShapeLayer layer];
        [_ringTrack setStrokeColor:[UIColor colorWithWhite:1.0 alpha:0.30].CGColor];
        [_ringTrack setFillColor:[UIColor clearColor].CGColor];
        [_ringTrack setLineWidth:2.5];
        [_iconContainer.layer addSublayer:_ringTrack];

        _ringProg = [CAShapeLayer layer];
        [_ringProg setStrokeColor:[UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0].CGColor];
        [_ringProg setFillColor:[UIColor clearColor].CGColor];
        [_ringProg setLineWidth:2.5];
        [_ringProg setLineCap:kCALineCapRound];
        [_iconContainer.layer addSublayer:_ringProg];

        _titleMarquee = [[UIView alloc] initWithFrame:CGRectZero];
        [_titleMarquee setClipsToBounds:YES];
        [self addSubview:_titleMarquee];
        _titleLabel = [[UILabel alloc] initWithFrame:_titleMarquee.bounds];
        [_titleLabel setTextColor:[UIColor whiteColor]];
        [_titleLabel setFont:[UIFont systemFontOfSize:10.0]];
        [_titleLabel setAutoresizingMask:UIViewAutoresizingFlexibleHeight];
        [_titleLabel setAdjustsFontSizeToFitWidth:NO];
        [_titleLabel.layer setShadowColor:[UIColor blackColor].CGColor];
        [_titleLabel.layer setShadowOpacity:0.6];
        [_titleLabel.layer setShadowRadius:2.0];
        [_titleLabel.layer setShadowOffset:CGSizeMake(0, 1)];
        [_titleMarquee addSubview:_titleLabel];

        _subtitleMarquee = [[UIView alloc] initWithFrame:CGRectZero];
        [_subtitleMarquee setClipsToBounds:YES];
        [self addSubview:_subtitleMarquee];
        _subtitleLabel = [[UILabel alloc] initWithFrame:_subtitleMarquee.bounds];
        [_subtitleLabel setTextColor:[UIColor colorWithWhite:1.0 alpha:0.9]];
        [_subtitleLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_subtitleLabel setAutoresizingMask:UIViewAutoresizingFlexibleHeight];
        [_subtitleLabel setAdjustsFontSizeToFitWidth:NO];
        [_subtitleLabel.layer setShadowColor:[UIColor blackColor].CGColor];
        [_subtitleLabel.layer setShadowOpacity:0.6];
        [_subtitleLabel.layer setShadowRadius:2.0];
        [_subtitleLabel.layer setShadowOffset:CGSizeMake(0, 1)];
        [_subtitleMarquee addSubview:_subtitleLabel];

        _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_elapsedLabel setText:@"1:23"];
        [_elapsedLabel setTextColor:[UIColor whiteColor]];
        [_elapsedLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_elapsedLabel setAdjustsFontSizeToFitWidth:NO];
        [self addSubview:_elapsedLabel];

        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [_durationLabel setText:@"3:45"];
        [_durationLabel setTextColor:[UIColor whiteColor]];
        [_durationLabel setFont:[UIFont systemFontOfSize:9.0]];
        [_durationLabel setAdjustsFontSizeToFitWidth:NO];
        [self addSubview:_durationLabel];

        _barTrack = [[UIView alloc] initWithFrame:CGRectZero];
        [_barTrack setBackgroundColor:[UIColor colorWithWhite:1.0 alpha:0.30]];
        [_barTrack.layer setCornerRadius:1.4];
        [self addSubview:_barTrack];
        _barFill = [[UIView alloc] initWithFrame:CGRectZero];
        [_barFill setBackgroundColor:[UIColor whiteColor]];
        [_barFill.layer setCornerRadius:1.4];
        [self addSubview:_barFill];

        NSArray *syms = @[@"backward.fill", @"pause.fill", @"forward.fill"];
        UIImageView *b1 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *b2 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *b3 = [[UIImageView alloc] initWithFrame:CGRectZero];
        UIImageView *btns[3] = {b1, b2, b3};
        for (int i = 0; i < 3; i++) {
            UIImageView *iv = btns[i];
            [iv setImage:[UIImage systemImageNamed:syms[i]]];
            [iv setContentMode:UIViewContentModeScaleAspectFit];
            [iv setTintColor:[UIColor whiteColor]];
            if (i == 0) _btnLeft = iv;
            else if (i == 1) _btnCenter = iv;
            else _btnRight = iv;
            [self addSubview:iv];
        }
    }
    return self;
}

// ---- 布局: 唯一 frame 来源 ----
- (void)applyLayoutWithRectMap:(NSDictionary<NSString *, NSValue *> *)rectMap {
    [_lastRectMap removeAllObjects];
    for (NSString *k in rectMap) [_lastRectMap setObject:rectMap[k] forKey:k];

    CGRect bg = [rectMap[TLPXElBackground] CGRectValue];
    [_backgroundImageView setFrame:bg];
    [_underlayImageView setFrame:bg];

    CGRect icon = [rectMap[TLPXElIconContainer] CGRectValue];
    [_iconContainer setFrame:icon];
    CGRect disc = [rectMap[TLPXElVinylDisc] CGRectValue];
    [_vinylDiscView setFrame:disc];
    CGRect art = [rectMap[TLPXElVinylArt] CGRectValue];
    [_vinylArtView setFrame:art];

    [_titleMarquee setFrame:[rectMap[TLPXElTitle] CGRectValue]];
    [_titleLabel setFrame:_titleMarquee.bounds];
    [_subtitleMarquee setFrame:[rectMap[TLPXElSubtitle] CGRectValue]];
    [_subtitleLabel setFrame:_subtitleMarquee.bounds];

    [_barTrack setHidden:NO];
    [_elapsedLabel setFrame:[rectMap[TLPXElElapsed] CGRectValue]];
    [_durationLabel setFrame:[rectMap[TLPXElDuration] CGRectValue]];
    [_barTrack setFrame:[rectMap[TLPXElBar] CGRectValue]];

    // 环形进度环绕黑胶盘中心 (黑胶盘 rect 已是容器局部坐标)
    double dcx = disc.origin.x + disc.size.width / 2.0;
    double dcy = disc.origin.y + disc.size.height / 2.0;
    double r = disc.size.width / 2.0 + 3.0;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddEllipseInRect(path, NULL, CGRectMake(dcx - r, dcy - r, r * 2, r * 2));
    [_ringTrack setPath:path];
    [_ringProg setPath:path];
    CGPathRelease(path);
    [_ringTrack setFrame:icon];
    [_ringProg setFrame:icon];
    double frac = (_fraction > 0.001) ? _fraction : 0.0;
    [_ringProg setStrokeStart:0.0];
    [_ringProg setStrokeEnd:(CGFloat)MAX(frac, 0.02)];

    [_btnLeft setFrame:[rectMap[TLPXElButtonLeft] CGRectValue]];
    [_btnCenter setFrame:[rectMap[TLPXElButtonCenter] CGRectValue]];
    [_btnRight setFrame:[rectMap[TLPXElButtonRight] CGRectValue]];

    // 线性进度填充
    CGRect bar = [_barTrack frame];
    [_barFill setFrame:CGRectMake(bar.origin.x, bar.origin.y,
                                  bar.size.width * _fraction, bar.size.height)];

    // 跑马灯 (速度 pt/s, 文本超宽才滚动)
    [self ccpSetupMarquee:_titleMarquee label:_titleLabel];
    [self ccpSetupMarquee:_subtitleMarquee label:_subtitleLabel];

    if (_alignmentOverlayVisible) [self ccpRebuildOverlay];
}

- (void)ccpSetupMarquee:(UIView *)container label:(UILabel *)lab {
    @try {
        // 关闭一切自动缩字 (指令 6)
        [lab setAdjustsFontSizeToFitWidth:NO];
        [lab setMinimumScaleFactor:1.0];
        [lab setAllowsDefaultTighteningForTruncation:NO];
        [lab setFrame:CGRectMake(0, 0, CGFLOAT_MAX, container.bounds.size.height)];
        [lab sizeToFit];
        CGFloat tw = [lab frame].size.width;
        CGFloat cw = [container bounds].size.width;
        // 移除旧动画
        [lab.layer removeAnimationForKey:@"tlpxMarquee"];
        if (tw <= cw) {
            [lab setFrame:CGRectMake(0, 0, cw, container.bounds.size.height)];
            return;
        }
        [lab setFrame:CGRectMake(0, 0, tw, container.bounds.size.height)];
        // pt/s 匀速滚动
        double speed = TLPXMarqueeSpeedPtsPerSecond;
        double d1 = tw;
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"position.x"];
        [anim setFromValue:@(0)];
        [anim setToValue:@(-tw)];
        [anim setDuration:d1 / speed];
        [anim setRepeatCount:100000];
        [anim setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
        [lab.layer addAnimation:anim forKey:@"tlpxMarquee"];
    } @catch (id e) {}
}

- (void)applyFonts:(NSDictionary<NSString *, NSNumber *> *)fonts {
    double tf = [fonts[TLPXKeyTitleFont] doubleValue];
    double sf = [fonts[TLPXKeySubtitleFont] doubleValue];
    double ef = [fonts[TLPXKeyElapsedTitleFont] doubleValue];
    double df = [fonts[TLPXKeyDurationTitleFont] doubleValue];
    if (tf >= 4) [_titleLabel setFont:[UIFont systemFontOfSize:tf]];
    if (sf >= 4) [_subtitleLabel setFont:[UIFont systemFontOfSize:sf]];
    if (ef >= 4) [_elapsedLabel setFont:[UIFont systemFontOfSize:ef]];
    if (df >= 4) [_durationLabel setFont:[UIFont systemFontOfSize:df]];
    [self ccpSetupMarquee:_titleMarquee label:_titleLabel];
    [self ccpSetupMarquee:_subtitleMarquee label:_subtitleLabel];
}

- (void)applyMediaSnapshot:(TLPXMediaSnapshot *)snap {
    [_titleLabel setText:snap.title ?: @"歌名示例文本"];
    [_subtitleLabel setText:snap.artist ?: @"歌手名示例"];
    if (snap.duration > 0.5 && !snap.sample) {
        int em = (int)snap.elapsed, dm = (int)snap.duration;
        [_elapsedLabel setText:[NSString stringWithFormat:@"%d:%02d", em / 60, em % 60]];
        [_durationLabel setText:[NSString stringWithFormat:@"%d:%02d", dm / 60, dm % 60]];
        _fraction = (snap.elapsed > 0) ? MIN(1.0, snap.elapsed / snap.duration) : 0.0;
    } else {
        [_elapsedLabel setText:@"1:23"];
        [_durationLabel setText:@"3:45"];
        _fraction = 0.35;
    }
    if (snap.artwork) [_vinylArtView setImage:snap.artwork];
    [self applyLayoutWithRectMap:_lastRectMap];
}

- (void)setMaskBundlePath:(NSString *)dir {
    @try {
        if (![dir length]) return;
        NSString *mask = [dir stringByAppendingPathComponent:@"Mask.png"];
        UIImage *mimg = [UIImage imageWithContentsOfFile:mask];
        if (mimg) {
            // Mask.png 作为背景蒙版 (同源加载, 与真机一致)
            CALayer *ml = [CALayer layer];
            [ml setFrame:_backgroundImageView.bounds];
            [ml setContents:(id)mimg.CGImage];
            [_backgroundImageView.layer setMask:ml];
        }
        NSString *under = [dir stringByAppendingPathComponent:@"Underlay.png"];
        UIImage *uimg = [UIImage imageWithContentsOfFile:under];
        if (uimg) [_underlayImageView setImage:uimg];
        NSString *vinyl = [dir stringByAppendingPathComponent:@"Vinyl.png"];
        UIImage *vimg = [UIImage imageWithContentsOfFile:vinyl];
        if (vimg) [_vinylDiscView setImage:vimg];
    } @catch (id e) {}
}

// ---- 对齐检查叠加层 (阶段三) ----
- (void)setAlignmentOverlayVisible:(BOOL)visible {
    _alignmentOverlayVisible = visible;
    if (visible) {
        [self ccpRebuildOverlay];
    } else {
        [_overlay removeFromSuperview];
        _overlay = nil;
    }
}

- (void)ccpRebuildOverlay {
    @try {
        [_overlay removeFromSuperview];
        _overlay = [[UIView alloc] initWithFrame:self.bounds];
        [_overlay setUserInteractionEnabled:NO];
        [self addSubview:_overlay];

        // 10pt 网格
        UIView *grid = [[UIView alloc] initWithFrame:self.bounds];
        [grid setBackgroundColor:[UIColor clearColor]];
        [grid.layer setBorderColor:[UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.10].CGColor];
        (void)grid;
        CAShapeLayer *gl = [CAShapeLayer layer];
        CGMutablePathRef gp = CGPathCreateMutable();
        for (double x = 10; x < self.bounds.size.width; x += 10)
            CGPathMoveToPoint(gp, NULL, x, 0), CGPathAddLineToPoint(gp, NULL, x, self.bounds.size.height);
        for (double y = 10; y < self.bounds.size.height; y += 10)
            CGPathMoveToPoint(gp, NULL, 0, y), CGPathAddLineToPoint(gp, NULL, self.bounds.size.width, y);
        [gl setPath:gp];
        CGPathRelease(gp);
        [gl setStrokeColor:[UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.15].CGColor];
        [gl setLineWidth:0.5];
        [_overlay.layer addSublayer:gl];

        // 模块 1px 描边
        [_overlay.layer setBorderColor:[UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.9].CGColor];
        [_overlay.layer setBorderWidth:1.0];
        [_overlay.layer setCornerRadius:12.0];

        // 每元素边框 + 坐标标注
        for (NSString *k in _lastRectMap) {
            CGRect r = [_lastRectMap[k] CGRectValue];
            if (r.size.width <= 0.5 && r.size.height <= 0.5) continue;
            UIView *box = [[UIView alloc] initWithFrame:r];
            [box setBackgroundColor:[UIColor clearColor]];
            [box.layer setBorderColor:[UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:0.9].CGColor];
            [box.layer setBorderWidth:1.0];
            [_overlay addSubview:box];
            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(r.origin.x, r.origin.y - 12, 130, 12)];
            [lb setText:[NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f", r.origin.x, r.origin.y, r.size.width, r.size.height]];
            [lb setFont:[UIFont systemFontOfSize:8.0]];
            [lb setTextColor:[UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:1.0]];
            [_overlay addSubview:lb];
        }
    } @catch (id e) {}
}

@end
