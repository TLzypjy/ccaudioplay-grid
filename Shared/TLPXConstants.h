//
//  TLPXConstants.h
//  共享常量 —— 真机模块 (SpringBoard, 经伴随 tweak) 与设置面板预览两端唯一取值来源。
//  禁止在任何 .m 里写布局相关的魔术数字; 新增常量一律加在这里。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// ---------- 配置域 / 配置键 (与原插件偏好完全一致, 两端同 key 读写) ----------
FOUNDATION_EXPORT NSString * const TLPXPrefsDomain;

FOUNDATION_EXPORT NSString * const TLPXKeyIconFrame;            // 专辑容器
FOUNDATION_EXPORT NSString * const TLPXKeyTitleFrame;           // 歌词
FOUNDATION_EXPORT NSString * const TLPXKeySubTitleFrame;        // 歌曲
FOUNDATION_EXPORT NSString * const TLPXKeyElapsedTitleFrame;    // 当前时间 (进度容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXKeyDurationTitleFrame;   // 总时间 (进度容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXKeyProgressFrame;        // 进度条 (进度容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXKeyLeftButtonFrame;      // 上一曲
FOUNDATION_EXPORT NSString * const TLPXKeyCenterButtonFrame;    // 播放
FOUNDATION_EXPORT NSString * const TLPXKeyRightButtonFrame;     // 下一曲
FOUNDATION_EXPORT NSString * const TLPXKeyLayoutType;           // 模块档位 0..4
FOUNDATION_EXPORT NSString * const TLPXKeyTitleFont;            // 歌词字号
FOUNDATION_EXPORT NSString * const TLPXKeySubtitleFont;         // 歌曲字号
FOUNDATION_EXPORT NSString * const TLPXKeyElapsedTitleFont;     // 当前时间字号
FOUNDATION_EXPORT NSString * const TLPXKeyDurationTitleFont;    // 总时间字号
FOUNDATION_EXPORT NSString * const TLPXKeyMaskName;             // 遮罩主题名
FOUNDATION_EXPORT NSString * const TLPXKeyIsEnableCustomFrame;  // 启用自定义
FOUNDATION_EXPORT NSString * const TLPXKeyIsEnableColor;        // 启用颜色调试
FOUNDATION_EXPORT NSString * const TLPXKeyPlayingAsset;         // 背景(播放时)素材名

// ---------- 布局档位 ----------
typedef NS_ENUM(NSInteger, TLPXTier) {
    TLPXTier2x2 = 0,
    TLPXTier2x3 = 1,
    TLPXTier3x2 = 2,
    TLPXTier4x2 = 3,
    TLPXTier4x3 = 4,
};

FOUNDATION_EXPORT NSInteger TLPXTierCols(TLPXTier tier);   // 档位列数 (2/2/3/4/4)
FOUNDATION_EXPORT NSInteger TLPXTierRows(TLPXTier tier);   // 档位行数 (2/3/2/2/3)

// ---------- rectMap 元素键 (TLPXLayoutEngine 输出) ----------
FOUNDATION_EXPORT NSString * const TLPXElBackground;       // 背景层 (恒为 {0,0,size,size})
FOUNDATION_EXPORT NSString * const TLPXElIconContainer;    // 专辑容器 (含黑胶/封面子元素)
FOUNDATION_EXPORT NSString * const TLPXElVinylDisc;        // 黑胶盘 (容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXElVinylArt;         // 黑胶中心封面 (容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXElTitle;            // 歌词
FOUNDATION_EXPORT NSString * const TLPXElSubtitle;         // 歌曲
FOUNDATION_EXPORT NSString * const TLPXElProgressGroup;    // 进度容器
FOUNDATION_EXPORT NSString * const TLPXElElapsed;          // 当前时间 (容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXElDuration;         // 总时间 (容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXElBar;              // 进度条 (容器内局部坐标)
FOUNDATION_EXPORT NSString * const TLPXElButtonLeft;       // 上一曲
FOUNDATION_EXPORT NSString * const TLPXElButtonCenter;     // 播放
FOUNDATION_EXPORT NSString * const TLPXElButtonRight;      // 下一曲

// ---------- metrics.plist (真机实测尺寸回写; rootless / rootfs 双路径) ----------
FOUNDATION_EXPORT NSString * const TLPXMetricsPathRootless;   // /var/mobile/Documents/TLPXMetrics.plist
FOUNDATION_EXPORT NSString * const TLPXMetricsPathRootfs;     // /var/jb/var/mobile/Documents/TLPXMetrics.plist

// ---------- 伴交通知 / 导出文件 ----------
FOUNDATION_EXPORT NSString * const TLPXNoteFrameUpdate;       // 布局配置变化 (原插件通知名)
FOUNDATION_EXPORT NSString * const TLPXNoteFontUpdate;        // 字体配置变化 (原插件通知名)

// ---------- 跑马灯 / 对齐检查 ----------
FOUNDATION_EXPORT CGFloat const TLPXMarqueeSpeedPtsPerSecond; // 跑马灯速度 (pt/s, 两端一致)
FOUNDATION_EXPORT NSString * const TLPXMaskBundleDirFormat;   // 遮罩包目录格式串

// ---------- 素材目录 ----------
FOUNDATION_EXPORT NSString * const TLPXBgDirPlaying;          // 背景(播放时)素材目录
FOUNDATION_EXPORT NSString * const TLPXBgDirBack;             // 背景(未播放)素材目录

NS_ASSUME_NONNULL_END
