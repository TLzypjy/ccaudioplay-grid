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
// 固定模式下用户在素材库点选的那一条(设置页写入 "picked" 字段)
static NSString *RNDPicked(NSString *slot) {
    @try {
        NSString *p = [[RNDConfig() objectForKey:slot] objectForKey:@"picked"];
        return ([p isKindOfClass:[NSString class]] && p.length) ? p : nil;
    } @catch (id e) { return nil; }
}

// 诊断用: 探测 roothide 主 jbroot 根路径(固定在 /var/containers/Bundle/Application 下)
static NSString *RNDJbRoot(void) {
    static NSString *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *found = @"";
        NSArray *c = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *n in c) {
            if ([n hasPrefix:@".jbroot-"]) {
                found = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:n];
                break;
            }
        }
        r = found;
    });
    return r;
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
        if ([self.mode isEqualToString:@"random"]) {
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
        } else {
            // order / fixed: 一轮播完从头再来
            // (修复: fixed 之前两个分支都不命中, idx 越界抛异常 -> 播完一条就卡死)
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
@property (nonatomic, weak) AVQueuePlayer *player;      // 播放槽(PlayingAsset)当前 player
@property (nonatomic, strong) AVQueuePlayer *backPlayerRef; // 背景槽 player(原生或我们创建, 强持有)
@property (nonatomic, strong) AVPlayerLayer *createdLayer;  // 我们创建的背景图层(若有)
@property (nonatomic, strong) RNDQueue *queue;          // 播放时(PlayingAsset)
@property (nonatomic, strong) RNDQueue *backQueue;      // 未播放(BackAsset)
@property (nonatomic, weak) id observingItem;           // 播放槽挂了结束通知的 item
@property (nonatomic, weak) id observingItemBack;       // 背景槽挂了结束通知的 item
@property (nonatomic, weak) AVPlayerItem *nextItem;         // 播放槽预载的下一条(无缝切换)
@property (nonatomic, weak) AVPlayerItem *nextItemBack;     // 背景槽预载的下一条(无缝切换)
@property (nonatomic, copy) NSString *nextPath;             // 播放槽预载下一条的路径
@property (nonatomic, copy) NSString *nextPathBack;         // 背景槽预载下一条的路径
@property (nonatomic, assign) BOOL playingEnabled;
@property (nonatomic, assign) BOOL backEnabled;
@property (nonatomic, assign) BOOL treeLogged;          // 一次性诊断标志
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

// 真正执行换片: 清空队列插入新 item 并起播(含探测日志)。
// 用于初始起播/配置变化/竞态兜底, 会清掉预载引用。
static void RNDCommitSwap(RNDState *st, AVQueuePlayer *player, AVPlayerItem *item, NSString *path, BOOL isBack) {
    @try {
        if ([player respondsToSelector:@selector(removeAllItems)]) [player removeAllItems];
        [player insertItem:item afterItem:nil];
        // 允许队列自动推进(预载无缝切换的前提)
        if ([player respondsToSelector:@selector(setActionAtItemEnd:)]) {
            ((void (*)(id, SEL, long))objc_msgSend)(player, @selector(setActionAtItemEnd:), 0 /* AVPlayerActionAtItemEndAdvance */);
        }
        [player play];
    } @catch (id e) {
        @try { [player replaceCurrentItemWithPlayerItem:item]; [player play]; }
        @catch (id e2) { RNDLog(@"play next FAILED: %@", e2); }
    }
    if (isBack) { st.nextItemBack = nil; st.nextPathBack = nil; }
    else { st.nextItem = nil; st.nextPath = nil; }
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

// 预载下一条: 追加到当前 item 之后, 播完时 AVQueuePlayer 自动无缝推进(不空屏)。
// 每次推进消耗一次 queue.next(), 与播放条数一一对应。
static void RNDPreloadNext(RNDState *st, AVQueuePlayer *player, RNDQueue *queue, BOOL isBack) {
    NSString *np = [queue next];
    if (!np.length) return;
    AVPlayerItem *ni = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:np]];
    if (!ni) return;
    @try {
        if (player.currentItem) {
            if ([player respondsToSelector:@selector(insertItem:afterItem:)])
                [player insertItem:ni afterItem:player.currentItem];
        } else if ([player respondsToSelector:@selector(insertItem:afterItem:)]) {
            [player insertItem:ni afterItem:nil];
        } else return;
    } @catch (id e) { RNDLog(@"preload FAILED: %@", e); return; }
    if (isBack) { st.nextItemBack = ni; st.nextPathBack = np; }
    else { st.nextItem = ni; st.nextPath = np; }
    RNDLog(@"preloaded -> %@ (queue=%lu)", [np lastPathComponent], (unsigned long)[[player items] count]);
}

