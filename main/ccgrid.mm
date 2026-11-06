/**
 * CCAudioPlayPres — 网格素材库 loader
 *
 * 原理: 本二进制替换偏好设置 bundle 的主程序(CFBundleExecutable),
 *       +load 时 dlopen 同目录下的 CCAudioPlayPresCore(原二进制),
 *       原有全部设置逻辑(滑条/颜色/遮罩/3x2 自定义...)原样保留;
 *       swizzle CCAssetCell 的两个素材入口 + 细胞初始化:
 *       -selectExistingAsset(从已有素材选择): 列表式 SandboxFileBrowser -> 网格素材库;
 *       -selectImagePicker(从相册选择, 改名「素材目录」): 拉起 Filza 定位到该行素材的
 *       磁盘保存目录 (官方 URL 形式 filza://view/<路径>);
 *       -initWithStyle:reuseIdentifier:specifier: 后扫描按钮把「从相册选择」改为「素材目录」
 *       (相册导入功能保留在网格库右上角"导入"入口)。
 *       三列网格 + GIF/视频 角标 + 名字胶囊 + 选中圆点,
 *       长按进入抖动编辑态(红-删除 + 点名字行内改名), 右上角导入(相册/文件)。
 *
 * 与原 CCAssetCell 的对接(与旧 SandboxFileBrowser 完全一致的委托调用):
 *   选中: fileBrowser:didSelectFilePath:fileName:
 *   取消: fileBrowserDidCancel:
 *   删除: fileBrowser:deleteFileName:filePath:     (本 UI 先删文件再回调)
 *   改名: fileBrowser:renameNewFileName:oldFileName:filePath: (本 UI 先 move 再回调)
 * 存储逻辑(写 plist/发 Darwin 通知/更新行文字)全部在 CCAssetCell 原实现里, 不做任何改动。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

#define CCG_SEL(s) sel_registerName(s)
#define CCG_CLS(s) ((id)objc_getClass(s))

@class CCGBrowserViewController;

static inline id CCG_MSG1(id o, SEL s, id a) { return ((id(*)(id, SEL, id))objc_msgSend)(o, s, a); }
static inline id CCG_MSG0(id o, SEL s) { return ((id(*)(id, SEL))objc_msgSend)(o, s); }
static inline BOOL CCG_RESP(id o, SEL s) { return ((BOOL(*)(id, SEL, SEL))objc_msgSend)(o, sel_registerName("respondsToSelector:"), s); }
static inline CGRect CCGRect(double x, double y, double w, double h) { CGRect r = {{x, y}, {w, h}}; return r; }

// 媒体扩展名分类
static NSSet *CCGImageExts(void) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"bmp", @"tiff"]];
    });
    return s;
}
static NSSet *CCGVideoExts(void) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v"]];
    });
    return s;
}

// ---------- 缩略图 ----------
static void *gImageIOLib = NULL;
static void *fnCGSrcCreate = NULL, *fnCGSrcImg = NULL, *fnCGSrcCount = NULL;
static void CCGEnsureLibs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gImageIOLib = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY);
        if (gImageIOLib) {
            fnCGSrcCreate = dlsym(gImageIOLib, "CGImageSourceCreateWithData");
            fnCGSrcImg = dlsym(gImageIOLib, "CGImageSourceCreateImageAtIndex");
            fnCGSrcCount = dlsym(gImageIOLib, "CGImageSourceGetCount");
        }
    });
}

// 统一缩到方形小图(卡片显示尺寸的 retina 倍), 控制内存: 1080p 帧解出来是 8MB, 不缩会爆。
// 注意用"居中裁切填满"(AspectFill)而不是 letterbox: 否则黑边会被烘进图里,
// 卡片再做 AspectFill 就只能整体缩小, 看起来两边留黑不填满。
static UIImage *CCGSquareThumb(UIImage *img, double side) {
    if (!img) return nil;
    double w = img.size.width, h = img.size.height;
    if (w <= 1 || h <= 1) return img;
    // 取短边做正方形裁切区域
    double cropSide = MIN(w, h);
    CGRect crop = CGRectMake((w - cropSide) / 2.0, (h - cropSide) / 2.0, cropSide, cropSide);
    CGImageRef cg = img.CGImage;
    if (cg) {
        double sx = CGImageGetWidth(cg) / w, sy = CGImageGetHeight(cg) / h;
        CGRect pxCrop = CGRectMake(crop.origin.x * sx, crop.origin.y * sy,
                                   crop.size.width * sx, crop.size.height * sy);
        CGImageRef cropped = CGImageCreateWithImageInRect(cg, pxCrop);
        if (cropped) {
            img = [UIImage imageWithCGImage:cropped];
            CGImageRelease(cropped);
        }
    }
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 1.0);
    [img drawInRect:CCGRect(0, 0, side, side)];
    UIImage *outImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return outImg ?: img;
}

// 设置进程里 objc_getClass("AVURLAsset") 可能拿到不响应消息的假类(实测会转发崩溃),
// 原二进制用的是编译期类引用 -> 直接从 CCAudioPlayPresCore 的 __objc_classrefs 槽位读真类指针。
// 槽位 VA 由逆向原二进制得出 (bundle 固定文件, 不会变):
//   0xc6520 -> _OBJC_CLASS_$_AVURLAsset
//   0xc6528 -> _OBJC_CLASS_$_AVAssetImageGenerator
static Class gRealAVURLAsset = Nil;
static Class gRealAVAssetImageGenerator = Nil;

static void CCGCacheRealAVFClasses(void) {
    if (gRealAVURLAsset || gRealAVAssetImageGenerator) return;
    @try {
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            const char *base = strstr(nm, "CCAudioPlayPresCore");
            if (!base || strcmp(base, "CCAudioPlayPresCore") != 0) continue;
            uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            void *slotA = (void *)(slide + 0xc6520);
            void *slotG = (void *)(slide + 0xc6528);
            Class a = *(__unsafe_unretained Class *)slotA;
            Class g = *(__unsafe_unretained Class *)slotG;
            if (a && [(id)a respondsToSelector:CCG_SEL("URLAssetWithURL:options:")]) gRealAVURLAsset = a;
            if (g && [(id)g respondsToSelector:CCG_SEL("assetImageGeneratorWithAsset:")]) gRealAVAssetImageGenerator = g;
            break;
        }
    } @catch (id e) {}
}

static UIImage *CCGThumbForPath(NSString *path) {
    @try {
        CCGEnsureLibs();
        if (!path || !fnCGSrcCreate || !fnCGSrcImg) return nil;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return nil;
        CGImageSourceRef src = ((CGImageSourceRef(*)(CFDataRef, CFDictionaryRef))fnCGSrcCreate)((__bridge CFDataRef)data, NULL);
        if (!src) return nil;
        CGImageRef cg = ((CGImageRef(*)(CGImageSourceRef, size_t, CFDictionaryRef))fnCGSrcImg)(src, 0, NULL);
        CFRelease(src);
        if (!cg) return nil;
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return CCGSquareThumb(img, 400.0);
    } @catch (id e) {
        return nil;
    }
}

// 调试日志(缩略图失败时能定位到哪一步), 写 /var/mobile/Documents/ccgrid_debug.log
static void CCGDbg(NSString *line) {
    @try {
        NSString *p = @"/var/mobile/Documents/ccgrid_debug.log";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        NSMutableString *existing = nil;
        if ([attr fileSize] > 0 && [attr fileSize] < 60000) {
            existing = [NSMutableString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        }
        NSString *ts = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
        NSMutableString *next = existing ?: [NSMutableString string];
        [next appendString:ts];
        [next writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

static UIImage *CCGVideoThumbForPath(NSString *path) {
    @try {
        CCGCacheRealAVFClasses();
        Class assetCls = gRealAVURLAsset;
        Class genCls = gRealAVAssetImageGenerator;
        if (!assetCls) { CCGDbg(@"AVF: real AVURLAsset unavailable"); return nil; }
        if (!genCls) { CCGDbg(@"AVF: real AVAssetImageGenerator unavailable"); return nil; }
        NSURL *url = [NSURL fileURLWithPath:path];
        // 不用 respondsToSelector 当门槛(此进程里结果不可信, 原插件也是直接调用),
        // 全部真调用 + @try 接异常, 失败一路降级
        id asset = ((id(*)(id, SEL, id, id))objc_msgSend)(assetCls, CCG_SEL("URLAssetWithURL:options:"), url, nil);
        if (!asset) { CCGDbg(@"AVF: asset nil"); return nil; }
        id gen = ((id(*)(id, SEL, id))objc_msgSend)(genCls, CCG_SEL("assetImageGeneratorWithAsset:"), asset);
        if (!gen) { CCGDbg(@"AVF: gen nil"); return nil; }
        ((void(*)(id, SEL, id))objc_msgSend)(gen, CCG_SEL("setAppliesPreferredTrackTransform:"), (id)kCFBooleanTrue);
        // 手工构造 CMTime{value=0, timescale=1, flags=Valid, epoch=0}, 不引入 CoreMedia 链接依赖
        typedef struct { long long value; int timescale; unsigned flags; long long epoch; } CCGTime;
        CCGTime t; t.value = 0; t.timescale = 1; t.flags = 1; t.epoch = 0;
        // 注意: 新 iOS 上是三段选择器 copyCGImageAtTime:actualTime:error:
        // (逆向原插件得其真实调用; 两段的旧方法已不存在, 之前一直因此失败)
        CGImageRef cg = ((CGImageRef(*)(id, SEL, CCGTime *, void *, void *))objc_msgSend)(
            gen, CCG_SEL("copyCGImageAtTime:actualTime:error:"), &t, NULL, NULL);
        if (!cg) {
            CCGDbg([NSString stringWithFormat:@"AVF: cg nil (gen=%@)", [gen class]]);
            return nil;
        }
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        if (!img) return nil;
        UIImage *small = CCGSquareThumb(img, 400.0);
        CCGDbg(@"AVF: ok");
        return small;
    } @catch (id e) {
        // 转发异常也在这里接住
        CCGDbg(@"AVF: exception (copyCGImage)");
        return nil;
    }
}

// ---------- QuickLook 缩略图兜底(独立框架 dlopen, 不依赖进程里已加载什么) ----------
// 异步生成完成后回主线程就地刷新对应 cell 的 imageView (tag 930)
static void CCGQLThumbAsync(NSString *path, NSString *name, NSIndexPath *ip, __weak CCGBrowserViewController *wself) {
    @try {
        static void *qlLib = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // 同 AVF: 先补伞层再补子框架, 防止类/方法只注册了一半
            dlopen("/System/Library/Frameworks/QuickLook.framework/QuickLook", RTLD_LAZY);
            qlLib = dlopen("/System/Library/Frameworks/QuickLookThumbnailing.framework/QuickLookThumbnailing", RTLD_LAZY);
        });
        Class qlCls = objc_getClass("QLThumbnailGenerator");
        if (!qlLib || !qlCls) { CCGDbg(@"QL: framework/class unavailable"); return; }
        // 不用 respondsToSelector 当门槛, 直接调, 异常 @try 接
        double scale = [UIScreen mainScreen].scale;
        id gen = ((id(*)(id, SEL, CGSize, double, long long))objc_msgSend)(
            qlCls, CCG_SEL("generatorWithMaximumSize:scale:requestOptions:"), CGSizeMake(600, 600), scale, 0);
        if (!gen) { CCGDbg(@"QL: generator nil"); return; }
        NSURL *url = [NSURL fileURLWithPath:path];
        void (^blk)(id, id) = ^(id thumb, id err) {
            @try {
                UIImage *img = nil;
                if (thumb && [thumb respondsToSelector:CCG_SEL("uiKitImage")]) {
                    img = CCG_MSG0(thumb, CCG_SEL("uiKitImage"));
                }
                if (!img && thumb && [thumb respondsToSelector:CCG_SEL("CGImage")]) {
                    CGImageRef cg = (__bridge CGImageRef)CCG_MSG0(thumb, CCG_SEL("CGImage"));
                    if (cg) img = [UIImage imageWithCGImage:cg];
                }
                if (!img) { CCGDbg(@"QL: completion no image"); return; }
                CCGDbg(@"QL: ok");
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        id s = wself;
                        if (!s) return;
                        ((void(*)(id, SEL, id, id, id))objc_msgSend)(s, CCG_SEL("qlGotThumb:forName:atIp:"), img, name, ip);
                    } @catch (id e) {}
                });
            } @catch (id e) { CCGDbg(@"QL: completion exception"); }
        };
        ((void(*)(id, SEL, id, void (^)(id, id)))objc_msgSend)(gen, CCG_SEL("generateBestRepresentationForFile:completionHandler:"), url, blk);
    } @catch (id e) { CCGDbg(@"QL: exception"); }
}

// ---------- 编辑态 associated key ----------
static const char kCCGDelKey = 0;   // 删除按钮 -> 文件名
static const char kCCGNameKey = 0;  // 名字点按手势 -> 文件名

// 记住用户点选的素材名(跨会话, 重进素材库蓝点不丢)
static NSString *CCGPickStoreKey(NSString *dir) {
    return [NSString stringWithFormat:@"CCGridPicked::%@", dir ?: @""];
}
static NSString *CCGLoadPicked(NSString *dir) {
    @try {
        return [[NSUserDefaults standardUserDefaults] stringForKey:CCGPickStoreKey(dir)];
    } @catch (id e) { return nil; }
}
static void CCGSavePicked(NSString *dir, NSString *name) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (name.length) [ud setObject:name forKey:CCGPickStoreKey(dir)];
        else [ud removeObjectForKey:CCGPickStoreKey(dir)];
        [ud synchronize];
    } @catch (id e) {}
}

// ============ 网格素材库 ============
@interface CCGBrowserViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegate,
                                                        UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                                                        UIDocumentPickerDelegate, UITextFieldDelegate>
{
    __weak id _cell;                 // CCAssetCell (SandboxFileBrowserDelegate)
    NSString *_dir;                  // 当前目录
    NSMutableArray *_files;          // 文件/目录名(仅末级)
    NSMutableDictionary *_thumbs;    // 名字 -> UIImage
    NSString *_selName;              // 从细胞读到的选中名(格式未知, 仅参考)
    NSString *_pickedName;           // 本界面实际点选的素材名(绝对准确, 蓝点以它为准)
    UICollectionView *_cv;
    // 导入暂存
    id _pendImg;
    NSURL *_pendURL;
    BOOL _pendVideo;
    // 编辑态
    BOOL _editMode;
    UILongPressGestureRecognizer *_editLP;
    UITextField *_activeField;
    NSString *_activeName;
    id _activeCell;
    id _activeLabel;
    id _activeIp;
    double _preKbdOY;
    BOOL _isRoot;                    // 是否根目录(决定"关闭"行为)
    CGPoint _lastTapPt;              // 普通模式下点名字直接改名的位置检测
    double _lastTapAt;
    NSMutableSet *_qlPending;        // QuickLook 异步生成中的素材名(防重复请求)
    NSString *_pendSelPath;          // 去抖: 待执行的点选全路径
    NSString *_pendSelName;          // 去抖: 待执行的点选名
}
- (instancetype)initWithCell:(id)cell directory:(NSString *)dir isRoot:(BOOL)root;
- (void)closeTapped;
- (void)importTapped;
- (void)reloadFiles;
- (void)qlGotThumb:(UIImage *)img forName:(NSString *)name atIp:(NSIndexPath *)ip;
- (void)genThumbInBackgroundForName:(NSString *)name path:(NSString *)full isVideo:(BOOL)isVideo ip:(NSIndexPath *)ip;
@end

@implementation CCGBrowserViewController

- (instancetype)initWithCell:(id)cell directory:(NSString *)dir isRoot:(BOOL)root {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _cell = cell;
        _dir = [dir copy];
        _isRoot = root;
        _files = [NSMutableArray array];
        _thumbs = [NSMutableDictionary dictionary];
        _qlPending = [NSMutableSet set];
        _lastTapPt = CGPointMake(-9999, -9999);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setTitle:@"素材库"];
    [self view].backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(closeTapped)];
    [self navigationItem].leftBarButtonItem = close;
    UIBarButtonItem *imp = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(importTapped)];
    [self navigationItem].rightBarButtonItem = imp;

    // 当前选中素材名: 优先用本界面保存过的点选记录(跨会话稳定), 细胞存储仅作参考
    @try {
        id c = _cell;
        if (c && [c respondsToSelector:@selector(Key)] && [c respondsToSelector:@selector(assetNameWithKey:)]) {
            id key = CCG_MSG0(c, CCG_SEL("Key"));
            _selName = CCG_MSG1(c, CCG_SEL("assetNameWithKey:"), key);
        }
    } @catch (id e) { _selName = nil; }
    _pickedName = CCGLoadPicked(_dir);

    UICollectionViewFlowLayout *flow = [[UICollectionViewFlowLayout alloc] init];
    [flow setMinimumInteritemSpacing:0];
    [flow setMinimumLineSpacing:14];
    [flow setSectionInset:UIEdgeInsetsMake(14, 16, 70, 16)];
    // item 宽 = (容器宽-32)/3, 卡片宽 = item宽-12 (左右各缩6), 卡片为正方形;
    // 下方 58pt: 胶囊(8+22) + 圆点(36+16) + 4pt 余量, 任何机型都不会互相遮挡
    CGRect sb = [UIScreen mainScreen].bounds;
    double iw = (sb.size.width - 32.0) / 3.0;
    double ih = (iw - 12.0) + 58.0;
    [flow setItemSize:CGSizeMake(iw, ih)];

    _cv = [[UICollectionView alloc] initWithFrame:[self view].bounds collectionViewLayout:flow];
    [_cv setBackgroundColor:[UIColor clearColor]];
    [_cv setDelegate:self];
    [_cv setDataSource:self];
    [_cv setAlwaysBounceVertical:YES];
    [_cv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [_cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"ccgm"];
    _editLP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressTapped:)];
    [_editLP setMinimumPressDuration:0.4];
    [_cv addGestureRecognizer:_editLP];
    [[self view] addSubview:_cv];

    [self reloadFiles];

    // 打印素材根目录与缓存目录, 方便在文件管理器里找到/清理 .ccthumbs
    CCGDbg([NSString stringWithFormat:@"DIR root=%@ | cache=%@", _dir,
            [[self class] ccgThumbDir:_dir]]);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbdWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbdDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbdWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_cv) return;
    // 兜底: 任何宽度下保证一行恰好 3 个且不遮挡
    UICollectionViewFlowLayout *fl = (UICollectionViewFlowLayout *)_cv.collectionViewLayout;
    double want = (_cv.bounds.size.width - 32.0) / 3.0;
    if (want > 1.0 && fabs(fl.itemSize.width - want) > 1.0) {
        [fl setItemSize:CGSizeMake(want, (want - 12.0) + 58.0)];
        [fl setMinimumInteritemSpacing:0];
        [fl setMinimumLineSpacing:14];
        [fl setSectionInset:UIEdgeInsetsMake(14, 16, 70, 16)];
        [fl invalidateLayout];
    }
}

// ---------- 数据 ----------
- (void)reloadFiles {
    [self reloadFiles:NO];
}

- (void)reloadFiles:(BOOL)keepThumbs {
    // 刷新当前选中素材名(删除/改名后细胞侧可能已更新存储)
    @try {
        id c = _cell;
        if (c && [c respondsToSelector:@selector(Key)] && [c respondsToSelector:@selector(assetNameWithKey:)]) {
            id key = CCG_MSG0(c, CCG_SEL("Key"));
            NSString *cur = CCG_MSG1(c, CCG_SEL("assetNameWithKey:"), key);
            if (cur) _selName = cur;
        }
    } @catch (id e) {}
    NSMutableArray *arr = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *all = [fm contentsOfDirectoryAtPath:_dir error:nil];
    for (NSString *nm in all) {
        if (!nm || [nm hasPrefix:@"."]) continue;
        NSString *full = [_dir stringByAppendingPathComponent:nm];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [arr addObject:nm];
            continue;
        }
        NSString *ext = [[nm pathExtension] lowercaseString];
        if ([CCGImageExts() containsObject:ext] || [CCGVideoExts() containsObject:ext]) {
            [arr addObject:nm];
        }
    }
    [arr sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (!keepThumbs) {
        // 丢弃已不存在的缩略图
        NSArray *keys = [_thumbs allKeys];
        for (NSString *k in keys) {
            if (![arr containsObject:k]) [_thumbs removeObjectForKey:k];
        }
    }
    _files = arr;
    NSString *cnt = [NSString stringWithFormat:@"素材库 (%lu)", (unsigned long)[_files count]];
    if (_editMode) cnt = @"长按完成退出";
    [self setTitle:cnt];
    [_cv reloadData];
    if (_editMode) [self startJiggling];
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return (NSInteger)[_files count];
}

- (void)jiggleCard:(UIView *)card {    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.rotation"];
    [anim setFromValue:@(-0.03)];
    [anim setToValue:@(0.03)];
    [anim setDuration:0.12];
    [anim setAutoreverses:YES];
    [anim setRepeatCount:100000];
    [card.layer addAnimation:anim forKey:@"ccgJiggle"];
}

- (void)startJiggling {
    for (UICollectionViewCell *c in [_cv visibleCells]) {
        UIView *card = [c viewWithTag:911];
        if (card) [self jiggleCard:card];
    }
}

- (void)stopJiggling {
    for (UICollectionViewCell *c in [_cv visibleCells]) {
        UIView *card = [c viewWithTag:911];
        if (card) [card.layer removeAnimationForKey:@"ccgJiggle"];
    }
}

- (void)enterEditing {
    if (_editMode) return;
    _editMode = YES;
    [self setTitle:@"长按完成退出"];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(exitEditing)];
    [self navigationItem].rightBarButtonItem = done;
    [_editLP setEnabled:NO]; // 编辑态禁用长按, 防抢占删除钮点击
    [_cv reloadData];
    [self startJiggling];
}

- (void)exitEditing {
    if (!_editMode) return;
    if (_activeField) [_activeField resignFirstResponder];
    [self stopJiggling];
    _editMode = NO;
    [_editLP setEnabled:YES];
    UIBarButtonItem *imp = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(importTapped)];
    [self navigationItem].rightBarButtonItem = imp;
    [self setTitle:[NSString stringWithFormat:@"素材库 (%lu)", (unsigned long)[_files count]]];
    [_cv reloadData];
}

// QuickLook 异步回调: 缓存缩略图并就地刷新可见 cell
- (void)qlGotThumb:(UIImage *)img forName:(NSString *)name atIp:(NSIndexPath *)ip {
    @try {
        if (!img || !_cv || _thumbs == nil) return;
        [_thumbs setObject:img forKey:name];
        [_qlPending removeObject:name];
        UICollectionViewCell *cell = [_cv cellForItemAtIndexPath:ip];
        if (cell) {
            UIImageView *iv = (UIImageView *)[cell viewWithTag:930];
            [iv setImage:img];
        }
    } @catch (id e) {}
}

// 缩略图磁盘缓存: 首帧只取一次, 落盘后永久复用(文件改动会因 mtime 变化自动重取)
// 缓存目录 = 素材目录下的 .ccthumbs (点前缀不会出现在列表里)
- (NSString *)thumbCachePathForFull:(NSString *)full {
    @try {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        long long mt = (long long)([attr fileModificationDate].timeIntervalSince1970);
        NSString *base = [full stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        return [[[self class] ccgThumbDir:_dir] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%lld.jpg", base, mt]];
    } @catch (id e) {
        return nil;
    }
}

+ (NSString *)ccgThumbDir:(NSString *)dir {
    return [dir stringByAppendingPathComponent:@".ccthumbs"];
}

// 缩略图后台生成: ① 磁盘缓存命中直接用 ② 未命中才解码首帧并落盘 ③ AVF 失败落 QL 兜底
// 完成后主线程就地刷新对应 cell
- (void)genThumbInBackgroundForName:(NSString *)name path:(NSString *)full isVideo:(BOOL)isVideo ip:(NSIndexPath *)ip {
    if ([_qlPending containsObject:name]) return;
    [_qlPending addObject:name];
    NSIndexPath *ipCopy = [ip copy];
    NSString *nameCopy = [name copy];
    NSString *fullCopy = [full copy];
    NSString *dirCopy = [_dir copy];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        UIImage *img = nil;
        NSString *cachePath = nil;
        @try {
            // ① 磁盘缓存(键含 mtime, 素材改动自动失效)
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fullCopy error:nil];
            long long mt = (long long)([attr fileModificationDate].timeIntervalSince1970);
            NSString *base = [fullCopy stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            cachePath = [[[CCGBrowserViewController ccgThumbDir:dirCopy]
                stringByAppendingPathComponent:[NSString stringWithFormat:@"v2_%@.%lld.jpg", base, mt]] copy];

            if (cachePath && [[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
                img = [UIImage imageWithContentsOfFile:cachePath];   // 秒出, 不解码视频
            }

            // ② 未命中: 解码首帧并落盘
            if (!img) {
                img = isVideo ? CCGVideoThumbForPath(fullCopy) : CCGThumbForPath(fullCopy);
                if (img && cachePath) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:
                        [cachePath stringByDeletingLastPathComponent]
                        withIntermediateDirectories:YES attributes:nil error:nil];
                    NSData *jd = UIImageJPEGRepresentation(img, 0.82);
                    if (jd) [jd writeToFile:cachePath atomically:YES];
                }
            }
        } @catch (id e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!_cv) return;
                if (img) {
                    [_thumbs setObject:img forKey:nameCopy];
                } else if (isVideo) {
                    // AVF 取帧失败 -> QuickLook 异步兜底
                    [_qlPending removeObject:nameCopy];
                    dispatch_async(dispatch_get_global_queue(0, 0), ^{
                        CCGQLThumbAsync(fullCopy, nameCopy, ipCopy, self);
                    });
                    return;
                }
                [_qlPending removeObject:nameCopy];
                UICollectionViewCell *cell = [_cv cellForItemAtIndexPath:ipCopy];
                if (cell) {
                    UIImageView *iv = (UIImageView *)[cell viewWithTag:930];
                    [iv setImage:img];
                }
            } @catch (id e) {}
        });
    });
}

- (void)longPressTapped:(UILongPressGestureRecognizer *)lp {
    if ([lp state] != UIGestureRecognizerStateBegan) return;
    CGPoint p = [lp locationInView:_cv];
    NSIndexPath *ip = [_cv indexPathForItemAtPoint:p];
    if (!ip) return;
    NSInteger row = [ip item];
    if (row >= (NSInteger)[_files count]) return;
    [self enterEditing];
}

- (void)delBtnTapped:(UITapGestureRecognizer *)g {
    NSString *name = objc_getAssociatedObject(g, &kCCGDelKey);
    if (name) [self confirmDelete:name];
}

- (void)nameTapped:(UITapGestureRecognizer *)g {
    NSString *name = objc_getAssociatedObject(g, &kCCGNameKey);
    if (!name) return;
    UIView *pill = [g view];
    UIView *contentV = [pill superview];
    UICollectionViewCell *cell = (UICollectionViewCell *)[contentV superview];
    if (!cell) return;
    [self beginRename:name inCell:cell atPill:pill];
}

// ---------- cell ----------
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"ccgm" forIndexPath:ip];
    for (UIView *v in [cell contentView].subviews) [v removeFromSuperview];

    NSInteger row = [ip item];
    if (row >= (NSInteger)[_files count]) return cell;
    NSString *name = [_files objectAtIndex:row];
    NSString *full = [_dir stringByAppendingPathComponent:name];

    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir];

    // 与布局公式完全一致: item 宽 = (容器宽-32)/3, 卡片 = item宽-12
    double cvW = [self view].bounds.size.width;
    if (cvW < 2.0) cvW = [UIScreen mainScreen].bounds.size.width;
    double cardW = (cvW - 32.0) / 3.0 - 12.0;
    double imgH = cardW;

    // 白色圆角卡片(不裁切, 让删除钮伸出右上角)
    UIView *card = [[UIView alloc] initWithFrame:CCGRect(6, 0, cardW, imgH)];
    [card setBackgroundColor:[UIColor whiteColor]];
    [card setTag:911];
    [card.layer setCornerRadius:14.0];

    if (isDir) {
        // 目录: 简单文件夹样式
        UILabel *dirLabel = [[UILabel alloc] initWithFrame:card.bounds];
        [dirLabel setText:@"📁"];
        [dirLabel setTextAlignment:NSTextAlignmentCenter];
        [dirLabel setFont:[UIFont systemFontOfSize:44.0]];
        [dirLabel setBackgroundColor:[UIColor colorWithWhite:0.92 alpha:1.0]];
        [dirLabel.layer setCornerRadius:14.0];
        [dirLabel.layer setMasksToBounds:YES];
        [card addSubview:dirLabel];
        UILabel *badge = [[UILabel alloc] initWithFrame:CCGRect(6, 6, 34, 16)];
        [badge setText:@"目录"];
        [badge setFont:[UIFont systemFontOfSize:9.0]];
        [badge setTextAlignment:NSTextAlignmentCenter];
        [badge setBackgroundColor:[UIColor colorWithWhite:0.0 alpha:0.55]];
        [badge setTextColor:[UIColor whiteColor]];
        [badge.layer setCornerRadius:8.0];
        [badge.layer setMasksToBounds:YES];
        [card addSubview:badge];
        [[cell contentView] addSubview:card];
    } else {
        NSString *ext = [[name pathExtension] lowercaseString];
        BOOL isVideo = [CCGVideoExts() containsObject:ext];
        BOOL isGif = [ext isEqualToString:@"gif"];
        NSString *typeTag = isVideo ? @"视频" : (isGif ? @"GIF" : @"图片");

        UIImage *thumb = [_thumbs objectForKey:name];
        if (!thumb && !isDir) {
            // 缩略图后台生成(主线程同步解码视频帧会卡滑动), 完成后就地刷新对应 cell
            [self genThumbInBackgroundForName:name path:full isVideo:isVideo ip:ip];
        }
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CCGRect(0, 0, cardW, imgH)];
        [iv setTag:930];
        [iv setImage:thumb];
        [iv setContentMode:UIViewContentModeScaleAspectFill];
        [iv setBackgroundColor:[UIColor colorWithWhite:0.9 alpha:1.0]];
        [iv.layer setCornerRadius:14.0];
        [iv.layer setMasksToBounds:YES];
        [card addSubview:iv];

        // 左上角类型角标
        UILabel *badge = [[UILabel alloc] initWithFrame:CCGRect(6, 6, 34, 16)];
        [badge setText:typeTag];
        [badge setFont:[UIFont systemFontOfSize:9.0]];
        [badge setTextAlignment:NSTextAlignmentCenter];
        [badge setBackgroundColor:[UIColor colorWithWhite:0.0 alpha:0.55]];
        [badge setTextColor:[UIColor whiteColor]];
        [badge.layer setCornerRadius:8.0];
        [badge.layer setMasksToBounds:YES];
        [card addSubview:badge];

        // 视频左下角播放标志
        if (isVideo) {
            UIView *vb = [[UIView alloc] initWithFrame:CCGRect(6, imgH - 30, 24, 24)];
            [vb setBackgroundColor:[UIColor colorWithWhite:0.0 alpha:0.45]];
            [vb.layer setCornerRadius:12.0];
            [vb.layer setMasksToBounds:YES];
            UILabel *pl = [[UILabel alloc] initWithFrame:CCGRect(0, -1, 24, 24)];
            [pl setText:@"▶"];
            [pl setFont:[UIFont systemFontOfSize:11.0]];
            [pl setTextAlignment:NSTextAlignmentCenter];
            [pl setTextColor:[UIColor whiteColor]];
            [vb addSubview:pl];
            [card addSubview:vb];
        }

        // 编辑态删除钮
        if (_editMode) {
            UIButton *delv = [[UIButton alloc] initWithFrame:CCGRect(cardW - 14, -12, 26, 26)];
            [delv setBackgroundColor:[UIColor redColor]];
            [delv.layer setCornerRadius:13.0];
            [delv.layer setMasksToBounds:YES];
            [delv setTitle:@"-" forState:UIControlStateNormal];
            [delv setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [delv.titleLabel setFont:[UIFont boldSystemFontOfSize:19.0]];
            [delv addTarget:self action:@selector(delBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:delv];
            objc_setAssociatedObject(delv, &kCCGDelKey, name, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [[cell contentView] addSubview:card];
    }

    if (_editMode) [self jiggleCard:card];

    // 名字胶囊(仅编辑态可点 -> 行内改名; 普通态穿透给 cell = 选中素材)
    UIView *pill = [[UIView alloc] initWithFrame:CCGRect(10, imgH + 8, cardW - 8, 22)];
    [pill setTag:921];
    [pill setBackgroundColor:[UIColor colorWithWhite:0.62 alpha:0.85]];
    [pill setUserInteractionEnabled:_editMode];
    [pill.layer setCornerRadius:11.0];
    [pill.layer setMasksToBounds:YES];
    UILabel *plb = [[UILabel alloc] initWithFrame:CCGRect(0, 0, cardW - 8, 22)];
    [plb setText:name];
    [plb setFont:[UIFont systemFontOfSize:11.0]];
    [plb setTextAlignment:NSTextAlignmentCenter];
    [plb setTextColor:[UIColor whiteColor]];
    [plb setTag:922];
    [pill addSubview:plb];
    [[cell contentView] addSubview:pill];
    UITapGestureRecognizer *ng = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nameTapped:)];
    [pill addGestureRecognizer:ng];
    objc_setAssociatedObject(ng, &kCCGNameKey, name, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 选中圆点(目录/编辑态不显示)
    // 蓝点以用户在本界面实际点选的素材为准(原始细胞存储名格式不可控);
    // 首次进入时用细胞里读到的名字兜底匹配
    if (!_editMode && !isDir) {
        NSString *base = [name stringByDeletingPathExtension];
        BOOL on = NO;
        if (_pickedName.length) {
            on = [[[_pickedName lastPathComponent] stringByDeletingPathExtension] isEqualToString:base];
        } else if (_selName.length) {
            on = [[[_selName lastPathComponent] stringByDeletingPathExtension] isEqualToString:base];
        }
         UIView *dot = [[UIView alloc] initWithFrame:CCGRect(6 + cardW / 2 - 9, imgH + 35, 18, 18)];
         [dot.layer setCornerRadius:9.0];
        [dot.layer setMasksToBounds:YES];
        [dot setBackgroundColor:on ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.80 alpha:1.0]];
        [[cell contentView] addSubview:dot];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (_editMode) return;
    NSInteger row = [ip item];
    if (row >= (NSInteger)[_files count]) return;
    NSString *name = [_files objectAtIndex:row];
    NSString *full = [_dir stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir];

    if (isDir) {
        // 子目录: 推入新浏览器(同一 delegate)
        CCGBrowserViewController *sub = [[CCGBrowserViewController alloc] initWithCell:_cell directory:full isRoot:NO];
        [[self navigationController] pushViewController:sub animated:YES];
        return;
    }
    // 选择素材: 原细胞会读整个视频文件+写配置(主线程重活), 然后 dismiss 整个弹出层。
    // 1) 蓝点立即重绘(用 _pickedName, 不等原细胞)
    // 2) 原细胞调用做 0.3s 去抖: 连续快速点选时只执行最后一次, 避免排队卡死主线程
    // 3) 递一个透明"替身"VC 接住原细胞自带的 dismiss, 网格留在原地
    id d = _cell;
    if (d && [d respondsToSelector:@selector(fileBrowser:didSelectFilePath:fileName:)]) {
        _pickedName = name;
        _selName = name;
        CCGSavePicked(_dir, name);   // 持久化, 重进素材库蓝点仍在
        [_cv reloadData];   // 圆点立即切换

        _pendSelPath = [full copy];
        _pendSelName = [name copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 只有仍是最新一次点选才真正调用原细胞(去抖)
            if (![self->_pendSelPath isEqualToString:full]) return;
            NSString *p = self->_pendSelPath;
            NSString *n = self->_pendSelName;
            self->_pendSelPath = nil;
            self->_pendSelName = nil;
            UIViewController *sacrifice = [[UIViewController alloc] init];
            [sacrifice setModalPresentationStyle:UIModalPresentationOverFullScreen];
            [sacrifice setView:[[UIView alloc] initWithFrame:CGRectZero]];
            [self presentViewController:sacrifice animated:NO completion:^{
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(d, CCG_SEL("fileBrowser:didSelectFilePath:fileName:"), self, p, n);
            }];
        });
    } else {
        [self closeTapped];
    }
}

// ---------- 删除 ----------
- (void)confirmDelete:(NSString *)name {
    NSString *full = [_dir stringByAppendingPathComponent:name];
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"删除素材"
                                                                message:[NSString stringWithFormat:@"确定删除「%@」? 不可恢复", name]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *yes = [UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        // 先算缩略图缓存路径(依赖被删文件的 mtime)
        NSString *thumbCache = [self thumbCachePathForFull:full];
        [[NSFileManager defaultManager] removeItemAtPath:full error:nil];
        [_thumbs removeObjectForKey:name];
        if (_pickedName && [_pickedName isEqualToString:name]) { _pickedName = nil; CCGSavePicked(_dir, nil); }
        if (thumbCache) [[NSFileManager defaultManager] removeItemAtPath:thumbCache error:nil];
        [self reloadFiles];   // 立即刷新列表
        id d = _cell;
        if (d && [d respondsToSelector:@selector(fileBrowser:deleteFileName:filePath:)]) {
            // 原实现删除后也会 dismiss 整个素材库; 用替身 VC 接住, 删除后留在网格里
            UIViewController *sacrifice = [[UIViewController alloc] init];
            [sacrifice setModalPresentationStyle:UIModalPresentationOverFullScreen];
            [sacrifice setView:[[UIView alloc] initWithFrame:CGRectZero]];
            [self presentViewController:sacrifice animated:NO completion:^{
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(d, CCG_SEL("fileBrowser:deleteFileName:filePath:"), self, name, full);
            }];
        }
    }];
    UIAlertAction *cc = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [al addAction:yes];
    [al addAction:cc];
    [self presentViewController:al animated:YES completion:nil];
}

// ---------- 行内改名 ----------
- (void)beginRename:(NSString *)name inCell:(id)cell atPill:(id)pill {
    if (_activeField) [_activeField resignFirstResponder];
    UILabel *lab = (UILabel *)[pill viewWithTag:922];
    CGRect lf = [pill frame];
    if (lab) [lab setHidden:YES];
    _activeIp = [_cv indexPathForCell:(UICollectionViewCell *)cell];
    _preKbdOY = _cv.contentOffset.y;
    UITextField *tf = [[UITextField alloc] initWithFrame:lf];
    [tf setText:name];
    [tf setFont:[UIFont systemFontOfSize:11.0]];
    [tf setTextAlignment:NSTextAlignmentCenter];
    [tf setBorderStyle:UITextBorderStyleRoundedRect];
    [tf setReturnKeyType:UIReturnKeyDone];
    [tf setClearButtonMode:UITextFieldViewModeWhileEditing];
    [tf setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [tf setAutocorrectionType:UITextAutocorrectionTypeNo];
    [tf setDelegate:self];
    [tf setTag:955];
    [[cell contentView] addSubview:tf];
    _activeField = tf;
    _activeName = name;
    _activeCell = cell;
    _activeLabel = lab;
    [tf becomeFirstResponder];
}

- (double)kbdTargetOffsetForCell:(UIView *)cell kbH:(double)kbH {
    CGRect fr = [cell frame];
    CGRect cvb = [_cv bounds];
    UIEdgeInsets ins = [_cv contentInset];
    double want = fr.origin.y + fr.size.height + 46.0 - (cvb.size.height - kbH);
    double st = [_cv safeAreaInsets].top;
    if (want < -st) want = -st;
    double maxOff = [_cv contentSize].height + ins.bottom - cvb.size.height;
    if (maxOff < 0) maxOff = 0;
    if (want > maxOff) want = maxOff;
    return want;
}

- (void)kbdApplyInset:(double)kbH {
    UIEdgeInsets ins = [_cv contentInset];
    ins.bottom = kbH + 8.0;
    [_cv setContentInset:ins];
}

- (double)clampOffsetY:(double)y {
    double minOff = -[_cv safeAreaInsets].top;
    double maxOff = [_cv contentSize].height - [_cv bounds].size.height;
    if (maxOff < minOff) maxOff = minOff;
    if (y < minOff) y = minOff;
    if (y > maxOff) y = maxOff;
    return y;
}

- (double)kbdHeightFromNote:(NSNotification *)n {
    double kbH = 0;
    NSDictionary *ui = [n userInfo];
    if (ui) {
        NSValue *kbv = [ui objectForKey:UIKeyboardFrameEndUserInfoKey];
        if (kbv) kbH = [kbv CGRectValue].size.height;
    }
    return kbH;
}

- (void)kbdScrollToActive:(double)kbH {
    if (kbH <= 0 || !_activeCell) return;
    [self kbdApplyInset:kbH];
    double offY = [self kbdTargetOffsetForCell:_activeCell kbH:kbH];
    CGPoint pt = [_cv contentOffset];
    pt.y = offY;
    [_cv setContentOffset:pt animated:YES];
}

- (void)kbdWillShow:(NSNotification *)n {
    if (!_activeIp) return;
    @try { [self kbdScrollToActive:[self kbdHeightFromNote:n]]; } @catch (id e) {}
}

- (void)kbdDidShow:(NSNotification *)n {
    if (!_activeIp) return;
    @try { [self kbdScrollToActive:[self kbdHeightFromNote:n]]; } @catch (id e) {}
}

- (void)kbdWillHide:(NSNotification *)n {
    @try {
        UIEdgeInsets ins = [_cv contentInset];
        ins.bottom = 0;
        [_cv setContentInset:ins];
        CGPoint rp = [_cv contentOffset];
        rp.y = [self clampOffsetY:_preKbdOY];
        [_cv setContentOffset:rp animated:NO];
    } @catch (id e) {}
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)doRename:(NSString *)old to:(NSString *)newName {
    if (!newName || [newName length] == 0) return;
    newName = [[newName componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"];
    newName = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![newName length] || [newName isEqualToString:old]) return;
    // 未带扩展名时补上原扩展名, 防止素材丢失类型
    NSString *oldExt = [[old pathExtension] lowercaseString];
    if ([newName pathExtension].length == 0 && [oldExt length] > 0) {
        newName = [newName stringByAppendingPathExtension:oldExt];
    }
    NSString *src = [_dir stringByAppendingPathComponent:old];
    NSString *dst = [_dir stringByAppendingPathComponent:newName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) { [self showTip:@"已存在同名素材"]; return; }
    NSError *err = nil;
    if ([fm moveItemAtPath:src toPath:dst error:&err]) {
        [_thumbs removeObjectForKey:old];
        if (_pickedName && [_pickedName isEqualToString:old]) { _pickedName = newName; CCGSavePicked(_dir, newName); }
        // 同步移动缩略图缓存(同文件 mtime 不变, 仅路径键变化)
        NSString *oldCache = [self thumbCachePathForFull:src];
        NSString *newCache = [self thumbCachePathForFull:dst];
        if (oldCache && [[NSFileManager defaultManager] fileExistsAtPath:oldCache]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:
                [newCache stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:newCache error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:oldCache toPath:newCache error:nil];
        }
        id d = _cell;
        if (d && [d respondsToSelector:@selector(fileBrowser:renameNewFileName:oldFileName:filePath:)]) {
            ((void(*)(id, SEL, id, id, id, id))objc_msgSend)(d, CCG_SEL("fileBrowser:renameNewFileName:oldFileName:filePath:"),
                                                             self, newName, old, src);
        }
        [self reloadFiles];
    } else {
        [self showTip:err.localizedDescription ?: @"改名失败"];
    }
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf != _activeField) return;
    NSString *old = _activeName;
    NSString *nn = [tf text];
    [tf removeFromSuperview];
    @try {
        CGPoint rp = [_cv contentOffset];
        rp.y = [self clampOffsetY:_preKbdOY];
        [_cv setContentOffset:rp animated:YES];
    } @catch (id e) {}
    _activeField = nil;
    _activeName = nil;
    _activeCell = nil;
    _activeIp = nil;
    if (_activeLabel) { [_activeLabel setHidden:NO]; _activeLabel = nil; }
    if (old && nn && [nn length] > 0) [self doRename:old to:nn];
}

// ---------- 提示 ----------
- (void)showTip:(NSString *)msg {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"提示" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

// ---------- 关闭 ----------
- (void)closeTapped {
    id d = _cell;
    if (_isRoot) {
        // 与旧 dismissBrowser 相同: 通知 delegate 取消, 由细胞关掉整个弹出层
        if (d && [d respondsToSelector:@selector(fileBrowserDidCancel:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(d, CCG_SEL("fileBrowserDidCancel:"), self);
        }
        if ([self presentingViewController]) [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

// ---------- 导入 ----------
- (void)importTapped {
    // iPad 上 actionSheet 需要锚点, 退回 alert 样式
    UIAlertControllerStyle style = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIAlertControllerStyleAlert : UIAlertControllerStyleActionSheet;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"导入素材" message:@"选择来源" preferredStyle:style];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从相册" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openPhotos]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openFiles]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openPhotos {
    UIImagePickerController *pc = [[UIImagePickerController alloc] init];
    [pc setSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
    [pc setMediaTypes:@[@"public.image", @"public.movie"]];
    [pc setDelegate:self];
    [pc setAllowsEditing:NO];
    [self presentViewController:pc animated:YES completion:nil];
}

- (void)openFiles {
    Class utCls = objc_getClass("UTType");
    NSArray *types;
    if (utCls) {
        id utImage = ((id(*)(id, SEL))objc_msgSend)(utCls, CCG_SEL("image"));
        id utMovie = ((id(*)(id, SEL))objc_msgSend)(utCls, CCG_SEL("movie"));
        types = [NSArray arrayWithObjects:utImage, utMovie, nil];
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
        [dp setDelegate:self];
        [self presentViewController:dp animated:YES completion:nil];
        return;
    }
    // 兜底: 旧 API (iOS 13)
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.image", @"public.movie"] inMode:UIDocumentPickerModeImport];
    [dp setDelegate:self];
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSString *mt = [info objectForKey:UIImagePickerControllerMediaType];
    _pendVideo = mt && [mt isEqualToString:@"public.movie"];
    if (_pendVideo) {
        _pendURL = [info objectForKey:UIImagePickerControllerMediaURL];
    } else {
        // 图片优先取原始文件 URL (保住 GIF 动图)
        _pendURL = [info objectForKey:UIImagePickerControllerImageURL] ?: [info objectForKey:UIImagePickerControllerMediaURL];
    }
    _pendImg = _pendURL ? nil : [info objectForKey:UIImagePickerControllerOriginalImage];
    [self dismissViewControllerAnimated:YES completion:nil];
    [self performSelector:@selector(showNaming) withObject:nil afterDelay:0.5];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    _pendImg = nil;
    _pendURL = [urls firstObject];
    NSString *ext = [[_pendURL pathExtension] lowercaseString];
    _pendVideo = [CCGVideoExts() containsObject:ext];
    [self dismissViewControllerAnimated:YES completion:nil];
    [self performSelector:@selector(showNaming) withObject:nil afterDelay:0.5];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showNaming {
    [self askNameAndSave:_pendImg url:_pendURL isVideo:_pendVideo];
    _pendImg = nil;
    _pendURL = nil;
}

- (void)askNameAndSave:(UIImage *)img url:(NSURL *)srcURL isVideo:(BOOL)isVideo {
    if (!img && !srcURL) return;
    NSString *defaultName = @"新素材";
    if (srcURL) {
        defaultName = [[srcURL lastPathComponent] stringByDeletingPathExtension];
        defaultName = [[defaultName componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"];
        if (![defaultName length]) defaultName = @"新素材";
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"命名素材" message:@"给这个素材起个名字" preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        [tf setPlaceholder:@"素材名称"];
        [tf setText:defaultName];
    }];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UITextField *tf = [[al textFields] firstObject];
        NSString *nm = [tf text];
        if (!nm || [nm length] == 0) nm = @"新素材";
        [self saveMaterial:nm image:img url:srcURL isVideo:isVideo];
    }];
    [al addAction:ok];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)saveMaterial:(NSString *)nm image:(UIImage *)img url:(NSURL *)srcURL isVideo:(BOOL)isVideo {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_dir]) {
        [fm createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *safe = [[nm componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"];
    safe = [safe stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!safe || [safe length] == 0) safe = @"新素材";

    NSString *ext = nil;
    if (isVideo) {
        NSString *se = srcURL ? [[srcURL pathExtension] lowercaseString] : @"";
        ext = [CCGVideoExts() containsObject:se] ? se : @"mov";
    } else if (img && !srcURL) {
        ext = @"jpg";
    } else {
        NSString *se = srcURL ? [[srcURL pathExtension] lowercaseString] : @"";
        if ([CCGImageExts() containsObject:se]) ext = se;
        else if ([CCGVideoExts() containsObject:se]) ext = se; // 混合类型兜底
        else ext = @"jpg";
    }
    NSString *dst = [_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", safe, ext]];

    // 同名去重
    NSString *base = dst;
    int idx = 2;
    while ([fm fileExistsAtPath:dst]) {
        dst = [NSString stringWithFormat:@"%@ %d.%@", [[base stringByDeletingLastPathComponent] stringByAppendingPathComponent:[base.lastPathComponent stringByDeletingPathExtension]], idx, [base pathExtension]];
        idx++;
        if (idx > 99) break;
    }

    BOOL ok = NO;
    BOOL scoped = NO;
    if (srcURL) {
        scoped = [srcURL startAccessingSecurityScopedResource];
        // 优先走原细胞 copyFileFromURL:toPath: (带 NSData 兜底, 与原导入路径一致)
        id d = _cell;
        if (d && [d respondsToSelector:@selector(copyFileFromURL:toPath:)]) {
            ((void(*)(id, SEL, id, id))objc_msgSend)(d, CCG_SEL("copyFileFromURL:toPath:"), srcURL, dst);
            ok = [fm fileExistsAtPath:dst];
        }
        if (!ok) ok = [fm copyItemAtURL:srcURL toURL:[NSURL fileURLWithPath:dst] error:nil];
        if (scoped) [srcURL stopAccessingSecurityScopedResource];
    } else if (img) {
        NSData *data = UIImageJPEGRepresentation(img, 0.9);
        ok = [data writeToFile:dst atomically:YES];
    }
    (void)ok;
    [self reloadFiles];
    // 导入成功: 后台取一次首帧并落盘缩略图缓存, 之后打开素材库秒出图、永不重复解码
    NSString *dstName = [dst lastPathComponent];
    BOOL dstIsVideo = [CCGVideoExts() containsObject:[[dstName pathExtension] lowercaseString]];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [self genThumbInBackgroundForName:dstName path:dst isVideo:dstIsVideo ip:nil];
    });
}

@end

// ============ swizzle ============
static void (*gOrigSelectExistingAsset)(id, SEL) = NULL;
static void (*gOrigSelectImagePicker)(id, SEL) = NULL;
static id (*gOrigAssetCellInit)(id, SEL, long, id, id) = NULL;

// 按钮改名: 「从相册选择」的功能已被换成"跳转素材目录(Filza)", 标题同步改成「素材目录」。
// 原文字不在包内任何文件里(运行时拼出/roothide 处理), 所以不走文本补丁,
// 而是在细胞初始化完成后递归扫描子树, 对含"相册"字样的按钮直接改标题。
static void CCGScanRetitle(id view) {
    @try {
        for (UIView *sub in [view subviews]) {
            if ([sub isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)sub;
                NSString *t = [b titleForState:UIControlStateNormal] ?: [b titleLabel].text;
                if (t && [t containsString:@"相册"]) {
                    [b setTitle:@"素材目录" forState:UIControlStateNormal];
                    [b setTitle:@"素材目录" forState:UIControlStateHighlighted];
                    [[b titleLabel] setText:@"素材目录"];
                }
            }
            CCGScanRetitle(sub);
        }
    } @catch (id e) {}
}

static id CCGAssetCellInit(id self, SEL _cmd, long style, id rid, id spec) {
    id r = gOrigAssetCellInit(self, _cmd, style, rid, spec);
    CCGScanRetitle(self);
    return r;
}

static void CCGSelectExistingAsset(id self, SEL _cmd) {
    @try {
        UIViewController *host = nil;
        if ([self respondsToSelector:@selector(_viewControllerForAncestor)]) {
            host = ((UIViewController *(*)(id, SEL))objc_msgSend)(self, CCG_SEL("_viewControllerForAncestor"));
        }
        if (!host) {
            // 兜底: key window root
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindow *w = ((UIWindowScene *)scene).keyWindow;
                    if (w) { host = w.rootViewController; break; }
                }
            }
            if (!host) host = [UIApplication sharedApplication].keyWindow.rootViewController;
        }
        if (!host) return;
        NSString *root = nil;
        if ([self respondsToSelector:@selector(rootAssetPath)]) {
            root = ((NSString *(*)(id, SEL))objc_msgSend)(self, CCG_SEL("rootAssetPath"));
        }
        if (!root) root = NSHomeDirectory();
        CCGBrowserViewController *vc = [[CCGBrowserViewController alloc] initWithCell:self directory:root isRoot:YES];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [nav setModalPresentationStyle:UIModalPresentationPageSheet];
        [host presentViewController:nav animated:YES completion:nil];
    } @catch (id e) {
        // 失败兜底走原实现
        if (gOrigSelectExistingAsset) gOrigSelectExistingAsset(self, _cmd);
    }
}

// 「从相册选择」按钮: 不再弹系统相册, 改为拉起 Filza 定位到该行素材的磁盘保存目录
// (即 rootAssetPath, 与网格素材库打开的是同一个真实目录; 相册导入仍走网格库右上角"导入")。
// URL 形式踩坑记录:
//   v109 filza://view?path=%2Fvar%2F...  -> Filza 打开但不跳转 (查询参数形式非官方格式, 且 Filza 不反转义)
//   v110 filza://view?path=/var/...      -> URL 无路径成分, Filza 原样停在原处 (用户看=没反应)
//   官方文档(tigisoftware)只有路径拼接形式: filza://view/路径/到/目标
//   (scheme=filza, host=view, 目标路径就是 URL 的 path; 例: filza://view/Applications/Filza.app)
//   -> v111 用 filza://view + 去尾斜杠的原始路径 (仅转义空格/引号/非ASCII等非法字符)。
// 注意: 不用 canOpenURL (filza 未在宿主 Info.plist 的 LSApplicationQueriesSchemes 声明时必返回 NO),
// 直接 openURL 异步拉起, completionHandler 传 nil -> 不回调进本进程, 无 PAC 风险;
// 目录拿不到/构造失败时退回原相册实现。
static void CCGSelectImagePicker(id self, SEL _cmd) {
    @try {
        NSString *root = nil;
        if ([self respondsToSelector:@selector(rootAssetPath)]) {
            root = ((NSString *(*)(id, SEL))objc_msgSend)(self, CCG_SEL("rootAssetPath"));
        }
        if (![root length]) {
            if (gOrigSelectImagePicker) gOrigSelectImagePicker(self, _cmd);
            return;
        }
        // 去掉尾部斜杠(rootAssetPath 以 / 结尾), 拼成 filza://view/var/mobile/...
        NSString *path = root;
        while ([path length] > 1 && [path hasSuffix:@"/"]) {
            path = [path substringToIndex:[path length] - 1];
        }
        // 最小转义: 字母数字与 -._~/:!$'()*,;=@ 原样保留, 其余(空格 # % <> 引号 中文等)才转义
        NSMutableCharacterSet *allowed = [[NSMutableCharacterSet alphanumericCharacterSet] mutableCopy];
        [allowed addCharactersInString:@"-._~/:!$'()*,;=@"];
        NSString *enc = [path stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", enc]];
        if (!url) {
            if (gOrigSelectImagePicker) gOrigSelectImagePicker(self, _cmd);
            return;
        }
        SEL openSel = CCG_SEL("openURL:options:completionHandler:");
        UIApplication *app = [UIApplication sharedApplication];
        if ([app respondsToSelector:openSel]) {
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(app, openSel, url, [NSDictionary dictionary], nil);
        } else {
            // 极老系统兜底
            ((void(*)(id, SEL, id))objc_msgSend)(app, CCG_SEL("openURL:"), url);
        }
    } @catch (id e) {
        if (gOrigSelectImagePicker) gOrigSelectImagePicker(self, _cmd);
    }
}

static void CCGSwizzleAfterCoreLoad(void) {
    Class cell = objc_getClass("CCAssetCell");
    if (!cell) return;
    SEL sel = CCG_SEL("selectExistingAsset");
    Method m = class_getInstanceMethod(cell, sel);
    if (m) {
        gOrigSelectExistingAsset = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)CCGSelectExistingAsset);
    }
    // 「从相册选择」-> 拉起 Filza 定位素材目录
    SEL selIP = CCG_SEL("selectImagePicker");
    Method mIP = class_getInstanceMethod(cell, selIP);
    if (mIP) {
        gOrigSelectImagePicker = (void (*)(id, SEL))method_getImplementation(mIP);
        method_setImplementation(mIP, (IMP)CCGSelectImagePicker);
    }
    // 细胞初始化后把「从相册选择」按钮改名为「素材目录」
    SEL selInit = CCG_SEL("initWithStyle:reuseIdentifier:specifier:");
    Method mInit = class_getInstanceMethod(cell, selInit);
    if (mInit) {
        gOrigAssetCellInit = (id (*)(id, SEL, long, id, id))method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)CCGAssetCellInit);
    }
}

@interface CCGBootstrap : NSObject
@end
@implementation CCGBootstrap
+ (void)load {
    @autoreleasepool {
        Dl_info info;
        if (dladdr((void *)&CCGSwizzleAfterCoreLoad, &info) && info.dli_fname) {
            NSString *mine = [NSString stringWithUTF8String:info.dli_fname];
            NSString *core = [[mine stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"CCAudioPlayPresCore"];
            dlopen([core fileSystemRepresentation], RTLD_NOW);
        }
        CCGSwizzleAfterCoreLoad();
    }
}
@end
