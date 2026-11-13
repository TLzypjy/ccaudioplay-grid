/**
 * CCAudioPlayFix — 修复 CC 视频素材"自动暂停"
 *
 * 原理: CCAudioPlay 的视频素材由 SpringBoard 内的 AVQueuePlayer(+AVPlayerLooper) 播放,
 *       音频类别为 Ambient。原 dylib 没有监听 AVAudioSession 中断:
 *       任何其他 App 激活音频会话(微信语音/游戏音效/Siri/闹钟/提示音)都会中断
 *       SpringBoard 会话, iOS 将该播放器暂停且永不恢复 —— 表现为"视频素材有时候自动暂停",
 *       而音乐属于音乐 App 自己的会话不受影响。
 *
 * 修复策略(不改动原 dylib, 全部运行时补充):
 *   1. swizzle -[CCCustomView setOnScreen:], 模块回到屏幕时做一次恢复检查
 *      (与原实现相同的恢复条件: 模块可见 + 宿主 VC isPlaying)。
 *   2. 监听 AVAudioSessionInterruptionNotification, 中断结束后分 0.3/1.0/2.5s 三次恢复检查。
 *   3. 2 秒看门狗兜底: 满足恢复条件的被暂停播放器直接 play
 *      (原逻辑对暂停只发生在模块隐藏时, 可见即循环, 因此恢复条件是忠实的)。
 *   4. MediaServicesWereReset(系统音频服务重启, 罕见)时, 通过原 tweak 自己的
 *      Darwin 通知触发素材重建, 让 AVPlayerItem/Looper 重新创建。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CCFLog(fmt, ...) NSLog(@"[CCAudioPlayFix] " fmt, ##__VA_ARGS__)

#pragma mark - 原插件类的前置声明(仅声明接口, 消息运行时解析)

@interface CCCustomView : UIView
@property (nonatomic, readonly) BOOL onScreen;
@property (nonatomic, readonly) UIView *nowPlayingView;
@property (nonatomic, readonly) AVQueuePlayer *playingPlayer;
@property (nonatomic, readonly) AVQueuePlayer *backPlayer;
- (void)setOnScreen:(BOOL)onScreen;
@end

@interface UIView (CCFix_Private)
- (UIViewController *)_viewControllerForAncestor;
@end

#pragma mark - 实例跟踪

static NSHashTable *CCFTrackedViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static BOOL CCFResponds(id obj, SEL sel) {
    return obj != nil && [(id)obj respondsToSelector:sel];
}

static void CCFResumeViewOnce(id view) {
    if (!CCFResponds(view, @selector(onScreen))) return;
    BOOL onScreen = ((BOOL (*)(id, SEL))objc_msgSend)(view, @selector(onScreen));
    if (!onScreen) return;

    // 忠实还原原实现的恢复条件: 宿主 VC isPlaying
    if (CCFResponds(view, @selector(nowPlayingView))) {
        UIView *npv = [(CCCustomView *)view nowPlayingView];
        UIViewController *vc = npv ? [npv _viewControllerForAncestor] : nil;
        if (vc && CCFResponds(vc, @selector(isPlaying))) {
            BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(vc, @selector(isPlaying));
            if (!playing) return;
        }
    }

    BOOL didResume = NO;
    if (CCFResponds(view, @selector(playingPlayer))) {
        AVQueuePlayer *pp = [(CCCustomView *)view playingPlayer];
        if (pp && pp.rate == 0.0) {
            [pp play];
            didResume = YES;
        }
    }
    if (CCFResponds(view, @selector(backPlayer))) {
        AVQueuePlayer *bp = [(CCCustomView *)view backPlayer];
        if (bp && bp.rate == 0.0) {
            [bp play];
            didResume = YES;
        }
    }
    if (didResume) {
        CCFLog(@"resumed paused video player(s) after interruption/stall");
    }
}

static void CCFResumeAllDelayed(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (id view in [[CCFTrackedViews() allObjects] copy]) {
            CCFResumeViewOnce(view);
        }
    });
}

#pragma mark - setOnScreen: swizzle

static void CCF_SwizzleSetOnScreen(Class cls) {
    SEL orig = @selector(setOnScreen:);
    SEL mine = @selector(ccf_setOnScreen:);
    Method m = class_getInstanceMethod(cls, orig);
    if (!m || class_getInstanceMethod(cls, mine)) return;

    IMP newIMP = imp_implementationWithBlock(^void(id self, BOOL on) {
        // 原实现
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, mine, on);

        NSHashTable *table = CCFTrackedViews();
        @synchronized (table) { [table addObject:self]; }

        if (on) {
            CCFResumeAllDelayed(0.25);
            CCFResumeAllDelayed(1.0);
        }
    });
    // 先把 block 的 IMP 装到 ccf_setOnScreen:, 再交换, 这样 block 里调 mine 即原实现
    BOOL added = class_addMethod(cls, mine, newIMP, "v@:B");
    if (!added) return;
    method_exchangeImplementations(class_getInstanceMethod(cls, orig),
                                   class_getInstanceMethod(cls, mine));
}

#pragma mark - 通知 + 看门狗

static void CCFSetupObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:AVAudioSessionInterruptionNotification
                    object:[AVAudioSession sharedInstance]
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSNumber *typeNum = [note.userInfo objectForKey:AVAudioSessionInterruptionTypeKey];
        if (!typeNum) return;
        if ([typeNum unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) {
            CCFResumeAllDelayed(0.3);
            CCFResumeAllDelayed(1.0);
            CCFResumeAllDelayed(2.5);
        }
    }];

    // 音频服务被系统重启(极少): 播放器对象可能失效, 用原 tweak 的 Darwin 通知触发重建
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                    object:[AVAudioSession sharedInstance]
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        CCFLog(@"media services reset -> trigger asset rebuild via darwin notify");
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.thefool.ccaudioplaypres/updatePlayingAssetNotificationt"), NULL, NULL, YES);
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.thefool.ccaudioplaypres/updateBackAssetNotificationt"), NULL, NULL, YES);
        CCFResumeAllDelayed(1.0);
        CCFResumeAllDelayed(3.0);
    }];

    // 2s 看门狗: 满足"模块可见+音乐播放中"却被暂停的播放器自动恢复
    static dispatch_source_t watchdogTimer; // 常驻强持有
    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        for (id view in [[CCFTrackedViews() allObjects] copy]) {
            CCFResumeViewOnce(view);
        }
    });
    dispatch_resume(timer);
    watchdogTimer = timer;
}

#pragma mark - 入口

__attribute__((constructor))
static void CCAudioPlayFixEntry(void) {
    @autoreleasepool {
        Class cls = objc_getClass("CCCustomView");
        if (!cls) {
            CCFLog(@"CCCustomView not found (tweak not loaded?) — fix inactive");
            return;
        }
        CCF_SwizzleSetOnScreen(cls);
        CCFSetupObservers();
        CCFLog(@"installed (tracked class CCCustomView)");
    }
}
