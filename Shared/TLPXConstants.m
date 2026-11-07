//
//  TLPXConstants.m
//

#import "TLPXConstants.h"

NSString * const TLPXPrefsDomain = @"com.thefool.ccaudioplaypres";

NSString * const TLPXKeyIconFrame          = @"iconFrame";
NSString * const TLPXKeyTitleFrame         = @"titleFrame";
NSString * const TLPXKeySubTitleFrame      = @"subTitleFrame";
NSString * const TLPXKeyElapsedTitleFrame  = @"elapsedTitleFrame";
NSString * const TLPXKeyDurationTitleFrame = @"durationTitleFrame";
NSString * const TLPXKeyProgressFrame      = @"progressFrame";
NSString * const TLPXKeyLeftButtonFrame    = @"leftButtonFrame";
NSString * const TLPXKeyCenterButtonFrame  = @"centerButtonFrame";
NSString * const TLPXKeyRightButtonFrame   = @"rightButtonFrame";
NSString * const TLPXKeyLayoutType         = @"LayoutType";
NSString * const TLPXKeyTitleFont          = @"titleFont";
NSString * const TLPXKeySubtitleFont       = @"subtitleFont";
NSString * const TLPXKeyElapsedTitleFont   = @"elapsedTitleFont";
NSString * const TLPXKeyDurationTitleFont  = @"durationTitleFont";
NSString * const TLPXKeyMaskName           = @"MaskName";

NSInteger TLPXTierCols(TLPXTier tier) {
    switch (tier) {
        case TLPXTier3x2: return 3;
        case TLPXTier4x2: case TLPXTier4x3: return 4;
        default: return 2;                          // 2x2 / 2x3
    }
}

NSInteger TLPXTierRows(TLPXTier tier) {
    switch (tier) {
        case TLPXTier2x3: return 3;
        case TLPXTier4x3: return 3;
        default: return 2;                          // 2x2 / 3x2 / 4x2
    }
}

NSString * const TLPXElBackground      = @"background";
NSString * const TLPXElIconContainer   = @"iconContainer";
NSString * const TLPXElVinylDisc       = @"vinylDisc";
NSString * const TLPXElVinylArt        = @"vinylArt";
NSString * const TLPXElTitle           = @"title";
NSString * const TLPXElSubtitle        = @"subtitle";
NSString * const TLPXElProgressGroup   = @"progressGroup";
NSString * const TLPXElElapsed         = @"elapsed";
NSString * const TLPXElDuration        = @"duration";
NSString * const TLPXElBar             = @"bar";
NSString * const TLPXElButtonLeft      = @"buttonLeft";
NSString * const TLPXElButtonCenter    = @"buttonCenter";
NSString * const TLPXElButtonRight     = @"buttonRight";

NSString * const TLPXMetricsPathRootless = @"/var/mobile/Documents/TLPXMetrics.plist";
NSString * const TLPXMetricsPathRootfs   = @"/var/jb/var/mobile/Documents/TLPXMetrics.plist";

NSString * const TLPXNoteFrameUpdate = @"com.thefool.ccaudioplaypres/updateCustomFrameNotificationt";
NSString * const TLPXNoteFontUpdate  = @"com.thefool.ccaudioplaypres/updateCustomFontNotificationt";

CGFloat const TLPXMarqueeSpeedPtsPerSecond = 30.0;
NSString * const TLPXMaskBundleDirFormat   = @"/var/mobile/Library/Application Support/CCAudioPlay/CCAudioPlay-Mask-N95/%@.bundle";

NSString * const TLPXBgDirPlaying = @"/var/mobile/CCAudioPlay-BackGround/PlayingAsset";
NSString * const TLPXBgDirBack    = @"/var/mobile/CCAudioPlay-BackGround/BackAsset";

NSString * const TLPXKeyIsEnableCustomFrame = @"isEnableCustomFrame";
NSString * const TLPXKeyIsEnableColor       = @"isEnableColor";
NSString * const TLPXKeyPlayingAsset        = @"PlayingAsset";
