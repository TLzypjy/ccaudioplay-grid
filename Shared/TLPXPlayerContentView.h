//
//  TLPXPlayerContentView.h
//  播放器内容视图 —— 真机实际层级的数据驱动复刻：
//  背景 → 遮罩 → 黑胶/封面 → 歌词跑马灯 → 歌曲 → 当前/总时间 → 线性进度条 → 环形进度 → 左中右按钮。
//
//  所有子视图 frame 只来自 - applyLayoutWithRectMap: (TLPXLayoutEngine 的输出)。
//  不依赖 SpringBoard 私有类, 可在 Preferences 进程初始化。
//  字体统一 systemFontOfSize:, 关闭一切自动缩字, 跑马灯速度按 pt/s。
//

#import <UIKit/UIKit.h>
#import "TLPXConstants.h"

NS_ASSUME_NONNULL_BEGIN

@class TLPXMediaSnapshot;

@interface TLPXPlayerContentView : UIView

// 外部塞静态素材 (当前选中素材的静态首帧/图片); 视频由真机负责, 预览不播视频
@property (nonatomic, retain, readonly) UIImageView *backgroundImageView;

// 对齐检查叠加层 (阶段三): 模块描边 + 每元素边框与 x,y,w,h 标注 + 10pt 网格
@property (nonatomic, assign) BOOL alignmentOverlayVisible;

- (void)applyLayoutWithRectMap:(NSDictionary<NSString *, NSValue *> *)rectMap;
- (void)applyFonts:(NSDictionary<NSString *, NSNumber *> *)fonts;   // key: TLPXKey*Font
- (void)applyMediaSnapshot:(TLPXMediaSnapshot *)snap;               // 歌名/歌手/时间/封面/进度
- (void)setMaskBundlePath:(nullable NSString *)dir;                 // 主题遮罩同源加载 (Mask/Underlay/Vinyl)

@end

NS_ASSUME_NONNULL_END
