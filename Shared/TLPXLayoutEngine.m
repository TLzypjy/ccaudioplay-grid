//
//  TLPXLayoutEngine.m
//  纯几何计算。所有 rect 均为模块坐标系点值；进度组三键 (elapsed/duration/bar)
//  为进度容器局部坐标 (与原插件配置语义一致)。
//
//  未设置判定: rect 四个分量全部 ≤ 0.5 视为"未设置"，按默认排布补齐。
//  引擎本身不做任何设备适配补偿 —— 设备差异只通过输入的 moduleSize 体现。
//

#import "TLPXLayoutEngine.h"

static BOOL TLPXRectIsUnset(CGRect r) {
    return r.origin.x <= 0.5 && r.origin.y <= 0.5 &&
           r.size.width <= 0.5 && r.size.height <= 0.5;
}

@implementation TLPXLayoutEngine

+ (CGSize)fallbackSizeForTier:(TLPXTier)tier {
    // 仅当 metrics.plist 缺失(未同步过实测尺寸)时使用, 并由调用方给出明确提示。
    switch (tier) {
        case TLPXTier2x2: return CGSizeMake(164.0, 159.0);
        case TLPXTier2x3: return CGSizeMake(164.0, 238.5);
        case TLPXTier3x2: return CGSizeMake(246.0, 159.0);
        case TLPXTier4x2: return CGSizeMake(328.0, 159.0);
        case TLPXTier4x3: return CGSizeMake(328.0, 238.5);
    }
}

+ (CGRect)defaultRectForElement:(NSString *)element size:(CGSize)moduleSize {
    CGFloat W = moduleSize.width, H = moduleSize.height;
    // 进度容器默认框 (实测自真机 2x2, 等比例表达)
    if ([element isEqualToString:TLPXElProgressGroup]) {
        return CGRectMake(0.088 * W, 0.604 * H, 0.835 * W, 0.202 * H);
    }
    // 进度容器内三键的默认局部坐标 (实测自真机 2x2)
    if ([element isEqualToString:TLPXElElapsed])  return CGRectMake(0, 0, 35.0, 34.33);
    if ([element isEqualToString:TLPXElDuration]) return CGRectMake(107.0, 0, 35.0, 34.33);
    if ([element isEqualToString:TLPXElBar])      return CGRectMake(41.0, 15.77, 60.0, 2.8);
    // 播放按钮组默认 (三键一体, 组内 28%/30%/28% + 6% 间隙)
    if ([element isEqualToString:TLPXElButtonLeft])   return CGRectMake(0.28 * W, 0.80 * H, 0.44 * W * (0.28 / 0.44), 0.14 * H);
    if ([element isEqualToString:TLPXElButtonCenter]) return CGRectMake(0.28 * W + 0.44 * W * 0.34, 0.80 * H, 0.44 * W * (0.30 / 0.44), 0.14 * H);
    if ([element isEqualToString:TLPXElButtonRight])  return CGRectMake(0.28 * W + 0.44 * W * 0.70, 0.80 * H, 0.44 * W * (0.28 / 0.44), 0.14 * H);
    // 其余单元素默认
    if ([element isEqualToString:TLPXElIconContainer]) return CGRectMake(0.04 * W, 0.26 * H, 0.26 * W, 0.42 * H);
    if ([element isEqualToString:TLPXElTitle])         return CGRectMake(0.34 * W, 0.10 * H, 0.60 * W, 0.22 * H);
    if ([element isEqualToString:TLPXElSubtitle])      return CGRectMake(0.34 * W, 0.36 * H, 0.58 * W, 0.16 * H);
    if ([element isEqualToString:TLPXElBackground])    return CGRectMake(0, 0, W, H);
    return CGRectZero;
}

