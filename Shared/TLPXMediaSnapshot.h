//
//  TLPXMediaSnapshot.h
//  统一播放信息数据源 —— 真机与预览共用同一份取数逻辑。
//
//  取数优先级 (getInfo):
//    1. MPNowPlayingInfoCenter (MediaPlayer 已加载时)
//    2. ccnow.plist / ccart.png (SpringBoard 侧伴随 tweak 经 MediaRemote 导出)
//    3. 内置样本 (明确标记 sample=YES, 预览界面对样本状态给出提示)
//
//  导出 (exportFromSpringBoard): 仅 SpringBoard 进程调用 (伴随 tweak),
//    经 MediaRemote 取真实播放信息写 ccnow.plist / ccart.png, 供设置进程读取。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLPXMediaSnapshot : NSObject

@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *artist;
@property (nonatomic, assign, readonly) NSTimeInterval elapsed;
@property (nonatomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, retain, readonly, nullable) UIImage *artwork;
@property (nonatomic, assign, readonly) BOOL sample;   // YES = 非真实数据 (样本兜底)

// 统一取数入口 (两端共用; 内部按优先级尝试各数据源)
+ (instancetype)currentSnapshot;

// SpringBoard 侧导出 (伴随 tweak 调用): MediaRemote → ccnow.plist / ccart.png
+ (void)exportFromSpringBoard;

@end

NS_ASSUME_NONNULL_END
