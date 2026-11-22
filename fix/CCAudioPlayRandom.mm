/**
 * CCAudioPlayRandom — 背景素材「随机洗牌轮播」
 *
 * 与设置页网格素材库配套:
 *   设置页把每个槽位(PlayingAsset 播放时 / BackAsset 未播放时)的
 *   {enabled, items:[视频完整路径]} 写到共享 plist:
 *     /var/mobile/Library/Preferences/com.thefool.ccaudioplay.random.plist
 *   本 tweak 注入 SpringBoard, 读取该 plist。当某槽位 enabled 且有 items 时:
 *     - 洗牌(items 打乱, 一轮播完重新洗牌, 不连续播放同一条)
 *     - 接管该槽位的 AVQueuePlayer: 关掉原 AVPlayerLooper(它会让单视频无限循环)
 *     - 收到 AVPlayerItemDidPlayToEndTime 后用 removeAllItems + insertItem 替换
 *       为新 item 并 play, 实现「播完自动切下一个」循环。
 *       日志落盘: /var/mobile/Documents/ccrandom_debug.log
 *
 * 不改动原 dylib, 只在收到原生素材更新通知后, 对原 tweak 建好的播放器做运行时接管。
 * 随机开关关闭 / 列表为空时, 完全不介入(原单素材循环行为不变)。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

// 日志同时写文件, 方便排查(NSLog 只在系统 console, 文件管理器看不到)
static NSString * const kRndLogPath = @"/var/mobile/Documents/ccrandom_debug.log";
static void RNDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [CCRandom] %@\n",
                      [NSDate date], body];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kRndLogPath]) {
            [fm createFileAtPath:kRndLogPath contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kRndLogPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (id e) {}
    NSLog(@"[CCRandom] %@", body);
}

static NSString * const kRndPlist = @"/var/mobile/Library/Preferences/com.thefool.ccaudioplay.random.plist";

#pragma mark - 共享 plist

static NSDictionary *RNDConfig(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kRndPlist];
        return d ?: @{};
    } @catch (id e) { return @{}; }
}
static NSString *RNDMode(NSString *slot) {
    @try {
        NSString *m = [[[RNDConfig() objectForKey:slot] objectForKey:@"mode"] stringValue];
        return m.length ? m : @"random";
    } @catch (id e) { return @"random"; }
}
// 只有启用且模式非 fixed 时才接管播放器(fixed = 原单素材循环行为)
static BOOL RNDActive(NSString *slot) {
    @try {
        NSDictionary *d = [RNDConfig() objectForKey:slot];
        BOOL en = [[d objectForKey:@"enabled"] boolValue];
        NSString *m = [[d objectForKey:@"mode"] stringValue];
        BOOL fixed = [m isEqualToString:@"fixed"];
        return en && !fixed;
    } @catch (id e) { return NO; }
}
static NSArray *RNDItems(NSString *slot) {
    @try {
        id v = [[RNDConfig() objectForKey:slot] objectForKey:@"items"];
        return [v isKindOfClass:[NSArray class]] ? v : @[];
    } @catch (id e) { return @[]; }
}

#pragma mark - 洗牌队列(不连续重复)

@interface RNDQueue : NSObject
@property (nonatomic, strong) NSArray *order;      // 当前轮的顺序(路径)
@property (nonatomic, assign) NSUInteger idx;       // 当前播放下标
@property (nonatomic, copy) NSString *lastPath;     // 上一条(防止跨轮连播同一条)
@property (nonatomic, copy) NSString *mode;         // "order" 顺序 / "random" 洗牌
- (instancetype)initWithItems:(NSArray *)items mode:(NSString *)mode;
- (NSString *)next;
@end

@implementation RNDQueue
- (instancetype)initWithItems:(NSArray *)items mode:(NSString *)m {
    if ((self = [super init])) {
        _order = [items copy] ?: @[];
        _mode = [m copy] ?: @"random";
        _idx = 0;
    }
    return self;
}
- (NSString *)next {
    NSArray *items = self.order;
    if (![items count]) return nil;
    if (self.idx >= [items count]) {
        if ([self.mode isEqualToString:@"order"]) {
            // 顺序模式: 一轮播完从头再来(不打乱)
            self.idx = 0;
        } else {
            // 洗牌模式: 一轮播完重新洗牌; 若首条==last, 与末条对调避免连续重复
            NSMutableArray *shuf = [items mutableCopy];
            for (NSUInteger i = [shuf count] - 1; i > 0; i--) {
                NSUInteger j = arc4random_uniform((uint32_t)(i + 1));
                [shuf exchangeObjectAtIndex:i withObjectAtIndex:j];
            }
            if ([shuf count] > 1 && [shuf[0] isEqualToString:self.lastPath]) {
                [shuf exchangeObjectAtIndex:0 withObjectAtIndex:[shuf count] - 1];
            }
            self.order = shuf;
            self.idx = 0;
        }
    }
    NSString *p = [self.order objectAtIndex:self.idx];
    self.idx++;
    self.lastPath = p;
    return p;
}
@end

#pragma mark - 每个 CCCustomView 的轮播状态

@interface RNDState : NSObject
@property (nonatomic, weak) AVQueuePlayer *player;
@property (nonatomic, strong) RNDQueue *queue;      // 播放时(PlayingAsset)
@property (nonatomic, strong) RNDQueue *backQueue;  // 未播放(BackAsset)
@property (nonatomic, weak) id observingItem;       // 当前挂了结束通知的 item
@property (nonatomic, assign) BOOL playingEnabled;
@property (nonatomic, assign) BOOL backEnabled;
@end
// itemDidEnd: 在下方分类中实现; 作为 NSNotificationCenter 的 selector 运行时解析, 无需在此声明
@implementation RNDState
@end

static const char kRNDStateKey = 0;
static NSHashTable *RNDViews(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

#pragma mark - 播放器接管

// 把 AVPlayerLooper 关掉(否则 item 播完会自动 seek 到 0 循环, 收不到 DidPlayToEnd)
static void RNDDisableLooper(id looper) {
    @try {
        if (looper && [(NSObject *)looper respondsToSelector:@selector(disableLooping)]) {
            ((void (*)(id, SEL))objc_msgSend)(looper, @selector(disableLooping));
        }
    } @catch (id e) {}
}

// 指定 item 播完后推进到队列下一条
static void RNDPlayNext(RNDState *st, AVQueuePlayer *player, RNDQueue *queue, id view) {
    NSString *path = [queue next];
    if (!path.length || !player) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    if (!url) return;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    if (!item) return;

    // 监听本条播完
    [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItem];
    st.observingItem = item;
    [[NSNotificationCenter defaultCenter] addObserver:st
                                             selector:@selector(itemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    // 可靠替换: 清空队列再把新 item 插到队首。
    // 不能用 insertItem:afterItem: + advanceToNextItem —— 队列只有 1 条时
    // advanceToNextItem 会把唯一的 item 移除, player 变空 -> 控制中心成空模块。
    @try {
        if ([player respondsToSelector:@selector(removeAllItems)]) [player removeAllItems];
        [player insertItem:item afterItem:nil];
        [player play];
    } @catch (id e) {
        @try { [player replaceCurrentItemWithPlayerItem:item]; [player play]; }
        @catch (id e2) { RNDLog(@"play next FAILED: %@", e2); }
    }
    RNDLog(@"play next -> %@ (current=%@, items=%lu, exists=%d)", [path lastPathComponent],
           player.currentItem ? @"ok" : @"NIL", (unsigned long)[[player items] count],
           [[NSFileManager defaultManager] fileExistsAtPath:path]);
    // 1.5s 后探测: item 是否真就绪 / player 是否在播 / 有没有错误
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RNDLog(@"probe %@: itemStatus=%ld err=%@ tcs=%ld rate=%.1f size=%@",
               [path lastPathComponent], (long)item.status,
               item.error ?: @"-", (long)player.timeControlStatus, player.rate,
               NSStringFromCGSize(item.presentationSize));
    });
}

@implementation RNDState (RNDEnd)
- (void)itemDidEnd:(NSNotification *)note {
    @try {
        // 判断是哪个槽位的 item 结束了
        AVQueuePlayer *pp = self.player;
        id view = nil;
        for (id v in [[RNDViews() allObjects] copy]) {
            if (objc_getAssociatedObject(v, &kRNDStateKey) == self) { view = v; break; }
        }
        if (!view) return;
        AVQueuePlayer *playing = nil, *back = nil;
        if ([view respondsToSelector:@selector(playingPlayer)]) playing = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(playingPlayer));
        if ([view respondsToSelector:@selector(backPlayer)]) back = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(backPlayer));

        if (pp == playing && self.playingEnabled) {
            RNDPlayNext(self, playing, self.queue, view);
        } else if (pp == back && self.backEnabled) {
            RNDPlayNext(self, back, self.backQueue, view);
        }
    } @catch (id e) { RNDLog(@"itemDidEnd exception: %@", e); }
}
@end

#pragma mark - 接管入口

// 在原生素材更新完成后调用: 若该槽位随机启用, 关 looper 并起播第一条
static void RNDApplyForView(id view, BOOL isBack) {
    @try {
        RNDState *st = objc_getAssociatedObject(view, &kRNDStateKey);
        if (!st) { st = [RNDState new]; objc_setAssociatedObject(view, &kRNDStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

        NSString *slot = isBack ? @"BackAsset" : @"PlayingAsset";
        BOOL active = RNDActive(slot);
        NSString *mode = RNDMode(slot);
        NSArray *items = RNDItems(slot);
        AVQueuePlayer *player = nil;
        id looper = nil;
        if (!isBack) {
            if ([view respondsToSelector:@selector(playingPlayer)]) player = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(playingPlayer));
            if ([view respondsToSelector:@selector(playingLayerLooper)]) looper = ((id (*)(id, SEL))objc_msgSend)(view, @selector(playingLayerLooper));
            st.playingEnabled = active;
        } else {
            if ([view respondsToSelector:@selector(backPlayer)]) player = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(backPlayer));
            if ([view respondsToSelector:@selector(backLayerLooper)]) looper = ((id (*)(id, SEL))objc_msgSend)(view, @selector(backLayerLooper));
            st.backEnabled = active;
        }
        st.player = player;

        if (!active || ![items count] || !player) {
            RNDLog(@"slot=%@ inactive(fixed/off/empty) -> native behavior", slot);
            return;
        }
        // 关掉 looper, 接管队列
        RNDDisableLooper(looper);
        RNDQueue *q = isBack ? st.backQueue : st.queue;
        // 模式或素材列表变化 -> 重建队列, 从头播
        if (!q || ![q.mode isEqualToString:mode] || ![q.order isEqualToArray:items]) {
            q = [[RNDQueue alloc] initWithItems:items mode:mode];
            if (isBack) st.backQueue = q; else st.queue = q;
            [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItem];
            st.observingItem = nil;
        }
        if (!st.observingItem) {
            RNDPlayNext(st, player, q, view);
        }
        RNDLog(@"slot=%@ mode=%@ active, %lu items, first=%@ exists=%d", slot, mode,
               (unsigned long)[items count], [items firstObject],
               [[NSFileManager defaultManager] fileExistsAtPath:[items firstObject]]);
    } @catch (id e) { RNDLog(@"apply exception: %@", e); }
}

#pragma mark - Darwin 通知重载

static void RNDOnConfigChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        NSString *nm = (__bridge NSString *)name;
        BOOL isBack = [nm rangeOfString:@"BackAsset"].location != NSNotFound;
        RNDLog(@"config changed: %@", nm);
        // 延迟接管: 原 tweak 收到同一通知会重建播放器(读文件/解码, 耗时较重),
        // 同帧接管会拿到旧 player 或被随后重建覆盖 -> 等它重建完再接管。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (id view in [[RNDViews() allObjects] copy]) {
                RNDState *st = objc_getAssociatedObject(view, &kRNDStateKey);
                if (st) {
                    // 关闭则清空队列状态, 恢复原生循环
                    NSString *slot = isBack ? @"BackAsset" : @"PlayingAsset";
                    if (!RNDActive(slot) || ![RNDItems(slot) count]) {
                        if (isBack) { st.backQueue = nil; st.backEnabled = NO; }
                        else { st.queue = nil; st.playingEnabled = NO; }
                        [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItem];
                        st.observingItem = nil;
                    }
                }
                RNDApplyForView(view, isBack);
            }
        });
    }
}

#pragma mark - setOnScreen hook (跟踪实例 + 首帧接管)

static void RNDInstallHooks(void) {
    Class cls = objc_getClass("CCCustomView");
    if (!cls) { RNDLog(@"CCCustomView not found"); return; }

    // 跟踪实例: hook setOnScreen:, 模块上屏时尝试接管(原生此时已建好播放器)
    SEL orig = @selector(setOnScreen:);
    SEL mine = @selector(rnd_setOnScreen:);
    Method m = class_getInstanceMethod(cls, orig);
    if (m && !class_getInstanceMethod(cls, mine)) {
        IMP imp = imp_implementationWithBlock(^void(id self, BOOL on) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, mine, on); // 原实现
            @synchronized (RNDViews()) { [RNDViews() addObject:self]; }
            if (on) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    RNDApplyForView(self, NO);
                    RNDApplyForView(self, YES);
                });
            }
        });
        if (class_addMethod(cls, mine, imp, "v@:B")) {
            method_exchangeImplementations(class_getInstanceMethod(cls, orig), class_getInstanceMethod(cls, mine));
        }
    }

    // 原生素材更新通知: 它重建播放器后我们再接管
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, RNDOnConfigChanged,
        CFSTR("com.thefool.ccaudioplaypres/updatePlayingAssetNotificationt"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, RNDOnConfigChanged,
        CFSTR("com.thefool.ccaudioplaypres/updateBackAssetNotificationt"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    RNDLog(@"installed");
}

__attribute__((constructor))
static void RNDEntry(void) {
    @autoreleasepool { RNDInstallHooks(); }
}