// 一条播完后的推进(无缝): 预载的下一条已由队列自动接上,
// 移除播完的旧 item -> 观察转到新 item -> 继续预载下一条。
// 若因竞态没推进成功, 直接把预载 item 换上去兜底(瞬时切换, 不空屏)。
static void RNDRotate(RNDState *st, AVQueuePlayer *player, RNDQueue *queue, BOOL isBack, id endedItem) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id nxt = isBack ? st.nextItemBack : st.nextItem;
            NSString *npath = isBack ? st.nextPathBack : st.nextPath;
            if (nxt && npath.length && player.currentItem == nxt) {
                // 正常路径: 已自动推进, 只需清理旧 item / 挪观察 / 继续预载
                if ([player respondsToSelector:@selector(removeItem:)]) {
                    void (*rm)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                    rm(player, @selector(removeItem:), endedItem);
                }
                [[NSNotificationCenter defaultCenter] removeObserver:st
                    name:AVPlayerItemDidPlayToEndTimeNotification object:endedItem];
                if (isBack) { st.observingItemBack = nxt; st.nextItemBack = nil; st.nextPathBack = nil; }
                else { st.observingItem = nxt; st.nextItem = nil; st.nextPath = nil; }
                [[NSNotificationCenter defaultCenter] addObserver:st
                                                         selector:@selector(itemDidEnd:)
                                                             name:AVPlayerItemDidPlayToEndTimeNotification
                                                           object:nxt];
                [player play];
                RNDLog(@"seamless next -> %@ (items=%lu)", [npath lastPathComponent], (unsigned long)[[player items] count]);
                RNDPreloadNext(st, player, queue, isBack);
            } else {
                // 竞态兜底: 预载在但没推进上 -> 直接换上(瞬时切换); 预载丢失 -> 按路径重建
                AVPlayerItem *item = nxt;
                NSString *path = npath;
                if (!item) {
                    path = [queue next];
                    if (!path.length) return;
                    item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
                }
                if (!item || !path.length) return;
                [[NSNotificationCenter defaultCenter] removeObserver:st
                    name:AVPlayerItemDidPlayToEndTimeNotification object:endedItem];
                if (isBack) st.observingItemBack = item; else st.observingItem = item;
                [[NSNotificationCenter defaultCenter] addObserver:st
                                                         selector:@selector(itemDidEnd:)
                                                             name:AVPlayerItemDidPlayToEndTimeNotification
                                                           object:item];
                RNDCommitSwap(st, player, item, path, isBack);
                RNDPreloadNext(st, player, queue, isBack);
            }
        } @catch (id e) { RNDLog(@"rotate exception: %@", e); }
    });
}

// 指定 item 播完后推进到队列下一条(isBack 决定观察挂在哪个槽位)。
// 无缝切换: 不做渐隐渐显(会空屏), 靠预载自动推进保证画面连续。
static void RNDPlayNext(RNDState *st, AVQueuePlayer *player, RNDQueue *queue, id view, BOOL isBack) {
    NSString *path = [queue next];
    if (!path.length || !player) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    if (!url) return;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    if (!item) return;

    // 监听本条播完(双槽位独立观察, 互不覆盖)
    id old = isBack ? st.observingItemBack : st.observingItem;
    [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:old];
    if (isBack) st.observingItemBack = item; else st.observingItem = item;
    [[NSNotificationCenter defaultCenter] addObserver:st
                                             selector:@selector(itemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                                 object:item];

    // 换片动作统一切回主线程执行
    dispatch_async(dispatch_get_main_queue(), ^{
        RNDCommitSwap(st, player, item, path, isBack);
        RNDPreloadNext(st, player, queue, isBack);
    });
}

@implementation RNDState (RNDEnd)
- (void)itemDidEnd:(NSNotification *)note {
    @try {
        id ended = note.object;
        id view = nil;
        for (id v in [[RNDViews() allObjects] copy]) {
            if (objc_getAssociatedObject(v, &kRNDStateKey) == self) { view = v; break; }
        }
        if (!view) return;
        // 双槽位独立: 按 item 归属分流(无缝推进)
        if (ended == self.observingItem && self.playingEnabled && self.player) {
            RNDRotate(self, self.player, self.queue, NO, ended);
        } else if (ended == self.observingItemBack && self.backEnabled && self.backPlayerRef) {
            RNDRotate(self, self.backPlayerRef, self.backQueue, YES, ended);
        }
    } @catch (id e) { RNDLog(@"itemDidEnd exception: %@", e); }
}
@end

#pragma mark - 接管入口

// 列出目录下视频文件(排序, mov/mp4)
static NSArray *RNDDirVideos(NSString *dir) {
    NSArray *fs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *f in fs) {
        NSString *ext = [f pathExtension].lowercaseString;
        if ([ext isEqualToString:@"mov"] || [ext isEqualToString:@"mp4"]) {
            [out addObject:[dir stringByAppendingPathComponent:f]];
        }
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

// 收集图层树摘要(一次性诊断)
static void RNDWalkLayers(CALayer *layer, int depth, NSMutableString *acc) {
    if (depth > 5) return;
    NSString *extra = @"";
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)layer;
        extra = [NSString stringWithFormat:@"player=%@ ready=%d ", pl.player, pl.readyForDisplay];
    }
    [acc appendFormat:@"\n  d%d %@ %@f=%@ h=%d", depth, NSStringFromClass([layer class]), extra,
        NSStringFromCGRect(layer.frame), layer.isHidden];
    for (CALayer *sub in layer.sublayers) RNDWalkLayers(sub, depth + 1, acc);
}