+ (NSDictionary<NSString *, NSValue *> *)rectMapWithSize:(CGSize)moduleSize
                                                   tier:(TLPXTier)tier
                                                 frames:(nullable NSDictionary<NSString *, NSValue *> *)frames
                                            textSamples:(nullable NSDictionary<NSString *, NSString *> *)textSamples
{
    CGFloat W = moduleSize.width, H = moduleSize.height;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // 取配置值 (未设置 → 默认)
    CGRect (^rect)(NSString *cfgKey, NSString *elKey) = ^CGRect(NSString *cfgKey, NSString *elKey) {
        CGRect r = CGRectZero;
        NSValue *v = frames[cfgKey];
        if (v) [v getValue:&r];
        if (TLPXRectIsUnset(r)) r = [self defaultRectForElement:elKey size:moduleSize];
        return r;
    };

    // 背景
    CGRect rBg = CGRectMake(0, 0, W, H);
    [out setObject:[NSValue valueWithBytes:&rBg objCType:@encode(CGRect)] forKey:TLPXElBackground];

    // 专辑容器 + 黑胶盘 + 黑胶中心封面 (容器内局部坐标)
    CGRect rIcon = rect(TLPXKeyIconFrame, TLPXElIconContainer);
    [out setObject:[NSValue valueWithBytes:&rIcon objCType:@encode(CGRect)] forKey:TLPXElIconContainer];
    {
        CGFloat discSide = rIcon.size.height * 0.92;
        CGRect rDisc = CGRectMake(rIcon.size.width - discSide * 0.72,
                                  (rIcon.size.height - discSide) / 2.0,
                                  discSide, discSide);
        [out setObject:[NSValue valueWithBytes:&rDisc objCType:@encode(CGRect)] forKey:TLPXElVinylDisc];
        CGRect rCard = CGRectMake(0, 0, rIcon.size.width * 0.62, rIcon.size.height);
        [out setObject:[NSValue valueWithBytes:&rCard objCType:@encode(CGRect)] forKey:TLPXElVinylArt];
    }

    // 歌词 / 歌曲
    CGRect rTitle = rect(TLPXKeyTitleFrame, TLPXElTitle);
    [out setObject:[NSValue valueWithBytes:&rTitle objCType:@encode(CGRect)] forKey:TLPXElTitle];
    CGRect rSub = rect(TLPXKeySubTitleFrame, TLPXElSubtitle);
    [out setObject:[NSValue valueWithBytes:&rSub objCType:@encode(CGRect)] forKey:TLPXElSubtitle];

    // 进度组: 容器 (默认比例) + 容器内三键 (配置为局部坐标)
    // 配置的 progressFrame 是"条"的局部坐标; 容器框由默认框给出
    // (真机容器由原布局摆放, 预览容器按默认比例; 条/时间局部值原样透传)。
    CGRect rGroup = [self defaultRectForElement:TLPXElProgressGroup size:moduleSize];
    [out setObject:[NSValue valueWithBytes:&rGroup objCType:@encode(CGRect)] forKey:TLPXElProgressGroup];
    CGRect rElapsed = rect(TLPXKeyElapsedTitleFrame, TLPXElElapsed);
    [out setObject:[NSValue valueWithBytes:&rElapsed objCType:@encode(CGRect)] forKey:TLPXElElapsed];
    CGRect rDuration = rect(TLPXKeyDurationTitleFrame, TLPXElDuration);
    [out setObject:[NSValue valueWithBytes:&rDuration objCType:@encode(CGRect)] forKey:TLPXElDuration];
    CGRect rBar = rect(TLPXKeyProgressFrame, TLPXElBar);
    [out setObject:[NSValue valueWithBytes:&rBar objCType:@encode(CGRect)] forKey:TLPXElBar];

    // 播放按钮三键 (未设置按组默认分解)
    CGRect gl = rect(TLPXKeyLeftButtonFrame, TLPXElButtonLeft);
    CGRect gc = rect(TLPXKeyCenterButtonFrame, TLPXElButtonCenter);
    CGRect gr = rect(TLPXKeyRightButtonFrame, TLPXElButtonRight);
    if (TLPXRectIsUnset(gl) && TLPXRectIsUnset(gc) && TLPXRectIsUnset(gr)) {
        CGFloat gw = 0.44 * W, gh = 0.14 * H, gx = 0.28 * W, gy = 0.80 * H;
        gl = CGRectMake(gx,             gy, gw * 0.28, gh);
        gc = CGRectMake(gx + gw * 0.34, gy, gw * 0.30, gh);
        gr = CGRectMake(gx + gw * 0.70, gy, gw * 0.28, gh);
    }
    [out setObject:[NSValue valueWithBytes:&gl objCType:@encode(CGRect)] forKey:TLPXElButtonLeft];
    [out setObject:[NSValue valueWithBytes:&gc objCType:@encode(CGRect)] forKey:TLPXElButtonCenter];
    [out setObject:[NSValue valueWithBytes:&gr objCType:@encode(CGRect)] forKey:TLPXElButtonRight];

    return out;
}

@end
