//
//  TLPXMediaSnapshot.m
//

#import "TLPXMediaSnapshot.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString * const TLPXNowPlistPath = @"/var/mobile/Documents/ccnow.plist";
static NSString * const TLPXNowArtPath   = @"/var/mobile/Documents/ccart.png";

@implementation TLPXMediaSnapshot

// MPNowPlayingInfoCenter (需 MediaPlayer 已加载; 未加载返回 nil 走下一级)
+ (nullable NSDictionary *)_nowPlayingInfoFromCenter {
    @try {
        Class cls = objc_getClass("MPNowPlayingInfoCenter");
        if (!cls) return nil;
        id center = ((id(*)(id, SEL))objc_msgSend)(cls, sel_registerName("defaultCenter"));
        id info = ((id(*)(id, SEL))objc_msgSend)(center, sel_registerName("nowPlayingInfo"));
        if ([info isKindOfClass:[NSDictionary class]]) return info;
        return nil;
    } @catch (id e) {
        return nil;
    }
}

// 伴随 tweak 导出的 ccnow.plist (SpringBoard 经 MediaRemote 写出)
+ (nullable NSDictionary *)_nowPlayingInfoFromExport {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:TLPXNowPlistPath];
        if ([d count] > 0) return d;
        return nil;
    } @catch (id e) {
        return nil;
    }
}

+ (instancetype)currentSnapshot {
    TLPXMediaSnapshot *s = [[self alloc] init];

    NSDictionary *info = [self _nowPlayingInfoFromCenter] ?: [self _nowPlayingInfoFromExport];

    if (info) {
        s->_title    = info[@"title"] ?: info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        s->_artist   = info[@"artist"] ?: info[@"kMRMediaRemoteNowPlayingInfoArtist"];
        s->_elapsed  = [info[@"elapsed"] ?: info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        s->_duration = [info[@"duration"] ?: info[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        id artData   = info[@"artwork"] ?: info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artData isKindOfClass:[NSData class]]) s->_artwork = [UIImage imageWithData:artData];
        else if ([artData isKindOfClass:[NSString class]]) s->_artwork = [UIImage imageWithContentsOfFile:artData];
        s->_sample = NO;
    }

    // 真实数据不足 (没播放 / 取不到) → 样本兜底, sample 标记置位供 UI 提示
    if (!s->_sample) {
        BOOL hasLive = ([s->_title length] > 0 || s->_duration > 0.5);
        if (!hasLive) {
            s->_title    = @"歌名示例文本";
            s->_artist   = @"歌手名示例";
            s->_elapsed  = 83.0;   // 1:23
            s->_duration = 225.0;  // 3:45
            s->_sample   = YES;
        }
    }
    return s;
}

+ (void)exportFromSpringBoard {
    @try {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!mr) return;
        void (*MRGNI)(dispatch_queue_t, void (^)(CFDictionaryRef)) =
            (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        if (!MRGNI) return;
        MRGNI(dispatch_get_global_queue(0, 0), ^(CFDictionaryRef info) {
            @try {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                UIImage *art = nil;
                if (info) {
                    NSDictionary *d = (__bridge NSDictionary *)info;
                    NSString *t = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoTitle"];
                    NSString *a = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtist"];
                    double e = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                    double du = [[d objectForKey:@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
                    NSData *ad = [d objectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([t length]) out[@"title"] = t;
                    if ([a length]) out[@"artist"] = a;
                    out[@"elapsed"] = @(e);
                    out[@"duration"] = @(du);
                    if (ad) art = [UIImage imageWithData:ad];
                }
                [out writeToFile:TLPXNowPlistPath atomically:YES];
                if (art) {
                    NSData *png = UIImagePNGRepresentation(art);
                    if (png) [png writeToFile:TLPXNowArtPath atomically:YES];
                }
            } @catch (id e) {}
        });
    } @catch (id e) {}
}

@end
