//
//  TLPXLayoutEngine.h
//  纯几何布局引擎 —— 真机模块与设置面板预览共用的唯一 frame 来源。
//  不依赖 UIKit / SpringBoard 私有 API，可在任意进程使用。
//
//  输入: 模块实测尺寸 + 布局档位 + frames 配置(存储值, 模块坐标系点值;
//        进度组三键为进度容器局部坐标) + 可选示例文本。
//  输出: rectMap —— 元素名 → CGRect(模块坐标系; 进度组子元素为容器局部坐标)。
//
//  规则: 配置值全零/缺省 = 未设置, 引擎按默认排布补齐; 除此之外原样透传,
//        引擎不做任何"看起来对"的补偿。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "TLPXConstants.h"

NS_ASSUME_NONNULL_BEGIN

@interface TLPXLayoutEngine : NSObject

// frames: 配置键(TLPXKey*Frame) → NSValue(CGRect)。缺省传 nil。
// textSamples: 可选, @{TLPXElTitle: @"文本", TLPXElSubtitle: @"文本"}；
//              供跑马灯可视宽度/文字基线标注, 不影响几何。
+ (NSDictionary<NSString *, NSValue *> *)rectMapWithSize:(CGSize)moduleSize
                                                   tier:(TLPXTier)tier
                                                 frames:(nullable NSDictionary<NSString *, NSValue *> *)frames
                                            textSamples:(nullable NSDictionary<NSString *, NSString *> *)textSamples;

// 单元素默认 frame (配置未设置时引擎内部使用; 也可用于 UI 提示)
+ (CGRect)defaultRectForElement:(NSString *)element size:(CGSize)moduleSize;

// 档位实测尺寸缺失时的兜底尺寸 (仅用于 metrics 缺失时的明确提示场景)
+ (CGSize)fallbackSizeForTier:(TLPXTier)tier;

@end

NS_ASSUME_NONNULL_END