// 找背景可用的 AVPlayerLayer: 只接受 player 为 nil 的(未绑定)或已绑定我们自己 player 的;
// 跳过绑定着其他 player 的图层(那是播放槽的, 不能抢)
static AVPlayerLayer *RNDFindBackLayer(id view, AVQueuePlayer *ours) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:((UIView *)view).layer];
    while ([stack count]) {
        CALayer *l = [stack objectAtIndex:0];
        [stack removeObjectAtIndex:0];
        if ([l isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayerLayer *pl = (AVPlayerLayer *)l;
            if (pl.player == nil || pl.player == ours) return pl;
        }
        for (CALayer *sub in l.sublayers) [stack addObject:sub];
    }
    return nil;
}

// 在原生素材更新完成后调用: 若该槽位随机启用, 关 looper 并起播第一条
static void RNDApplyForView(id view, BOOL isBack) {
    @try {
        RNDState *st = objc_getAssociatedObject(view, &kRNDStateKey);
        if (!st) { st = [RNDState new]; objc_setAssociatedObject(view, &kRNDStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

        NSString *slot = isBack ? @"BackAsset" : @"PlayingAsset";
        BOOL active = RNDActive(slot);
        NSString *mode = RNDMode(slot);
        NSArray *items = RNDItems(slot);
        // 固定模式: 只显示用户在素材库点选的那一条素材。
        // 切换素材后 picked 变化 -> 下面队列重建逻辑自动换片。
        // (roothide 下原生背景槽播放器不重建, 换片必须由接管方完成)
        if ([mode isEqualToString:@"fixed"]) {
            NSString *pk = RNDPicked(slot);
            if (pk && [[NSFileManager defaultManager] fileExistsAtPath:pk]) {
                items = @[pk];
            }
            RNDLog(@"slot=%@ fixed picked=%@ exists=%d", slot,
                   pk ? [pk lastPathComponent] : @"-", pk && [[NSFileManager defaultManager] fileExistsAtPath:pk]);
        }
        AVQueuePlayer *player = nil;
        id looper = nil;
        if (!isBack) {
            if ([view respondsToSelector:@selector(playingPlayer)]) player = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(playingPlayer));
            if ([view respondsToSelector:@selector(playingLayerLooper)]) looper = ((id (*)(id, SEL))objc_msgSend)(view, @selector(playingLayerLooper));
            st.playingEnabled = active;
            st.player = player;
        } else {
            if ([view respondsToSelector:@selector(backPlayer)]) player = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(backPlayer));
            if ([view respondsToSelector:@selector(backLayerLooper)]) looper = ((id (*)(id, SEL))objc_msgSend)(view, @selector(backLayerLooper));
            st.backEnabled = active;
            if (player) st.backPlayerRef = player;
        }

        // ===== 背景槽兜底接管: 原生没建播放器(roothide 下的缺陷)时, 我们自建 =====
        if (isBack && !player) {
            if (![items count]) items = RNDDirVideos(@"/var/mobile/CCAudioPlay-BackGround/BackAsset");
            if (![items count]) {
                RNDLog(@"slot=BackAsset takeover skip: no files");
            } else {
                player = st.backPlayerRef;
                if (!player) {
                    player = [[AVQueuePlayer alloc] init];
                    player.muted = YES; // 背景视频不发声
                    st.backPlayerRef = player;
                    RNDLog(@"slot=BackAsset takeover: player created");
                }
                AVPlayerLayer *lay = RNDFindBackLayer(view, player);
                if (!lay) {
                    lay = st.createdLayer;
                    if (!lay || !lay.superlayer) {
                        lay = [AVPlayerLayer layer];
                        lay.frame = ((UIView *)view).layer.bounds;
                        lay.videoGravity = AVLayerVideoGravityResizeAspectFill;
                        [((UIView *)view).layer insertSublayer:lay atIndex:0];
                        st.createdLayer = lay;
                        RNDLog(@"slot=BackAsset takeover: layer created");
                    }
                }
                if (lay.player != player) lay.player = player;
                st.backEnabled = YES; // 播完推进需要
                RNDQueue *q = st.backQueue;
                if (!q || ![q.order isEqualToArray:items]) {
                    q = [[RNDQueue alloc] initWithItems:items mode:mode];
                    st.backQueue = q;
                    [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItemBack];
                    st.observingItemBack = nil;
                }
                if (!st.observingItemBack) {
                    RNDPlayNext(st, player, q, view, YES);
                } else if (player.rate == 0.0) {
                    [player play];
                }
                if (!st.treeLogged) {
                    st.treeLogged = YES;
                    NSMutableString *acc = [NSMutableString stringWithFormat:@"BackAsset layer tree:"];
                    RNDWalkLayers(((UIView *)view).layer, 0, acc);
                    RNDLog(@"%@", acc);
                }
                RNDLog(@"slot=BackAsset takeover active: %lu files, layer=%@, cur=%@",
                       (unsigned long)[items count],
                       lay.player == player ? @"bound" : @"NOT-BOUND",
                       player.currentItem ? @"yes" : @"no");
                return;
            }
        }

        if (!active || ![items count] || !player) {
            // 诊断: fixed 模式下把原生 player 当前 item 的真实路径与状态也打出来
            @try {
                AVPlayerItem *cur = player.currentItem;
                if (cur && [cur.asset isKindOfClass:[AVURLAsset class]]) {
                    NSString *up = [(AVURLAsset *)cur.asset URL].path;
                    RNDLog(@"slot=%@ native item: path=%@ exists=%d status=%ld size=%@",
                           slot, up ?: @"-", [[NSFileManager defaultManager] fileExistsAtPath:up ?: @""],
                           (long)cur.status, NSStringFromCGSize(cur.presentationSize));
                } else {
                    RNDLog(@"slot=%@ native: player=%@ currentItem=%@ items=%lu", slot,
                           player ?: @"nil", cur ?: @"nil", (unsigned long)[[player items] count]);
                    // player 为空时 3 秒后复查一次(原生可能是异步建 player)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        @try {
                            AVQueuePlayer *p2 = nil;
                            if (!isBack) { if ([view respondsToSelector:@selector(playingPlayer)]) p2 = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(playingPlayer)); }
                            else { if ([view respondsToSelector:@selector(backPlayer)]) p2 = ((AVQueuePlayer *(*)(id, SEL))objc_msgSend)(view, @selector(backPlayer)); }
                            RNDLog(@"slot=%@ recheck3s: player=%@ items=%lu curStatus=%ld",
                                   slot, p2 ?: @"nil", (unsigned long)[[p2 items] count],
                                   p2.currentItem ? (long)p2.currentItem.status : -1L);
                        } @catch (id e) {}
                    });
                }
            } @catch (id e) {}
            // 诊断: 列出真实FS与 jbroot 内部两处的素材目录, 判断设置页/tweak 是否读写分离
            @try {
                NSString *jb = RNDJbRoot();
                NSArray *bases = @[@"/var/mobile/CCAudioPlay-BackGround",
                                   jb.length ? [jb stringByAppendingPathComponent:@"var/mobile/CCAudioPlay-BackGround"] : nil];
                for (NSString *base in bases) {
                    if (!base) continue;
                    NSString *disp = jb.length ? [base stringByReplacingOccurrencesOfString:jb withString:@"<JB>"] : base;
                    for (NSString *sub in @[@"PlayingAsset", @"BackAsset"]) {
                        NSString *p = [base stringByAppendingPathComponent:sub];
                        NSArray *fs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:nil];
                        RNDLog(@"dirlist %@/%@: %@", disp, sub,
                               [fs count] ? [NSString stringWithFormat:@"%lu files first=%@", (unsigned long)[fs count], [fs firstObject]] : @"EMPTY/MISSING");
                    }
                }
            } @catch (id e) {}
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
            [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:(isBack ? st.observingItemBack : st.observingItem)];
            if (isBack) st.observingItemBack = nil; else st.observingItem = nil;
        }
        if (!(isBack ? st.observingItemBack : st.observingItem)) {
            RNDPlayNext(st, player, q, view, isBack);
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
                    // 关闭/固定/清空则清空该槽位队列状态, 恢复原生行为。
                    // 只清理本次通知对应的槽位, 不能误杀另一槽位的观察(否则它播完一条就停)。
                    NSString *slot = isBack ? @"BackAsset" : @"PlayingAsset";
                    if (!RNDActive(slot) || ![RNDItems(slot) count]) {
                        if (isBack) {
                            st.backQueue = nil;
                            [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItemBack];
                            st.observingItemBack = nil;
                        } else {
                            st.queue = nil;
                            st.playingEnabled = NO;
                            [[NSNotificationCenter defaultCenter] removeObserver:st name:AVPlayerItemDidPlayToEndTimeNotification object:st.observingItem];
                            st.observingItem = nil;
                        }
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
