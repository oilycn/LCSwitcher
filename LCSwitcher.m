//
//  LCSwitcher.m
//  LiveContainer / Gnoix 单任务 & 多任务全能侧边栏切换器插件 (Tweak)
//

#import "LCSwitcher.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// MARK: - 私有接口声明

@interface NSUserDefaults (LCPrivate)
+ (nullable NSDictionary<NSString *, id> *)guestAppInfo;
+ (nullable NSBundle *)lcMainBundle;
@end

@class LCSwitcherOverlayController;
@class LCSwitcherOverlayWindow;
@class LCSwitcherBeadView;
@class LCSwitcherDrawerView;
@class LCSwitcherHandoffView;

// MARK: - 强制跟随系统旋转 & 画面缩放 Hook 与单应用状态管理

static BOOL gForceAutoRotateEnabled = NO;
static BOOL gOrientationHooksInstalled = NO;
static CGFloat gScreenScale = 1.0;
static BOOL gScaleHooksInstalled = NO;
static BOOL gIsApplyingWindowScale = NO;
static BOOL gIsMultitaskHostMode = NO;
static BOOL gMultitaskHooksInstalled = NO;
static void LCHideLCMultitaskDockWindow(id dockMgr);

static BOOL LCIsMultitaskExtensionProcess(void) {
    const char *exePath = _dyld_get_image_name(0);
    if (exePath && strstr(exePath, ".appex/")) {
        return YES;
    }
    NSString *procName = [NSProcessInfo processInfo].processName;
    if ([procName containsString:@"LiveProcess"] || [procName containsString:@"Multitask"]) {
        return YES;
    }
    if ([[NSBundle mainBundle].bundlePath hasSuffix:@".appex"]) {
        return YES;
    }
    return NO;
}

static Class LCFindHostClass(NSString *baseName) {
    if (!baseName.length) return Nil;
    Class c = NSClassFromString(baseName);
    if (c) return c;
    c = NSClassFromString([@"LiveContainer." stringByAppendingString:baseName]);
    if (c) return c;
    c = NSClassFromString([@"LiveContainerSwiftUI." stringByAppendingString:baseName]);
    if (c) return c;
    c = NSClassFromString([@"Gnoix." stringByAppendingString:baseName]);
    return c;
}

static BOOL LCIsLiveContainerHostProcess(void) {
    if (LCIsMultitaskExtensionProcess()) return NO;
    NSString *bundlePath = [NSBundle mainBundle].bundlePath ?: @"";
    if ([bundlePath containsString:@"/Documents/Applications/"]) {
        return NO;
    }
    if (NSClassFromString(@"DecoratedAppSceneViewController") != nil ||
        NSClassFromString(@"PiPManager") != nil ||
        NSClassFromString(@"LCMultitaskSceneViewController") != nil) {
        return YES;
    }
    return NO;
}

static CFMutableDictionaryRef gOrigShouldAutorotateIMPs = NULL;
static CFMutableDictionaryRef gOrigSupportedOrientationsIMPs = NULL;
static void (*orig_VC_viewWillAppear)(id, SEL, BOOL) = NULL;
static UIInterfaceOrientationMask (*orig_App_supportedInterfaceOrientationsForWindow)(id, SEL, UIWindow *) = NULL;
static UIInterfaceOrientationMask (*orig_Delegate_supportedInterfaceOrientationsForWindow)(id, SEL, UIApplication *, UIWindow *) = NULL;
static void (*orig_Window_setFrame)(id, SEL, CGRect) = NULL;

static UIInterfaceOrientationMask LCDesiredAutoRotateMask(void) {
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

static NSString *LCForceAutoRotateKeyForFolder(NSString *folderName) {
    if (!folderName.length) {
        return @"LCSwitcher_ForceAutoRotate_default";
    }
    return [NSString stringWithFormat:@"LCSwitcher_ForceAutoRotate_%@", folderName];
}

static BOOL LCLoadForceAutoRotateForFolder(NSString *folderName) {
    NSString *key = LCForceAutoRotateKeyForFolder(folderName);
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

static void LCSaveForceAutoRotateForFolder(NSString *folderName, BOOL enabled) {
    NSString *key = LCForceAutoRotateKeyForFolder(folderName);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:enabled forKey:key];
    [ud synchronize];
    gForceAutoRotateEnabled = enabled;
}

static BOOL hook_VC_shouldAutorotate(id self, SEL _cmd) {
    if (gForceAutoRotateEnabled) {
        return YES;
    }
    if (gOrigShouldAutorotateIMPs) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        IMP orig = m ? (IMP)CFDictionaryGetValue(gOrigShouldAutorotateIMPs, m) : NULL;
        if (orig) {
            return ((BOOL (*)(id, SEL))orig)(self, _cmd);
        }
    }
    return YES;
}

static UIInterfaceOrientationMask hook_VC_supportedInterfaceOrientations(id self, SEL _cmd) {
    if (gForceAutoRotateEnabled) {
        return LCDesiredAutoRotateMask();
    }
    if (gOrigSupportedOrientationsIMPs) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        IMP orig = m ? (IMP)CFDictionaryGetValue(gOrigSupportedOrientationsIMPs, m) : NULL;
        if (orig) {
            return ((UIInterfaceOrientationMask (*)(id, SEL))orig)(self, _cmd);
        }
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

static UIInterfaceOrientationMask hook_App_supportedInterfaceOrientationsForWindow(id self, SEL _cmd, UIWindow *window) {
    if (gForceAutoRotateEnabled) {
        return LCDesiredAutoRotateMask();
    }
    return orig_App_supportedInterfaceOrientationsForWindow ? orig_App_supportedInterfaceOrientationsForWindow(self, _cmd, window) : UIInterfaceOrientationMaskAllButUpsideDown;
}

static UIInterfaceOrientationMask hook_Delegate_supportedInterfaceOrientationsForWindow(id self, SEL _cmd, UIApplication *application, UIWindow *window) {
    if (gForceAutoRotateEnabled) {
        return LCDesiredAutoRotateMask();
    }
    return orig_Delegate_supportedInterfaceOrientationsForWindow ? orig_Delegate_supportedInterfaceOrientationsForWindow(self, _cmd, application, window) : UIInterfaceOrientationMaskAllButUpsideDown;
}

static void LCHookVCClassIfNeeded(Class cls) {
    Class overlayCls = NSClassFromString(@"LCSwitcherOverlayController");
    if (!cls || cls == overlayCls) return;
    if (!gOrigShouldAutorotateIMPs) {
        gOrigShouldAutorotateIMPs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (!gOrigSupportedOrientationsIMPs) {
        gOrigSupportedOrientationsIMPs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }

    for (Class c = cls; c && [c isSubclassOfClass:[UIViewController class]]; c = class_getSuperclass(c)) {
        if (c == overlayCls) continue;

        Method mShouldRotate = class_getInstanceMethod(c, @selector(shouldAutorotate));
        if (mShouldRotate && method_getImplementation(mShouldRotate) != (IMP)hook_VC_shouldAutorotate) {
            IMP orig = method_setImplementation(mShouldRotate, (IMP)hook_VC_shouldAutorotate);
            if (orig && !CFDictionaryContainsKey(gOrigShouldAutorotateIMPs, mShouldRotate)) {
                CFDictionarySetValue(gOrigShouldAutorotateIMPs, mShouldRotate, orig);
            }
        }

        Method mSupported = class_getInstanceMethod(c, @selector(supportedInterfaceOrientations));
        if (mSupported && method_getImplementation(mSupported) != (IMP)hook_VC_supportedInterfaceOrientations) {
            IMP orig = method_setImplementation(mSupported, (IMP)hook_VC_supportedInterfaceOrientations);
            if (orig && !CFDictionaryContainsKey(gOrigSupportedOrientationsIMPs, mSupported)) {
                CFDictionarySetValue(gOrigSupportedOrientationsIMPs, mSupported, orig);
            }
        }
    }
}

static void hook_VC_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gForceAutoRotateEnabled) {
        LCHookVCClassIfNeeded(object_getClass(self));
    }
    if (orig_VC_viewWillAppear) {
        orig_VC_viewWillAppear(self, _cmd, animated);
    }
}

static void LCHookAllActiveViewControllers(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *win in windowScene.windows) {
            NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
            if (win.rootViewController) [queue addObject:win.rootViewController];
            while (queue.count > 0) {
                UIViewController *vc = queue.firstObject;
                [queue removeObjectAtIndex:0];
                LCHookVCClassIfNeeded(object_getClass(vc));
                if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
                for (UIViewController *child in vc.childViewControllers) {
                    [queue addObject:child];
                }
            }
        }
    }
}

static void LCRestoreOrientationMethodEntry(const void *key, const void *value, void *context) {
    Method m = (Method)key;
    IMP orig = (IMP)value;
    if (m && orig) {
        method_setImplementation(m, orig);
    }
}

static void LCRestoreOrientationHooks(void) {
    if (gOrigShouldAutorotateIMPs) {
        CFDictionaryApplyFunction(gOrigShouldAutorotateIMPs, LCRestoreOrientationMethodEntry, NULL);
        CFDictionaryRemoveAllValues(gOrigShouldAutorotateIMPs);
    }
    if (gOrigSupportedOrientationsIMPs) {
        CFDictionaryApplyFunction(gOrigSupportedOrientationsIMPs, LCRestoreOrientationMethodEntry, NULL);
        CFDictionaryRemoveAllValues(gOrigSupportedOrientationsIMPs);
    }
}

static void LCInstallOrientationHooksIfNeeded(void) {
    if (!gForceAutoRotateEnabled) {
        LCRestoreOrientationHooks();
        return;
    }

    if (!gOrientationHooksInstalled) {
        gOrientationHooksInstalled = YES;

        Method mViewWillAppear = class_getInstanceMethod([UIViewController class], @selector(viewWillAppear:));
        if (mViewWillAppear && method_getImplementation(mViewWillAppear) != (IMP)hook_VC_viewWillAppear) {
            orig_VC_viewWillAppear = (void (*)(id, SEL, BOOL))method_setImplementation(mViewWillAppear, (IMP)hook_VC_viewWillAppear);
        }

        Class appClass = [UIApplication class];
        Method mAppSupported = class_getInstanceMethod(appClass, @selector(supportedInterfaceOrientationsForWindow:));
        if (mAppSupported && method_getImplementation(mAppSupported) != (IMP)hook_App_supportedInterfaceOrientationsForWindow) {
            orig_App_supportedInterfaceOrientationsForWindow = (UIInterfaceOrientationMask (*)(id, SEL, UIWindow *))method_setImplementation(mAppSupported, (IMP)hook_App_supportedInterfaceOrientationsForWindow);
        }

        id<UIApplicationDelegate> appDelegate = [UIApplication sharedApplication].delegate;
        if (appDelegate) {
            Class delClass = object_getClass(appDelegate);
            Method mDelSupported = class_getInstanceMethod(delClass, @selector(application:supportedInterfaceOrientationsForWindow:));
            if (mDelSupported && method_getImplementation(mDelSupported) != (IMP)hook_Delegate_supportedInterfaceOrientationsForWindow) {
                orig_Delegate_supportedInterfaceOrientationsForWindow = (UIInterfaceOrientationMask (*)(id, SEL, UIApplication *, UIWindow *))method_setImplementation(mDelSupported, (IMP)hook_Delegate_supportedInterfaceOrientationsForWindow);
            }
        }
    }

    LCHookVCClassIfNeeded([UIViewController class]);
    LCHookVCClassIfNeeded([UINavigationController class]);
    LCHookVCClassIfNeeded([UITabBarController class]);
    LCHookAllActiveViewControllers();
}

static void LCRefreshInterfaceOrientationsNow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gForceAutoRotateEnabled) {
            LCHookAllActiveViewControllers();
        } else {
            LCRestoreOrientationHooks();
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *win in windowScene.windows) {
                UIViewController *vc = win.rootViewController;
                while (vc) {
                    if ([vc respondsToSelector:@selector(setNeedsUpdateOfSupportedInterfaceOrientations)]) {
                        [vc setNeedsUpdateOfSupportedInterfaceOrientations];
                    }
                    vc = vc.presentedViewController;
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [UIViewController attemptRotationToDeviceOrientation];
#pragma clang diagnostic pop
    });
}

static NSString *LCScreenScaleKeyForFolder(NSString *folderName) {
    if (!folderName.length) {
        return @"LCSwitcher_ScreenScale_default";
    }
    return [NSString stringWithFormat:@"LCSwitcher_ScreenScale_%@", folderName];
}

static CGFloat LCLoadScreenScaleForFolder(NSString *folderName) {
    NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:LCScreenScaleKeyForFolder(folderName)];
    if (!val) return 1.0;
    CGFloat s = (CGFloat)val.doubleValue;
    if (s < 0.5 || s > 2.0) return 1.0;
    return s;
}

static void LCSaveScreenScaleForFolder(NSString *folderName, CGFloat scale) {
    CGFloat clamped = MIN(MAX(scale, 0.5), 2.0);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:(double)clamped forKey:LCScreenScaleKeyForFolder(folderName)];
    [ud synchronize];
    gScreenScale = clamped;
}

static BOOL LCShouldScaleWindow(UIWindow *win) {
    if (!win) return NO;
    Class overlayWinCls = NSClassFromString(@"LCSwitcherOverlayWindow");
    if (overlayWinCls && [win isKindOfClass:overlayWinCls]) return NO;
    NSString *clsName = NSStringFromClass([win class]);
    if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"] || [clsName containsString:@"StatusBar"]) {
        return NO;
    }
    return YES;
}

static void LCApplyScaleToWindow(UIWindow *win) {
    if (!LCShouldScaleWindow(win)) return;
    UIWindowScene *ws = win.windowScene;
    CGRect sceneBounds = ws ? ws.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
    if (sceneBounds.size.width <= 0 || sceneBounds.size.height <= 0) return;

    gIsApplyingWindowScale = YES;
    if (fabs(gScreenScale - 1.0) < 0.01) {
        win.transform = CGAffineTransformIdentity;
        win.bounds = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
        win.center = CGPointMake(CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds));
    } else {
        CGFloat scaledW = sceneBounds.size.width / gScreenScale;
        CGFloat scaledH = sceneBounds.size.height / gScreenScale;
        win.bounds = CGRectMake(0, 0, scaledW, scaledH);
        win.center = CGPointMake(CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds));
        win.transform = CGAffineTransformMakeScale(gScreenScale, gScreenScale);
    }
    gIsApplyingWindowScale = NO;
}

static void hook_Window_setFrame(id self, SEL _cmd, CGRect frame) {
    if (orig_Window_setFrame) {
        orig_Window_setFrame(self, _cmd, frame);
    }
    if (!gIsApplyingWindowScale && fabs(gScreenScale - 1.0) >= 0.01 && [self isKindOfClass:[UIWindow class]]) {
        LCApplyScaleToWindow((UIWindow *)self);
    }
}

static void LCInstallScaleHooksIfNeeded(void) {
    if (gScaleHooksInstalled) return;
    gScaleHooksInstalled = YES;
    Method mSetFrame = class_getInstanceMethod([UIWindow class], @selector(setFrame:));
    if (mSetFrame && method_getImplementation(mSetFrame) != (IMP)hook_Window_setFrame) {
        orig_Window_setFrame = (void (*)(id, SEL, CGRect))method_setImplementation(mSetFrame, (IMP)hook_Window_setFrame);
    }
}

static void LCApplyScreenScaleNow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gIsMultitaskHostMode) {
            Class dvcCls = LCFindHostClass(@"DecoratedAppSceneViewController");
            Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
            UIViewController *activeDVC = nil;
            if (dockMgrCls && [dockMgrCls respondsToSelector:@selector(shared)]) {
                id dockMgr = [dockMgrCls valueForKey:@"shared"];
                UIView *hostView = [dockMgr valueForKey:@"windowHostingView"];
                for (UIView *sub in [hostView.subviews reverseObjectEnumerator]) {
                    if (sub.hidden) continue;
                    UIResponder *r = sub.nextResponder;
                    if ([r isKindOfClass:[UIViewController class]] && (!dvcCls || [r isKindOfClass:dvcCls])) {
                        activeDVC = (UIViewController *)r;
                        break;
                    }
                }
            }
            if (!activeDVC && dvcCls) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                        if (win.hidden || !win.rootViewController) continue;
                        NSMutableArray<UIViewController *> *q = [NSMutableArray arrayWithObject:win.rootViewController];
                        while (q.count > 0) {
                            UIViewController *vc = q.firstObject;
                            [q removeObjectAtIndex:0];
                            if ([vc isKindOfClass:dvcCls] && !vc.view.hidden && vc.view.window) {
                                activeDVC = vc;
                            }
                            if (vc.presentedViewController) [q addObject:vc.presentedViewController];
                            [q addObjectsFromArray:vc.childViewControllers];
                        }
                    }
                }
            }
            if (activeDVC) {
                @try {
                    [activeDVC setValue:@(gScreenScale) forKey:@"scaleRatio"];
                    id appSceneVC = [activeDVC valueForKey:@"appSceneVC"];
                    if (appSceneVC) {
                        [appSceneVC setValue:@(gScreenScale) forKey:@"scaleRatio"];
                        UIView *contentView = [appSceneVC valueForKey:@"contentView"];
                        BOOL usesHosting = [[appSceneVC valueForKey:@"usesHostingControllerAPI"] boolValue];
                        if (usesHosting) {
                            contentView.transform = CGAffineTransformMakeScale(gScreenScale, gScreenScale);
                        } else {
                            contentView.layer.sublayerTransform = CATransform3DMakeScale(gScreenScale, gScreenScale, 1.0);
                        }
                        SEL updateSel = NSSelectorFromString(@"updateFrameWithSettingsBlock:");
                        if ([appSceneVC respondsToSelector:updateSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(appSceneVC, updateSel, nil);
                        }
                    }
                } @catch (__unused NSException *e) {}
            }
            // 多任务宿主模式下绝不回退缩放 LC 宿主自身的 UIWindow！
            return;
        }

        LCInstallScaleHooksIfNeeded();
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *win in windowScene.windows) {
                LCApplyScaleToWindow(win);
            }
        }
    });
}

// MARK: - LCSwitcherAppInfo 实现

@implementation LCSwitcherAppInfo

- (instancetype)initWithName:(NSString *)name
                  folderName:(NSString *)folderName
                    bundleId:(NSString *)bundleId
                     version:(NSString *)version
                    dataUUID:(NSString *)dataUUID
                     appPath:(NSString *)appPath
                        icon:(nullable UIImage *)icon
                isJITEnabled:(BOOL)isJITEnabled {
    self = [super init];
    if (self) {
        _name = [name copy] ?: @"";
        _folderName = [folderName copy] ?: @"";
        _bundleId = [bundleId copy] ?: @"";
        _version = [version copy] ?: @"";
        _dataUUID = [dataUUID copy] ?: @"";
        _appPath = [appPath copy] ?: @"";
        _icon = icon;
        _isJITEnabled = isJITEnabled;
    }
    return self;
}

@end

// MARK: - 单任务悬浮微珠视图 (LCSwitcherBeadView)

@interface LCSwitcherBeadView : UIView

@property (nonatomic, assign) BOOL isPinnedRight;
@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onSwipeToOpen)(void);
@property (nonatomic, copy, nullable) void (^onPanMoved)(CGPoint center);
@property (nonatomic, copy, nullable) void (^onPanEnded)(CGPoint center);
@property (nonatomic, copy, nullable) void (^onUserInteraction)(void);

- (void)resetVisualState;

@end

@implementation LCSwitcherBeadView {
    UIVisualEffectView *_blurView;
    UIView *_grabberBarView;
    UIView *_indicatorRingView;
    CGPoint _initialPanCenter;
    BOOL _didTriggerSwipeOpen;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isPinnedRight = YES;
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.clipsToBounds = NO;
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingNone;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _blurView.layer.cornerRadius = self.bounds.size.width / 2.0;
    _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    _blurView.clipsToBounds = YES;
    _blurView.layer.borderWidth = 0.0;
    [self addSubview:_blurView];

    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 6.0;
    self.layer.shadowOffset = CGSizeMake(0, 1);

    // 内部垂直微珠高光胶囊条（无边框纯净毛玻璃感）
    CGFloat barW = 4.0;
    CGFloat barH = 26.0;
    _grabberBarView = [[UIView alloc] initWithFrame:CGRectMake((self.bounds.size.width - barW) / 2.0, (self.bounds.size.height - barH) / 2.0, barW, barH)];
    _grabberBarView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.86];
    _grabberBarView.layer.cornerRadius = barW / 2.0;
    _grabberBarView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _grabberBarView.userInteractionEnabled = NO;
    [_blurView.contentView addSubview:_grabberBarView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0;
    _blurView.layer.cornerRadius = r;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 扩展微珠触摸热区，便于单手贴边快速侧滑呼出
    return CGRectContainsPoint(CGRectInset(self.bounds, -24.0, -16.0), point);
}

- (void)handleTap {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.onUserInteraction) self.onUserInteraction();
    UIView *superview = self.superview;
    if (!superview) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            _initialPanCenter = self.center;
            _didTriggerSwipeOpen = NO;
            [UIView animateWithDuration:0.15 animations:^{
                self.transform = CGAffineTransformMakeScale(1.12, 1.06);
                self.alpha = 1.0;
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [gesture translationInView:superview];
            CGPoint newCenter = CGPointMake(_initialPanCenter.x + translation.x, _initialPanCenter.y + translation.y);
            self.center = newCenter;
            if (self.onPanMoved) self.onPanMoved(newCenter);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGPoint translation = [gesture translationInView:superview];
            CGPoint velocity = [gesture velocityInView:superview];
            CGFloat halfW = superview.bounds.size.width * 0.45;
            BOOL isHorizontalFlick = fabs(translation.x) > fabs(translation.y) * 1.25;
            BOOL swipedInward = self.isPinnedRight
                ? (translation.x < -22.0 && velocity.x < -280.0)
                : (translation.x > 22.0 && velocity.x > 280.0);
            BOOL stayedOnSameHalf = (fabs(translation.x) < halfW);

            [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
                self.transform = CGAffineTransformIdentity;
            } completion:nil];

            if (gesture.state == UIGestureRecognizerStateEnded && isHorizontalFlick && swipedInward && stayedOnSameHalf) {
                // 快速向内轻滑：微珠回弹贴边并呼出抽屉
                [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:0 animations:^{
                    self.center = self->_initialPanCenter;
                } completion:nil];
                if (self.onSwipeToOpen) {
                    self.onSwipeToOpen();
                } else if (self.onTap) {
                    self.onTap();
                }
            } else if (self.onPanEnded) {
                // 正常拖拽（含拖到屏幕对侧左/右边缘或上下调整高度）：吸附到松手一侧并保存位置
                self.onPanEnded(self.center);
            }
            break;
        }
        default:
            break;
    }
}

- (void)resetVisualState {
    self.transform = CGAffineTransformIdentity;
    self.alpha = 1.0;
}

@end

// MARK: - 无缝平滑交接过渡视图 (LCSwitcherHandoffView)

@interface LCSwitcherHandoffView : UIView

- (void)configureWithAppName:(NSString *)appName icon:(nullable UIImage *)icon status:(NSString *)status;
- (void)updateStatus:(NSString *)status;
- (void)showWithCompletion:(nullable void (^)(void))completion;

@end

@implementation LCSwitcherHandoffView {
    UIVisualEffectView *_blurView;
    UIView *_dimView;
    UIView *_cardView;
    UIImageView *_iconImageView;
    UILabel *_titleLabel;
    UILabel *_statusLabel;
    UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.alpha = 0.0;
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blurView];

    _dimView = [[UIView alloc] initWithFrame:self.bounds];
    _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [self addSubview:_dimView];

    _cardView = [[UIView alloc] init];
    _cardView.translatesAutoresizingMaskIntoConstraints = NO;
    _cardView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    _cardView.layer.cornerRadius = 24.0;
    _cardView.layer.cornerCurve = kCACornerCurveContinuous;
    _cardView.layer.borderWidth = 0.8;
    _cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _cardView.layer.shadowOpacity = 0.45;
    _cardView.layer.shadowRadius = 24.0;
    _cardView.layer.shadowOffset = CGSizeMake(0, 8);
    [self addSubview:_cardView];

    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
    _iconImageView.layer.cornerRadius = 18.0;
    _iconImageView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconImageView.clipsToBounds = YES;
    _iconImageView.layer.borderWidth = 0.5;
    _iconImageView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    [_cardView addSubview:_iconImageView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 1;
    [_cardView addSubview:_titleLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.color = [UIColor whiteColor];
    _spinner.hidesWhenStopped = NO;
    [_cardView addSubview:_spinner];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 1;
    [_cardView addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_cardView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_cardView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_cardView.widthAnchor constraintEqualToConstant:240.0],

        [_iconImageView.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:28.0],
        [_iconImageView.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:72.0],
        [_iconImageView.heightAnchor constraintEqualToConstant:72.0],

        [_titleLabel.topAnchor constraintEqualToAnchor:_iconImageView.bottomAnchor constant:16.0],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-16.0],

        [_spinner.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:16.0],
        [_spinner.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],

        [_statusLabel.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:12.0],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16.0],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-16.0],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-24.0]
    ]];
}

- (void)configureWithAppName:(NSString *)appName icon:(nullable UIImage *)icon status:(NSString *)status {
    _titleLabel.text = appName;
    _iconImageView.image = icon ?: [UIImage systemImageNamed:@"app.fill"];
    _statusLabel.text = status;
    [_spinner startAnimating];
}

- (void)updateStatus:(NSString *)status {
    UILabel *lbl = _statusLabel;
    [UIView transitionWithView:lbl duration:0.15 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        lbl.text = status;
    } completion:nil];
}

- (void)showWithCompletion:(nullable void (^)(void))completion {
    UIView *card = _cardView;
    card.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1.0;
        card.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        if (completion) completion();
    }];
}

@end

// MARK: - 画中画管理器 (LCPictureInPictureManager)

@interface LCPictureInPictureManager : NSObject <AVPictureInPictureControllerDelegate>

@property (nonatomic, strong, nullable) AVPictureInPictureController *pipController;
@property (nonatomic, strong, nullable) AVPictureInPictureVideoCallViewController *videoCallVC;
@property (nonatomic, strong, nullable) UIView *wrapperView;
@property (nonatomic, weak, nullable) UIWindow *sourceWindow;
@property (nonatomic, weak, nullable) UIView *capturedView;
@property (nonatomic, assign) CGRect savedFrame;
@property (nonatomic, assign) UIViewAutoresizing savedAutoresizingMask;
@property (nonatomic, assign) CGAffineTransform savedTransform;
@property (nonatomic, copy, nullable) void (^onPiPStateChanged)(BOOL active);

+ (instancetype)sharedManager;
- (BOOL)isPiPActive;
- (void)togglePiPWithCompletion:(nullable void (^)(BOOL active, NSString * _Nullable errorMessage))completion;
- (void)stopPiP;

@end

@implementation LCPictureInPictureManager

+ (instancetype)sharedManager {
    static LCPictureInPictureManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LCPictureInPictureManager alloc] init];
    });
    return instance;
}

- (BOOL)isPiPActive {
    if (gIsMultitaskHostMode) {
        Class pipCls = NSClassFromString(@"PiPManager");
        if (pipCls && [pipCls respondsToSelector:@selector(shared)]) {
            id pipMgr = [pipCls valueForKey:@"shared"];
            if (pipMgr) {
                @try {
                    return [[pipMgr valueForKey:@"isPiP"] boolValue];
                } @catch (__unused NSException *e) {}
            }
        }
    }
    return self.pipController && self.pipController.isPictureInPictureActive;
}

- (nullable UIWindow *)findPrimaryTargetWindow {
    Class overlayWinCls = NSClassFromString(@"LCSwitcherOverlayWindow");
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (overlayWinCls && [win isKindOfClass:overlayWinCls]) continue;
            if (win.hidden || !win.rootViewController) continue;
            NSString *clsName = NSStringFromClass([win class]);
            if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"] || [clsName containsString:@"StatusBar"]) continue;
            if (win.isKeyWindow) return win;
            if (!fallback) fallback = win;
        }
    }
    return fallback;
}

- (void)togglePiPWithCompletion:(nullable void (^)(BOOL active, NSString * _Nullable errorMessage))completion {
    if (gIsMultitaskHostMode) {
        Class pipCls = NSClassFromString(@"PiPManager");
        if (pipCls && [pipCls respondsToSelector:@selector(shared)]) {
            id pipMgr = [pipCls valueForKey:@"shared"];
            if (pipMgr) {
                BOOL activeNow = NO;
                @try { activeNow = [[pipMgr valueForKey:@"isPiP"] boolValue]; } @catch (__unused NSException *e) {}
                if (activeNow) {
                    [pipMgr performSelector:NSSelectorFromString(@"stopPiP")];
                    if (completion) completion(NO, nil);
                    return;
                }
                Class dvcCls = NSClassFromString(@"DecoratedAppSceneViewController");
                UIViewController *activeDVC = nil;
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                        if (win.hidden || !win.rootViewController || !dvcCls) continue;
                        NSMutableArray<UIViewController *> *q = [NSMutableArray arrayWithObject:win.rootViewController];
                        while (q.count > 0) {
                            UIViewController *vc = q.firstObject;
                            [q removeObjectAtIndex:0];
                            if ([vc isKindOfClass:dvcCls] && !vc.view.hidden && vc.view.window) activeDVC = vc;
                            if (vc.presentedViewController) [q addObject:vc.presentedViewController];
                            [q addObjectsFromArray:vc.childViewControllers];
                        }
                    }
                }
                if (activeDVC) {
                    id appSceneVC = [activeDVC valueForKey:@"appSceneVC"];
                    if (appSceneVC && [pipMgr respondsToSelector:NSSelectorFromString(@"startPiPWithVC:")]) {
                        [pipMgr performSelector:NSSelectorFromString(@"startPiPWithVC:") withObject:appSceneVC];
                        if (completion) completion(YES, nil);
                        return;
                    }
                }
            }
        }
        // 多任务宿主模式下绝不回退截取宿主 LC 的 UIWindow！
        if (completion) completion(NO, @"未找到活跃的多任务子进程窗口");
        return;
    }

    if ([self isPiPActive]) {
        [self stopPiP];
        if (completion) completion(NO, nil);
        return;
    }

    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        if (completion) completion(NO, @"当前设备或容器不支持画中画");
        return;
    }

    UIWindow *targetWin = [self findPrimaryTargetWindow];
    if (!targetWin || !targetWin.rootViewController.view) {
        if (completion) completion(NO, @"未找到可投屏的应用窗口");
        return;
    }

    NSError *audioErr = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&audioErr];
    [[AVAudioSession sharedInstance] setActive:YES error:&audioErr];

    CGSize sourceSize = targetWin.bounds.size;
    if (sourceSize.width < 10 || sourceSize.height < 10) {
        sourceSize = CGSizeMake(320.0, 480.0);
    }

    AVPictureInPictureVideoCallViewController *vc = [[AVPictureInPictureVideoCallViewController alloc] init];
    vc.preferredContentSize = sourceSize;

    UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sourceSize.width, sourceSize.height)];
    wrapper.layer.anchorPoint = CGPointZero;
    wrapper.layer.position = CGPointZero;
    [vc.view addSubview:wrapper];

    AVPictureInPictureControllerContentSource *contentSource = [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:targetWin contentViewController:vc];
    AVPictureInPictureController *controller = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
    controller.canStartPictureInPictureAutomaticallyFromInline = YES;
    controller.delegate = self;
    SEL controlsSel = NSSelectorFromString(@"setControlsStyle:");
    if ([controller respondsToSelector:controlsSel]) {
        @try {
            [controller setValue:@(1) forKey:@"controlsStyle"];
        } @catch (__unused NSException *e) {}
    }

    self.sourceWindow = targetWin;
    self.videoCallVC = vc;
    self.wrapperView = wrapper;
    self.pipController = controller;

    [vc.view addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [controller startPictureInPicture];
        if (completion) completion(YES, nil);
    });
}

- (void)stopPiP {
    if (self.pipController && self.pipController.isPictureInPictureActive) {
        [self.pipController stopPictureInPicture];
    } else {
        [self cleanupAndRestore];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"bounds"] && object == self.videoCallVC.view && self.wrapperView) {
        CGRect rect = self.videoCallVC.view.bounds;
        if (rect.size.width > 1.0 && rect.size.height > 1.0) {
            CGFloat baseW = MAX(self.wrapperView.bounds.size.width, 1.0);
            CGFloat baseH = MAX(self.wrapperView.bounds.size.height, 1.0);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.wrapperView.transform = CGAffineTransformMakeScale(rect.size.width / baseW, rect.size.height / baseH);
            });
        }
    }
}

- (void)cleanupAndRestore {
    if (self.videoCallVC && self.videoCallVC.isViewLoaded) {
        @try {
            [self.videoCallVC.view removeObserver:self forKeyPath:@"bounds"];
        } @catch (__unused NSException *e) {}
    }

    UIWindow *win = self.sourceWindow;
    UIView *view = self.capturedView;
    if (win && view) {
        view.transform = self.savedTransform;
        view.autoresizingMask = self.savedAutoresizingMask;
        view.frame = win.bounds;
        [win addSubview:view];
    }

    self.wrapperView.transform = CGAffineTransformIdentity;
    self.wrapperView = nil;
    self.videoCallVC = nil;
    self.pipController = nil;
    self.capturedView = nil;
    self.sourceWindow = nil;

    if (self.onPiPStateChanged) {
        self.onPiPStateChanged(NO);
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = self.sourceWindow;
        UIView *contentView = win.rootViewController.view;
        if (!win || !contentView || !self.wrapperView || !self.videoCallVC) return;

        self.capturedView = contentView;
        self.savedFrame = contentView.frame;
        self.savedAutoresizingMask = contentView.autoresizingMask;
        self.savedTransform = contentView.transform;

        CGSize size = win.bounds.size;
        if (size.width < 10 || size.height < 10) size = CGSizeMake(320.0, 480.0);
        self.wrapperView.frame = CGRectMake(0, 0, size.width, size.height);
        contentView.transform = CGAffineTransformIdentity;
        contentView.frame = CGRectMake(0, 0, size.width, size.height);
        [self.wrapperView addSubview:contentView];
        self.videoCallVC.preferredContentSize = size;

        if (self.onPiPStateChanged) {
            self.onPiPStateChanged(YES);
        }
    });
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self cleanupAndRestore];
    });
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"[LCSwitcher] ❌ 画中画启动失败: %@", error.localizedDescription);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self cleanupAndRestore];
    });
}

@end

// MARK: - 单任务侧边抽屉面板视图 (LCSwitcherDrawerView)

@interface LCSwitcherDrawerView : UIView

@property (nonatomic, copy, nullable) void (^onSelectApp)(LCSwitcherAppInfo *app);
@property (nonatomic, copy, nullable) void (^onLongPressApp)(LCSwitcherAppInfo *app);
@property (nonatomic, copy, nullable) void (^onReturnHome)(void);
@property (nonatomic, copy, nullable) void (^onLongPressHome)(void);
@property (nonatomic, copy, nullable) void (^onToggleAutoRotate)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^onChangeScreenScale)(CGFloat scale);
@property (nonatomic, copy, nullable) void (^onTogglePiP)(void);
@property (nonatomic, copy, nullable) void (^onToggleTrueFullscreen)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onUserInteraction)(void);

- (void)reloadWithApps:(NSArray<LCSwitcherAppInfo *> *)apps runningFolder:(NSString *)runningFolder foregroundUUID:(nullable NSString *)foregroundUUID runningUUIDs:(nullable NSSet<NSString *> *)runningUUIDs;
- (void)setAutoRotateEnabled:(BOOL)enabled;
- (void)setAutoRotateRowHidden:(BOOL)hidden;
- (void)setScreenScale:(CGFloat)scale;
- (void)setPiPActive:(BOOL)active;
- (void)setTrueFullscreenActive:(BOOL)active;

@end

@implementation LCSwitcherDrawerView {
    UIVisualEffectView *_blurView;
    UIView *_headerView;
    UILabel *_titleLabel;
    UILabel *_countBadge;
    UIButton *_closeButton;
    UIView *_controlsPanel;
    UIStackView *_controlsStack;
    UIView *_scalePopoverBar;
    BOOL _isScalePopoverOpen;
    UIStackView *_bottomButtonsStack;
    UIButton *_homeActionButton;
    UIButton *_scaleActionButton;
    UILabel *_scaleActionTitleLabel;
    UIButton *_pipActionButton;
    UILabel *_pipActionTitleLabel;
    UIButton *_fullscreenActionButton;
    UILabel *_fullscreenActionTitleLabel;
    UIButton *_rotateActionButton;
    UILabel *_rotateActionTitleLabel;
    BOOL _isAutoRotateOn;
    UIButton *_scaleValueBadge;
    UISlider *_scaleSlider;
    UIScrollView *_scrollView;
    UIStackView *_stackView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingNone;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blurView];

    self.layer.cornerRadius = 20.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.6;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.45;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0, 4);

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.contentInset = UIEdgeInsetsMake(4.0, 0, 8.0, 0);
    [self addSubview:_scrollView];

    _stackView = [[UIStackView alloc] init];
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.spacing = 12.0;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.distribution = UIStackViewDistributionFill;
    [_scrollView addSubview:_stackView];

    [self setupControlsPanel];
    [self addSubview:_controlsPanel];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor constant:14.0],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_controlsPanel.topAnchor constant:-10.0],

        [_controlsPanel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_controlsPanel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
        [_controlsPanel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12.0],

        [_stackView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [_stackView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [_stackView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [_stackView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [_stackView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor]
    ]];
}

- (void)handleClose {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onClose) self.onClose();
}

- (void)handleReturnHome {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onReturnHome) self.onReturnHome();
}

- (UIButton *)createBottomActionButtonWithSymbol:(NSString *)symbolName
                                           title:(NSString *)title
                                           tint:(UIColor *)tintColor
                                      titleLabel:(UILabel * __strong *)outTitleLabel
                                          action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    btn.layer.cornerRadius = 12.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.layer.borderWidth = 0.5;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.userInteractionEnabled = NO;
    iv.tintColor = tintColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [btn addSubview:iv];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.userInteractionEnabled = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    lbl.textAlignment = NSTextAlignmentCenter;
    [btn addSubview:lbl];
    if (outTitleLabel) *outTitleLabel = lbl;

    [NSLayoutConstraint activateConstraints:@[
        [btn.heightAnchor constraintEqualToConstant:46.0],
        [iv.topAnchor constraintEqualToAnchor:btn.topAnchor constant:7.0],
        [iv.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [iv.widthAnchor constraintEqualToConstant:18.0],
        [iv.heightAnchor constraintEqualToConstant:18.0],
        [lbl.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:3.0],
        [lbl.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:2.0],
        [lbl.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-2.0]
    ]];
    return btn;
}

- (void)setupControlsPanel {
    _isScalePopoverOpen = NO;

    _controlsPanel = [[UIView alloc] init];
    _controlsPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlsPanel.backgroundColor = [UIColor clearColor];

    _controlsStack = [[UIStackView alloc] init];
    _controlsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _controlsStack.axis = UILayoutConstraintAxisVertical;
    _controlsStack.spacing = 8.0;
    _controlsStack.alignment = UIStackViewAlignmentFill;
    _controlsStack.distribution = UIStackViewDistributionFill;
    [_controlsPanel addSubview:_controlsStack];

    [NSLayoutConstraint activateConstraints:@[
        [_controlsStack.topAnchor constraintEqualToAnchor:_controlsPanel.topAnchor],
        [_controlsStack.leadingAnchor constraintEqualToAnchor:_controlsPanel.leadingAnchor],
        [_controlsStack.trailingAnchor constraintEqualToAnchor:_controlsPanel.trailingAnchor],
        [_controlsStack.bottomAnchor constraintEqualToAnchor:_controlsPanel.bottomAnchor]
    ]];

    // 1. 可展开缩放滑块条（默认隐藏，点击底部“缩放”按钮后展开）
    _scalePopoverBar = [[UIView alloc] init];
    _scalePopoverBar.translatesAutoresizingMaskIntoConstraints = NO;
    _scalePopoverBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.09];
    _scalePopoverBar.layer.cornerRadius = 13.0;
    _scalePopoverBar.layer.cornerCurve = kCACornerCurveContinuous;
    _scalePopoverBar.layer.borderWidth = 0.5;
    _scalePopoverBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    _scalePopoverBar.hidden = YES;
    _scalePopoverBar.alpha = 0.0;
    [_controlsStack addArrangedSubview:_scalePopoverBar];

    UILabel *minLbl = [[UILabel alloc] init];
    minLbl.translatesAutoresizingMaskIntoConstraints = NO;
    minLbl.text = @"50%";
    minLbl.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightMedium];
    minLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    [_scalePopoverBar addSubview:minLbl];

    _scaleSlider = [[UISlider alloc] init];
    _scaleSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _scaleSlider.minimumValue = 0.50f;
    _scaleSlider.maximumValue = 2.00f;
    _scaleSlider.value = 1.00f;
    _scaleSlider.continuous = YES;
    _scaleSlider.minimumTrackTintColor = [UIColor colorWithRed:0.55 green:0.62 blue:1.0 alpha:1.0];
    _scaleSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    [_scaleSlider addTarget:self action:@selector(handleScaleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_scaleSlider addTarget:self action:@selector(handleScaleSliderTouchEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_scalePopoverBar addSubview:_scaleSlider];

    _scaleValueBadge = [UIButton buttonWithType:UIButtonTypeSystem];
    _scaleValueBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [_scaleValueBadge setTitle:@"100%" forState:UIControlStateNormal];
    [_scaleValueBadge setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _scaleValueBadge.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _scaleValueBadge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    _scaleValueBadge.layer.cornerRadius = 7.0;
    _scaleValueBadge.layer.cornerCurve = kCACornerCurveContinuous;
    [_scaleValueBadge addTarget:self action:@selector(handleResetScaleTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scalePopoverBar addSubview:_scaleValueBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_scalePopoverBar.heightAnchor constraintEqualToConstant:40.0],
        [minLbl.leadingAnchor constraintEqualToAnchor:_scalePopoverBar.leadingAnchor constant:10.0],
        [minLbl.centerYAnchor constraintEqualToAnchor:_scalePopoverBar.centerYAnchor],
        [_scaleValueBadge.trailingAnchor constraintEqualToAnchor:_scalePopoverBar.trailingAnchor constant:-8.0],
        [_scaleValueBadge.centerYAnchor constraintEqualToAnchor:_scalePopoverBar.centerYAnchor],
        [_scaleValueBadge.widthAnchor constraintEqualToConstant:44.0],
        [_scaleValueBadge.heightAnchor constraintEqualToConstant:22.0],
        [_scaleSlider.leadingAnchor constraintEqualToAnchor:minLbl.trailingAnchor constant:6.0],
        [_scaleSlider.trailingAnchor constraintEqualToAnchor:_scaleValueBadge.leadingAnchor constant:-8.0],
        [_scaleSlider.centerYAnchor constraintEqualToAnchor:_scalePopoverBar.centerYAnchor]
    ]];

    // 2. 底部功能按钮栏（主页 · 缩放 · 画中画 · [单任务旋转]）
    _bottomButtonsStack = [[UIStackView alloc] init];
    _bottomButtonsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomButtonsStack.axis = UILayoutConstraintAxisHorizontal;
    _bottomButtonsStack.spacing = 6.0;
    _bottomButtonsStack.alignment = UIStackViewAlignmentFill;
    _bottomButtonsStack.distribution = UIStackViewDistributionFillEqually;
    [_controlsStack addArrangedSubview:_bottomButtonsStack];

    _homeActionButton = [self createBottomActionButtonWithSymbol:@"house.fill"
                                                           title:@"主页"
                                                           tint:[UIColor colorWithRed:0.45 green:0.78 blue:1.0 alpha:1.0]
                                                      titleLabel:nil
                                                          action:@selector(handleReturnHome)];
    UILongPressGestureRecognizer *homeLP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHomeLongPress:)];
    homeLP.minimumPressDuration = 0.5;
    [_homeActionButton addGestureRecognizer:homeLP];
    [_bottomButtonsStack addArrangedSubview:_homeActionButton];

    _scaleActionButton = [self createBottomActionButtonWithSymbol:@"arrow.up.left.and.arrow.down.right"
                                                            title:@"缩放"
                                                            tint:[UIColor colorWithRed:0.68 green:0.65 blue:1.0 alpha:1.0]
                                                       titleLabel:&_scaleActionTitleLabel
                                                           action:@selector(handleToggleScalePopover)];
    [_bottomButtonsStack addArrangedSubview:_scaleActionButton];

    _pipActionButton = [self createBottomActionButtonWithSymbol:@"pip.enter"
                                                          title:@"画中画"
                                                          tint:[UIColor colorWithRed:0.42 green:0.90 blue:0.92 alpha:1.0]
                                                     titleLabel:&_pipActionTitleLabel
                                                         action:@selector(handlePiPRowTapped)];
    [_bottomButtonsStack addArrangedSubview:_pipActionButton];

    _fullscreenActionButton = [self createBottomActionButtonWithSymbol:@"viewfinder"
                                                                 title:@"全屏"
                                                                 tint:[UIColor colorWithRed:1.0 green:0.76 blue:0.35 alpha:1.0]
                                                            titleLabel:&_fullscreenActionTitleLabel
                                                                action:@selector(handleTrueFullscreenTapped)];
    [_bottomButtonsStack addArrangedSubview:_fullscreenActionButton];

    _rotateActionButton = [self createBottomActionButtonWithSymbol:@"rotate.right.fill"
                                                             title:@"旋转"
                                                             tint:[UIColor colorWithRed:0.50 green:0.90 blue:0.62 alpha:1.0]
                                                        titleLabel:&_rotateActionTitleLabel
                                                            action:@selector(handleRotateButtonTapped)];
    [_bottomButtonsStack addArrangedSubview:_rotateActionButton];
}

- (void)handleToggleScalePopover {
    if (self.onUserInteraction) self.onUserInteraction();
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    _isScalePopoverOpen = !_isScalePopoverOpen;
    BOOL expand = _isScalePopoverOpen;
    if (expand) _scalePopoverBar.hidden = NO;
    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_scalePopoverBar.alpha = expand ? 1.0 : 0.0;
        self->_scaleActionButton.backgroundColor = expand ? [[UIColor systemIndigoColor] colorWithAlphaComponent:0.35] : [UIColor colorWithWhite:1.0 alpha:0.10];
        [self layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (!self->_isScalePopoverOpen) {
            self->_scalePopoverBar.hidden = YES;
        }
    }];
}

- (void)handleRotateButtonTapped {
    if (self.onUserInteraction) self.onUserInteraction();
    _isAutoRotateOn = !_isAutoRotateOn;
    [self setAutoRotateEnabled:_isAutoRotateOn];
    if (self.onToggleAutoRotate) {
        self.onToggleAutoRotate(_isAutoRotateOn);
    }
}

- (void)setAutoRotateEnabled:(BOOL)enabled {
    _isAutoRotateOn = enabled;
    _rotateActionButton.backgroundColor = enabled ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.32] : [UIColor colorWithWhite:1.0 alpha:0.10];
    _rotateActionButton.layer.borderColor = enabled ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.65].CGColor : [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    _rotateActionTitleLabel.text = enabled ? @"旋转中" : @"旋转";
}

- (void)setAutoRotateRowHidden:(BOOL)hidden {
    _rotateActionButton.hidden = hidden;
    _fullscreenActionButton.hidden = !hidden;
}

- (void)handleHomeLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onLongPressHome) self.onLongPressHome();
}

- (void)handleTrueFullscreenTapped {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onToggleTrueFullscreen) self.onToggleTrueFullscreen();
}

- (void)setTrueFullscreenActive:(BOOL)active {
    _fullscreenActionButton.backgroundColor = active ? [[UIColor systemOrangeColor] colorWithAlphaComponent:0.34] : [UIColor colorWithWhite:1.0 alpha:0.10];
    _fullscreenActionButton.layer.borderColor = active ? [[UIColor systemOrangeColor] colorWithAlphaComponent:0.70].CGColor : [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    _fullscreenActionTitleLabel.text = active ? @"退出全屏" : @"全屏";
}

- (void)handleScaleSliderChanged:(UISlider *)sender {
    if (self.onUserInteraction) self.onUserInteraction();
    CGFloat stepped = round((double)sender.value * 20.0) / 20.0;
    if (fabs(stepped - 1.0) < 0.03) stepped = 1.0;
    [self updateScaleBadge:stepped];
    if (self.onChangeScreenScale) {
        self.onChangeScreenScale(stepped);
    }
}

- (void)handleScaleSliderTouchEnded:(UISlider *)sender {
    CGFloat stepped = round((double)sender.value * 20.0) / 20.0;
    if (fabs(stepped - 1.0) < 0.03) stepped = 1.0;
    sender.value = (float)stepped;
    [self updateScaleBadge:stepped];
    if (self.onChangeScreenScale) {
        self.onChangeScreenScale(stepped);
    }
}

- (void)handleResetScaleTapped {
    if (self.onUserInteraction) self.onUserInteraction();
    _scaleSlider.value = 1.0f;
    [self updateScaleBadge:1.0];
    if (self.onChangeScreenScale) {
        self.onChangeScreenScale(1.0);
    }
}

- (void)setScreenScale:(CGFloat)scale {
    CGFloat clamped = MIN(MAX(scale, 0.5), 2.0);
    _scaleSlider.value = (float)clamped;
    [self updateScaleBadge:clamped];
}

- (void)updateScaleBadge:(CGFloat)scale {
    NSInteger pct = (NSInteger)llround(scale * 100.0);
    NSString *pctStr = [NSString stringWithFormat:@"%ld%%", (long)pct];
    [_scaleValueBadge setTitle:pctStr forState:UIControlStateNormal];
    BOOL isDefault = (pct == 100);
    _scaleActionTitleLabel.text = isDefault ? @"缩放" : pctStr;
    _scaleValueBadge.backgroundColor = isDefault ? [UIColor colorWithWhite:1.0 alpha:0.15] : [[UIColor systemIndigoColor] colorWithAlphaComponent:0.45];
}

- (void)handlePiPRowTapped {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onTogglePiP) self.onTogglePiP();
}

- (void)setPiPActive:(BOOL)active {
    _pipActionButton.backgroundColor = active ? [[UIColor systemTealColor] colorWithAlphaComponent:0.35] : [UIColor colorWithWhite:1.0 alpha:0.10];
    _pipActionButton.layer.borderColor = active ? [[UIColor systemTealColor] colorWithAlphaComponent:0.65].CGColor : [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    _pipActionTitleLabel.text = active ? @"退出画中画" : @"画中画";
}

static UIImage * _Nullable LCGrayscaleImage(UIImage * _Nullable image) {
    if (!image || !image.CGImage) return image;
    CGImageRef cgImg = image.CGImage;
    size_t w = CGImageGetWidth(cgImg);
    size_t h = CGImageGetHeight(cgImg);
    if (w == 0 || h == 0) return image;

    CGColorSpaceRef graySpace = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, graySpace, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(graySpace);
    if (!ctx) return image;

    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImg);
    CGImageRef grayCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!grayCG) return image;

    UIImage *result = [UIImage imageWithCGImage:grayCG scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(grayCG);
    return result;
}

- (void)reloadWithApps:(NSArray<LCSwitcherAppInfo *> *)apps runningFolder:(NSString *)runningFolder foregroundUUID:(nullable NSString *)foregroundUUID runningUUIDs:(nullable NSSet<NSString *> *)runningUUIDs {
    _countBadge.text = [NSString stringWithFormat:@" %lu ", (unsigned long)apps.count];

    for (UIView *sub in [_stackView.arrangedSubviews copy]) {
        [_stackView removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    const NSUInteger columns = 4;
    NSUInteger count = apps.count;
    for (NSUInteger i = 0; i < count; i += columns) {
        UIStackView *rowStack = [[UIStackView alloc] init];
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.spacing = 8.0;
        rowStack.alignment = UIStackViewAlignmentTop;
        rowStack.distribution = UIStackViewDistributionFillEqually;

        for (NSUInteger c = 0; c < columns; c++) {
            NSUInteger idx = i + c;
            if (idx < count) {
                LCSwitcherAppInfo *app = apps[idx];
                BOOL isForeground = NO;
                BOOL isRunning = NO;
                if (gIsMultitaskHostMode) {
                    isForeground = (foregroundUUID.length > 0 && app.dataUUID.length > 0 && [app.dataUUID isEqualToString:foregroundUUID]);
                    isRunning = isForeground || (app.dataUUID.length > 0 && [runningUUIDs containsObject:app.dataUUID]);
                } else {
                    isForeground = (runningFolder.length > 0 && [app.folderName isEqualToString:runningFolder]);
                    isRunning = isForeground;
                }
                UIView *tile = [self createAppTileWithApp:app isForeground:isForeground isRunning:isRunning];
                [rowStack addArrangedSubview:tile];
            } else {
                UIView *spacer = [[UIView alloc] init];
                spacer.userInteractionEnabled = NO;
                [rowStack addArrangedSubview:spacer];
            }
        }
        [_stackView addArrangedSubview:rowStack];
    }
}

- (UIView *)createAppTileWithApp:(LCSwitcherAppInfo *)app isForeground:(BOOL)isForeground isRunning:(BOOL)isRunning {
    UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = [UIColor clearColor];

    UIImage *rawIcon = app.icon ?: [UIImage systemImageNamed:@"app.fill"];
    UIImageView *iconView = [[UIImageView alloc] init];
    // 前台与后台运行中均为彩色图标；仅未运行的应用显示灰度图标
    iconView.image = isRunning ? rawIcon : (LCGrayscaleImage(rawIcon) ?: rawIcon);
    iconView.alpha = isRunning ? 1.0 : 0.68;
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 11.0;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.layer.borderWidth = isForeground ? 1.5 : 0.5;
    iconView.layer.borderColor = isForeground ? [UIColor systemGreenColor].CGColor : [UIColor colorWithWhite:1.0 alpha:(isRunning ? 0.28 : 0.14)].CGColor;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    [tile addSubview:iconView];

    if (isForeground) {
        UIView *greenDot = [[UIView alloc] init];
        greenDot.translatesAutoresizingMaskIntoConstraints = NO;
        greenDot.userInteractionEnabled = NO;
        greenDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.42 alpha:1.0];
        greenDot.layer.cornerRadius = 4.5;
        greenDot.layer.borderWidth = 1.4;
        greenDot.layer.borderColor = [UIColor colorWithWhite:0.08 alpha:0.9].CGColor;
        [tile addSubview:greenDot];

        [NSLayoutConstraint activateConstraints:@[
            [greenDot.topAnchor constraintEqualToAnchor:iconView.topAnchor constant:-2.0],
            [greenDot.trailingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:2.0],
            [greenDot.widthAnchor constraintEqualToConstant:9.0],
            [greenDot.heightAnchor constraintEqualToConstant:9.0]
        ]];
    }

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.userInteractionEnabled = NO;
    nameLabel.text = app.name;
    nameLabel.font = [UIFont systemFontOfSize:10.5 weight:(isForeground ? UIFontWeightSemibold : UIFontWeightRegular)];
    nameLabel.textColor = isRunning ? [UIColor colorWithWhite:1.0 alpha:(isForeground ? 1.0 : 0.88)] : [UIColor colorWithWhite:1.0 alpha:0.52];
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.numberOfLines = 1;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [tile addSubview:nameLabel];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor constant:2.0],
        [iconView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:44.0],
        [iconView.heightAnchor constraintEqualToConstant:44.0],

        [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:4.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:1.0],
        [nameLabel.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-1.0],
        [nameLabel.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-2.0]
    ]];

    objc_setAssociatedObject(tile, "LCAppInfoObject", app, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tile addTarget:self action:@selector(handleAppCardTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *tileLP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleAppCardLongPressed:)];
    tileLP.minimumPressDuration = 0.5;
    [tile addGestureRecognizer:tileLP];
    return tile;
}

- (void)handleAppCardTapped:(UIButton *)sender {
    if (self.onUserInteraction) self.onUserInteraction();
    LCSwitcherAppInfo *app = objc_getAssociatedObject(sender, "LCAppInfoObject");
    if (app && self.onSelectApp) {
        self.onSelectApp(app);
    }
}

- (void)handleAppCardLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.onUserInteraction) self.onUserInteraction();
    LCSwitcherAppInfo *app = objc_getAssociatedObject(gesture.view, "LCAppInfoObject");
    if (app && self.onLongPressApp) {
        self.onLongPressApp(app);
    }
}

- (UIView *)createAppRowWithApp:(LCSwitcherAppInfo *)app isRunning:(BOOL)isRunning {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = isRunning ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.22] : [UIColor colorWithWhite:1.0 alpha:0.09];
    card.layer.cornerRadius = 14.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = isRunning ? 1.0 : 0.5;
    card.layer.borderColor = isRunning ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.6].CGColor : [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = app.icon ?: [UIImage systemImageNamed:@"app.fill"];
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 10.0;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.layer.borderWidth = 0.5;
    iconView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconView];

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2.0;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = app.name;
    nameLabel.font = [UIFont systemFontOfSize:14.0 weight:(isRunning ? UIFontWeightBold : UIFontWeightMedium)];
    nameLabel.textColor = [UIColor whiteColor];
    nameLabel.numberOfLines = 1;

    UILabel *subLabel = [[UILabel alloc] init];
    NSString *ver = app.version.length ? [NSString stringWithFormat:@"v%@", app.version] : @"";
    subLabel.text = ver.length ? [NSString stringWithFormat:@"%@ • %@", ver, app.folderName] : app.folderName;
    subLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    subLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    subLabel.numberOfLines = 1;

    [textStack addArrangedSubview:nameLabel];
    [textStack addArrangedSubview:subLabel];
    [card addSubview:textStack];

    UIView *trailingView;
    if (isRunning) {
        UILabel *tag = [[UILabel alloc] init];
        tag.text = @"● 运行中";
        tag.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        tag.textColor = [UIColor systemGreenColor];
        tag.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.25];
        tag.layer.cornerRadius = 9.0;
        tag.layer.cornerCurve = kCACornerCurveContinuous;
        tag.clipsToBounds = YES;
        tag.textAlignment = NSTextAlignmentCenter;
        tag.translatesAutoresizingMaskIntoConstraints = NO;
        trailingView = tag;
        [NSLayoutConstraint activateConstraints:@[
            [tag.widthAnchor constraintEqualToConstant:62.0],
            [tag.heightAnchor constraintEqualToConstant:20.0]
        ]];
    } else {
        UIImageView *switchIcon = [[UIImageView alloc] init];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightMedium];
        switchIcon.image = [UIImage systemImageNamed:@"arrow.right.circle" withConfiguration:cfg];
        switchIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.4];
        switchIcon.contentMode = UIViewContentModeScaleAspectFit;
        switchIcon.translatesAutoresizingMaskIntoConstraints = NO;
        trailingView = switchIcon;
        [NSLayoutConstraint activateConstraints:@[
            [switchIcon.widthAnchor constraintEqualToConstant:18.0],
            [switchIcon.heightAnchor constraintEqualToConstant:18.0]
        ]];
    }
    [card addSubview:trailingView];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:54.0],

        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:38.0],
        [iconView.heightAnchor constraintEqualToConstant:38.0],

        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10.0],
        [textStack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:trailingView.leadingAnchor constant:-8.0],

        [trailingView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [trailingView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]
    ]];

    __weak typeof(self) weakSelf = self;
    UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull act) {
        if (weakSelf.onUserInteraction) weakSelf.onUserInteraction();
        if (weakSelf.onSelectApp) weakSelf.onSelectApp(app);
    }];
    [card addAction:action forControlEvents:UIControlEventTouchUpInside];

    return card;
}

@end

// MARK: - 单任务透明穿透悬浮窗口 (LCSwitcherOverlayWindow)

@interface LCSwitcherOverlayController : UIViewController

@property (nonatomic, strong) LCSwitcherBeadView *beadView;
@property (nonatomic, strong) LCSwitcherDrawerView *drawerView;
@property (nonatomic, strong) UIView *dimmingMaskView;
@property (nonatomic, strong) LCSwitcherHandoffView *transitionOverlayView;

@property (nonatomic, assign) BOOL isDrawerOpen;
@property (nonatomic, assign) BOOL isBeadPinnedRight;
@property (nonatomic, assign) CGFloat beadCenterYRatio;

- (UIView *)resolveHitTestAtPoint:(CGPoint)point inWindow:(UIWindow *)window withEvent:(UIEvent *)event;
- (void)setDrawerOpen:(BOOL)open animated:(BOOL)animated;
- (void)resetInactivityTimer;
- (void)updateLayoutForCanvasSize:(CGSize)size;

@end

@interface LCSwitcherOverlayWindow : UIWindow
@property (nonatomic, weak) LCSwitcherOverlayController *overlayController;
@end

@implementation LCSwitcherOverlayWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    self = [super initWithWindowScene:windowScene];
    if (self) {
        self.accessibilityIdentifier = @"LCSwitcherOverlayWindow";
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.overlayController) return nil;
    return [self.overlayController resolveHitTestAtPoint:point inWindow:self withEvent:event];
}

@end

// MARK: - 单任务悬浮窗口根控制器实现 (LCSwitcherOverlayController)

@implementation LCSwitcherOverlayController {
    NSTimer *_inactivityTimer;
    CGFloat _beadSize;
    CGFloat _drawerWidth;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    _beadSize = 44.0;
    _drawerWidth = 280.0;
    _beadCenterYRatio = 0.45;
    _isBeadPinnedRight = YES;

    [self setupComponents];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateLayoutForCanvasSize:self.view.bounds.size];
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        [weakSelf updateLayoutForCanvasSize:size];
    } completion:nil];
}

- (UIView *)resolveHitTestAtPoint:(CGPoint)point inWindow:(UIWindow *)window withEvent:(UIEvent *)event {
    if (self.transitionOverlayView.alpha > 0.05) {
        CGPoint p = [self.transitionOverlayView convertPoint:point fromView:window];
        return [self.transitionOverlayView hitTest:p withEvent:event];
    }

    CGPoint viewPoint = [self.view convertPoint:point fromView:window];
    if (self.isDrawerOpen) {
        if (CGRectContainsPoint(self.drawerView.frame, viewPoint)) {
            CGPoint p = [self.drawerView convertPoint:point fromView:window];
            return [self.drawerView hitTest:p withEvent:event];
        }
        if (CGRectContainsPoint(self.dimmingMaskView.frame, viewPoint)) {
            return self.dimmingMaskView;
        }
    }

    CGRect beadHitFrame = CGRectInset(self.beadView.frame, -24.0, -16.0);
    if (CGRectContainsPoint(beadHitFrame, viewPoint)) {
        CGPoint p = [self.beadView convertPoint:point fromView:window];
        return [self.beadView hitTest:p withEvent:event] ?: self.beadView;
    }

    // 透传给沙盒客态界面
    return nil;
}

- (void)setupComponents {
    // 1. 半透明遮罩（点击或滑动外部任意位置自动关闭侧边栏）
    self.dimmingMaskView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimmingMaskView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimmingMaskView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    self.dimmingMaskView.alpha = 0.0;
    UITapGestureRecognizer *maskTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMaskTap)];
    [self.dimmingMaskView addGestureRecognizer:maskTap];
    UIPanGestureRecognizer *maskPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMaskPan:)];
    [self.dimmingMaskView addGestureRecognizer:maskPan];
    [self.view addSubview:self.dimmingMaskView];

    // 2. 侧边抽屉面板
    self.drawerView = [[LCSwitcherDrawerView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    self.drawerView.onClose = ^{
        [weakSelf setDrawerOpen:NO animated:YES];
    };
    self.drawerView.onReturnHome = ^{
        [weakSelf setDrawerOpen:NO animated:YES];
        [LCSwitcher presentTransitionAndReturnHomeWithCompletion:nil];
    };
    self.drawerView.onLongPressHome = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback impactOccurred];
        [weakSelf setDrawerOpen:NO animated:YES];
        [weakSelf closeAllMultitaskProcesses];
    };
    self.drawerView.onToggleTrueFullscreen = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        BOOL active = [weakSelf toggleActiveMultitaskTrueFullscreen];
        [weakSelf.drawerView setTrueFullscreenActive:active];
    };
    self.drawerView.onLongPressApp = ^(LCSwitcherAppInfo *app) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback impactOccurred];
        [weakSelf closeMultitaskProcessForApp:app];
    };
    self.drawerView.onToggleAutoRotate = ^(BOOL enabled) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        NSString *runningFolder = [LCSwitcher currentGuestFolderName];
        LCSaveForceAutoRotateForFolder(runningFolder, enabled);
        LCInstallOrientationHooksIfNeeded();
        LCRefreshInterfaceOrientationsNow();
    };
    self.drawerView.onChangeScreenScale = ^(CGFloat scale) {
        NSString *runningFolder = [LCSwitcher currentGuestFolderName];
        LCSaveScreenScaleForFolder(runningFolder, scale);
        LCApplyScreenScaleNow();
    };
    self.drawerView.onTogglePiP = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        [weakSelf setDrawerOpen:NO animated:YES];
        [[LCPictureInPictureManager sharedManager] togglePiPWithCompletion:^(BOOL active, NSString * _Nullable errorMessage) {
            [weakSelf.drawerView setPiPActive:active];
            if (errorMessage.length) {
                NSLog(@"[LCSwitcher] ⚠️ %@", errorMessage);
            }
        }];
    };
    [LCPictureInPictureManager sharedManager].onPiPStateChanged = ^(BOOL active) {
        [weakSelf.drawerView setPiPActive:active];
    };
    self.drawerView.onSelectApp = ^(LCSwitcherAppInfo *app) {
        [weakSelf handleAppSelected:app];
    };
    self.drawerView.onUserInteraction = ^{
        [weakSelf resetInactivityTimer];
    };
    [self.view addSubview:self.drawerView];

    // 3. 贴边悬浮微珠（胶囊微珠形状，支持点击与向内侧滑呼出抽屉）
    self.beadView = [[LCSwitcherBeadView alloc] initWithFrame:CGRectMake(0, 0, 16.0, 54.0)];
    self.beadView.onTap = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        [weakSelf setDrawerOpen:!weakSelf.isDrawerOpen animated:YES];
    };
    self.beadView.onSwipeToOpen = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        [weakSelf setDrawerOpen:YES animated:YES];
    };
    self.beadView.onPanMoved = ^(CGPoint center) {
        [weakSelf resetInactivityTimer];
    };
    self.beadView.onPanEnded = ^(CGPoint center) {
        [weakSelf handleBeadPanEnded:center];
    };
    self.beadView.onUserInteraction = ^{
        [weakSelf resetInactivityTimer];
    };
    [self.view addSubview:self.beadView];

    // 4. 全屏平滑过渡交接遮罩
    self.transitionOverlayView = [[LCSwitcherHandoffView alloc] initWithFrame:self.view.bounds];
    self.transitionOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.transitionOverlayView];

    [self loadSavedBeadPosition];
    CGSize canvasSize = (self.view.bounds.size.width > 0 && self.view.bounds.size.height > 0) ? self.view.bounds.size : [UIScreen mainScreen].bounds.size;
    [self updateLayoutForCanvasSize:canvasSize];
    [self resetInactivityTimer];
}

- (void)loadSavedBeadPosition {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    double savedRatio = [ud doubleForKey:@"LCSwitcher_BeadCenterYRatio"];
    if (savedRatio > 0.1 && savedRatio < 0.9) {
        _beadCenterYRatio = (CGFloat)savedRatio;
    }
    if ([ud objectForKey:@"LCSwitcher_BeadPinnedRight"]) {
        _isBeadPinnedRight = [ud boolForKey:@"LCSwitcher_BeadPinnedRight"];
    }
}

- (void)saveBeadPosition {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:(double)_beadCenterYRatio forKey:@"LCSwitcher_BeadCenterYRatio"];
    [ud setBool:_isBeadPinnedRight forKey:@"LCSwitcher_BeadPinnedRight"];
    [ud synchronize];
}

- (void)updateLayoutForCanvasSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;

    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat safeTop = insets.top > 0 ? insets.top : 44.0;
    CGFloat safeBottom = insets.bottom > 0 ? insets.bottom : 34.0;
    CGFloat beadW = 16.0;
    CGFloat beadH = 54.0;
    CGFloat usableHeight = MAX(size.height - safeTop - safeBottom - beadH, 100.0);

    CGFloat targetY = safeTop + usableHeight * _beadCenterYRatio;
    CGFloat targetX = _isBeadPinnedRight ? (size.width - beadW + 2.0) : -2.0;

    self.beadView.isPinnedRight = _isBeadPinnedRight;
    self.beadView.frame = CGRectMake(targetX, targetY, beadW, beadH);

    CGFloat maxDrawerH = MAX(size.height - safeTop - safeBottom - 32.0, 220.0);
    CGFloat drawerH = MIN(360.0, maxDrawerH);
    CGFloat drawerY = safeTop + (size.height - safeTop - safeBottom - drawerH) / 2.0;
    CGFloat drawerActualW = MIN(296.0, size.width - 32.0);

    if (self.isDrawerOpen) {
        CGFloat drawerX = _isBeadPinnedRight ? (size.width - drawerActualW - 8.0) : 8.0;
        self.drawerView.frame = CGRectMake(drawerX, drawerY, drawerActualW, drawerH);
    } else {
        CGFloat drawerHiddenX = _isBeadPinnedRight ? (size.width + 20.0) : (-drawerActualW - 20.0);
        self.drawerView.frame = CGRectMake(drawerHiddenX, drawerY, drawerActualW, drawerH);
    }
}

- (void)handleBeadPanEnded:(CGPoint)center {
    CGSize size = self.view.bounds.size;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat safeTop = insets.top > 0 ? insets.top : 44.0;
    CGFloat safeBottom = insets.bottom > 0 ? insets.bottom : 34.0;
    CGFloat beadW = 16.0;
    CGFloat beadH = 54.0;
    CGFloat usableHeight = MAX(size.height - safeTop - safeBottom - beadH, 100.0);

    CGFloat clampedY = MIN(MAX(center.y, safeTop + beadH / 2.0), size.height - safeBottom - beadH / 2.0);
    _beadCenterYRatio = (clampedY - safeTop) / usableHeight;

    _isBeadPinnedRight = (center.x >= size.width / 2.0);
    self.beadView.isPinnedRight = _isBeadPinnedRight;
    [self saveBeadPosition];

    CGFloat targetX = _isBeadPinnedRight ? (size.width - beadW + 2.0) : -2.0;
    CGFloat targetY = clampedY - beadH / 2.0;

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:0 animations:^{
        weakSelf.beadView.frame = CGRectMake(targetX, targetY, beadW, beadH);
    } completion:^(BOOL finished) {
        [weakSelf resetInactivityTimer];
    }];
}

- (void)handleMaskTap {
    [self setDrawerOpen:NO animated:YES];
}

- (void)handleMaskPan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self setDrawerOpen:NO animated:YES];
    }
}

- (void)setDrawerOpen:(BOOL)open animated:(BOOL)animated {
    if (_isDrawerOpen == open) return;
    _isDrawerOpen = open;
    [self resetInactivityTimer];

    if (open) {
        [self refreshAppList];
    }

    CGSize size = self.view.bounds.size;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat safeTop = insets.top > 0 ? insets.top : 44.0;
    CGFloat safeBottom = insets.bottom > 0 ? insets.bottom : 34.0;
    CGFloat maxDrawerH = MAX(size.height - safeTop - safeBottom - 32.0, 220.0);
    CGFloat drawerH = MIN(360.0, maxDrawerH);
    CGFloat drawerY = safeTop + (size.height - safeTop - safeBottom - drawerH) / 2.0;
    CGFloat drawerActualW = MIN(296.0, size.width - 32.0);

    CGFloat targetX = open
        ? (_isBeadPinnedRight ? (size.width - drawerActualW - 8.0) : 8.0)
        : (_isBeadPinnedRight ? (size.width + 20.0) : (-drawerActualW - 20.0));

    if (open) {
        self.drawerView.frame = CGRectMake(
            _isBeadPinnedRight ? (size.width + 20.0) : (-drawerActualW - 20.0),
            drawerY,
            drawerActualW,
            drawerH
        );
    }

    NSTimeInterval duration = animated ? 0.28 : 0.0;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.6 options:0 animations:^{
        weakSelf.dimmingMaskView.alpha = open ? 1.0 : 0.0;
        weakSelf.drawerView.frame = CGRectMake(targetX, drawerY, drawerActualW, drawerH);
        weakSelf.beadView.alpha = open ? 0.0 : 1.0;
    } completion:^(BOOL finished) {
        if (!open) {
            [weakSelf resetInactivityTimer];
        }
    }];
}

- (void)refreshAppList {
    NSArray<LCSwitcherAppInfo *> *apps = [LCSwitcher scanInstalledApps];
    NSString *runningFolder = [LCSwitcher currentGuestFolderName];
    NSString *foregroundUUID = nil;
    NSMutableSet<NSString *> *runningUUIDs = [NSMutableSet set];
    if (gIsMultitaskHostMode) {
        UIViewController *topDVC = [self topmostVisibleDecoratedSceneVC];
        if (topDVC) {
            @try {
                foregroundUUID = [topDVC valueForKey:@"dataUUID"];
            } @catch (__unused NSException *e) {}
        }
        Class mmCls = LCFindHostClass(@"MultitaskManager");
        SEL isUsingSel = NSSelectorFromString(@"isUsingWithContainer:");
        for (UIViewController *vc in [self allActiveDecoratedSceneVCs]) {
            @try {
                NSString *uuid = [vc valueForKey:@"dataUUID"];
                if (!uuid.length) continue;
                BOOL usingNow = YES;
                if (mmCls && [mmCls respondsToSelector:isUsingSel]) {
                    usingNow = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(mmCls, isUsingSel, uuid);
                }
                if (usingNow) {
                    [runningUUIDs addObject:uuid];
                }
            } @catch (__unused NSException *e) {}
        }
    }
    [self.drawerView setAutoRotateRowHidden:gIsMultitaskHostMode];
    [self.drawerView setAutoRotateEnabled:LCLoadForceAutoRotateForFolder(runningFolder)];
    [self.drawerView setScreenScale:LCLoadScreenScaleForFolder(runningFolder)];
    [self.drawerView setPiPActive:[[LCPictureInPictureManager sharedManager] isPiPActive]];
    [self.drawerView setTrueFullscreenActive:[self isActiveMultitaskTrueFullscreen]];
    [self.drawerView reloadWithApps:apps runningFolder:runningFolder foregroundUUID:foregroundUUID runningUUIDs:runningUUIDs];
}

- (NSArray<UIViewController *> *)allActiveDecoratedSceneVCs {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    Class dvcCls = LCFindHostClass(@"DecoratedAppSceneViewController");
    if (!dvcCls) return result;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (!win.rootViewController) continue;
            NSMutableArray<UIViewController *> *q = [NSMutableArray arrayWithObject:win.rootViewController];
            while (q.count > 0) {
                UIViewController *vc = q.firstObject;
                [q removeObjectAtIndex:0];
                if ([vc isKindOfClass:dvcCls] && vc.view.superview != nil && vc.view.window != nil) {
                    [result addObject:vc];
                }
                if (vc.presentedViewController) [q addObject:vc.presentedViewController];
                [q addObjectsFromArray:vc.childViewControllers];
            }
        }
    }
    return result;
}

- (nullable UIViewController *)topmostVisibleDecoratedSceneVC {
    Class dvcCls = LCFindHostClass(@"DecoratedAppSceneViewController");
    Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
    if (dockMgrCls && [dockMgrCls respondsToSelector:@selector(shared)]) {
        id dockMgr = [dockMgrCls valueForKey:@"shared"];
        @try {
            UIView *hostView = [dockMgr valueForKey:@"windowHostingView"];
            for (UIView *sub in [hostView.subviews reverseObjectEnumerator]) {
                if (sub.hidden || sub.alpha < 0.1) continue;
                UIResponder *r = sub.nextResponder;
                if ([r isKindOfClass:[UIViewController class]] && (!dvcCls || [r isKindOfClass:dvcCls])) {
                    return (UIViewController *)r;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    for (UIViewController *vc in [[self allActiveDecoratedSceneVCs] reverseObjectEnumerator]) {
        if (!vc.view.hidden && vc.view.alpha > 0.1) return vc;
    }
    return nil;
}

- (void)closeAllMultitaskProcesses {
    if (!gIsMultitaskHostMode) {
        [LCSwitcher presentTransitionAndReturnHomeWithCompletion:nil];
        return;
    }
    SEL closeSel = NSSelectorFromString(@"closeWindow");
    for (UIViewController *vc in [self allActiveDecoratedSceneVCs]) {
        if ([vc respondsToSelector:closeSel]) {
            [vc performSelector:closeSel];
        }
    }
}

- (void)closeMultitaskProcessForApp:(LCSwitcherAppInfo *)app {
    if (!gIsMultitaskHostMode || !app) return;
    NSString *targetUUID = app.dataUUID ?: @"";
    if (!targetUUID.length) {
        NSString *docs = [LCSwitcher realHostDocumentsDirectory];
        NSString *plistPath = [[docs stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:[app.folderName stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        targetUUID = info[@"LCDataUUID"] ?: @"";
    }
    SEL closeSel = NSSelectorFromString(@"closeWindow");
    for (UIViewController *vc in [self allActiveDecoratedSceneVCs]) {
        @try {
            NSString *uuid = [vc valueForKey:@"dataUUID"];
            if (targetUUID.length && [uuid isEqualToString:targetUUID]) {
                if ([vc respondsToSelector:closeSel]) {
                    [vc performSelector:closeSel];
                }
                break;
            }
        } @catch (__unused NSException *e) {}
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refreshAppList];
    });
}

- (BOOL)isActiveMultitaskTrueFullscreen {
    if (!gIsMultitaskHostMode) return NO;
    Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
    if (dockMgrCls && [dockMgrCls respondsToSelector:@selector(shared)]) {
        id dockMgr = [dockMgrCls valueForKey:@"shared"];
        @try {
            return [[dockMgr valueForKey:@"isCollapsed"] boolValue];
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

- (BOOL)toggleActiveMultitaskTrueFullscreen {
    if (!gIsMultitaskHostMode) return NO;
    Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
    if (!dockMgrCls || ![dockMgrCls respondsToSelector:@selector(shared)]) return NO;
    id dockMgr = [dockMgrCls valueForKey:@"shared"];
    if (!dockMgr) return NO;

    BOOL wasCollapsed = NO;
    @try {
        wasCollapsed = [[dockMgr valueForKey:@"isCollapsed"] boolValue];
    } @catch (__unused NSException *e) {}

    BOOL targetCollapsed = !wasCollapsed;
    NSArray<UIViewController *> *allDVCs = [self allActiveDecoratedSceneVCs];
    if (targetCollapsed) {
        // 对所有已启动子进程统一最大化，确保 LC 在 isCollapsed && isMaximized 下对全部子进程隐藏顶栏并铺满全屏
        for (UIViewController *dvc in allDVCs) {
            @try {
                BOOL isMax = [[dvc valueForKey:@"isMaximized"] boolValue];
                if (!isMax && [dvc respondsToSelector:NSSelectorFromString(@"maximizeWindow")]) {
                    [dvc performSelector:NSSelectorFromString(@"maximizeWindow")];
                }
            } @catch (__unused NSException *e) {}
        }
    }

    SEL toggleSel = NSSelectorFromString(@"toggleDockCollapse");
    if ([dockMgr respondsToSelector:toggleSel]) {
        [dockMgr performSelector:toggleSel];
        // 确保原版 Dock 在 updateDockFrame 后仍保持隐藏，并同步刷新所有子进程约束
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCHideLCMultitaskDockWindow(dockMgr);
            SEL updateVertSel = NSSelectorFromString(@"updateVerticalConstraints");
            for (UIViewController *dvc in [self allActiveDecoratedSceneVCs]) {
                if ([dvc respondsToSelector:updateVertSel]) {
                    [dvc performSelector:updateVertSel];
                }
            }
        });
    }
    return targetCollapsed;
}

- (void)handleAppSelected:(LCSwitcherAppInfo *)app {
    if (!gIsMultitaskHostMode) {
        NSString *runningFolder = [LCSwitcher currentGuestFolderName];
        if (runningFolder.length && [app.folderName isEqualToString:runningFolder]) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
            [self setDrawerOpen:NO animated:YES];
            return;
        }
    }

    [self setDrawerOpen:NO animated:YES];
    [LCSwitcher presentTransitionAndSwitchToApp:app completion:nil];
}

- (void)resetInactivityTimer {
    [_inactivityTimer invalidate];
    _inactivityTimer = nil;

    if (!self.isDrawerOpen) {
        [UIView animateWithDuration:0.2 animations:^{
            self.beadView.alpha = 1.0;
        }];
    }

    __weak typeof(self) weakSelf = self;
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        if (!weakSelf || weakSelf.isDrawerOpen) return;
        [UIView animateWithDuration:0.35 animations:^{
            weakSelf.beadView.alpha = 0.22;
        }];
    }];
}

@end

// MARK: - 宿主窗口直挂透传容器视图 (多任务宿主模式专用，绝不新建 UIWindow 抢占 keyWindow / rootVC)

@interface LCSwitcherPassthroughView : UIView
@property (nonatomic, weak, nullable) LCSwitcherOverlayController *overlayController;
@end

@implementation LCSwitcherPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.window || !self.overlayController) return nil;
    CGPoint winPoint = [self convertPoint:point toView:self.window];
    return [self.overlayController resolveHitTestAtPoint:winPoint inWindow:self.window withEvent:event];
}

@end

// MARK: - LCSwitcher 核心中枢实现

@interface LCSwitcher ()
@property (nonatomic, strong, nullable) LCSwitcherOverlayWindow *overlayWindow;
@property (nonatomic, strong, nullable) LCSwitcherPassthroughView *hostOverlayView;
@property (nonatomic, strong) LCSwitcherOverlayController *overlayController;
@property (nonatomic, assign) BOOL isSetup;
@end

@implementation LCSwitcher

+ (instancetype)sharedManager {
    static LCSwitcher *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[LCSwitcher alloc] init];
    });
    return s_instance;
}

// MARK: - 生命周期安装与门禁检查

+ (void)setupIfNeeded {
    // 门禁 1：绝不在多任务子进程扩展 (.appex) 中运行
    if (LCIsMultitaskExtensionProcess()) return;

    // 门禁 2：必须在沙盒客态运行环境下，或宿主多任务模式接管下
    if (![self isContainerGuestRunning] && !gIsMultitaskHostMode) return;

    // 门禁 3：遵循用户单任务快捷切换开关设置 (默认开启)
    id enabledVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"GnoixContainer_SingleTaskQuickSwitcher"];
    if (enabledVal && ![enabledVal boolValue]) return;

    // 仅在单任务模式下安装旋转/窗口缩放 Hook（多任务宿主模式绝不干涉 LC 自身窗口与方向）
    if (!gIsMultitaskHostMode) {
        NSString *runningFolder = [self currentGuestFolderName];
        gForceAutoRotateEnabled = LCLoadForceAutoRotateForFolder(runningFolder);
        LCInstallOrientationHooksIfNeeded();
        if (gForceAutoRotateEnabled) {
            LCRefreshInterfaceOrientationsNow();
        }

        gScreenScale = LCLoadScreenScaleForFolder(runningFolder);
        LCInstallScaleHooksIfNeeded();
        if (fabs(gScreenScale - 1.0) >= 0.01) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LCApplyScreenScaleNow();
            });
        }
    }

    // 宿主多任务模式下立即挂载，单任务模式下延时 1.2 秒确保客态主窗口挂载完毕
    if (gIsMultitaskHostMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self sharedManager] performSetup];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[self sharedManager] performSetup];
        });
    }
}

- (void)performSetup {
    if (self.isSetup) {
        [self ensureWindowAttached];
        return;
    }

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
            if (!scene) {
                scene = (UIWindowScene *)s;
            }
        }
    }

    if (!scene) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf performSetup];
        });
        return;
    }

    // 多任务宿主模式：直接作为 subview 挂载在宿主 keyWindow 顶层，绝不新建 UIWindow，避免干扰 LC 的 rootVC / launchMultitaskGuestApp
    if (gIsMultitaskHostMode) {
        UIWindow *hostWin = nil;
        for (UIWindow *w in scene.windows) {
            if (w.hidden || !w.rootViewController) continue;
            if (w.isKeyWindow) { hostWin = w; break; }
            if (!hostWin) hostWin = w;
        }
        if (!hostWin) return;

        LCSwitcherOverlayController *controller = [[LCSwitcherOverlayController alloc] init];
        LCSwitcherPassthroughView *container = [[LCSwitcherPassthroughView alloc] initWithFrame:hostWin.bounds];
        container.backgroundColor = [UIColor clearColor];
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.overlayController = controller;

        controller.view.frame = container.bounds;
        controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:controller.view];
        [hostWin addSubview:container];
        [hostWin bringSubviewToFront:container];

        self.hostOverlayView = container;
        self.overlayController = controller;
        self.isSetup = YES;
        return;
    }

    LCSwitcherOverlayWindow *window = [[LCSwitcherOverlayWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelStatusBar + 120.0;
    window.backgroundColor = [UIColor clearColor];

    LCSwitcherOverlayController *controller = [[LCSwitcherOverlayController alloc] init];
    window.overlayController = controller;
    window.rootViewController = controller;
    window.hidden = NO;

    self.overlayWindow = window;
    self.overlayController = controller;
    self.isSetup = YES;

    NSLog(@"[LCSwitcher] ⚡ 单任务侧边快速切换微珠已就绪挂载 (Scene: %@)", scene);
}

- (void)ensureWindowAttached {
    if (self.hostOverlayView) {
        self.hostOverlayView.hidden = NO;
        if (self.hostOverlayView.superview) {
            self.hostOverlayView.frame = self.hostOverlayView.superview.bounds;
            [self.hostOverlayView.superview bringSubviewToFront:self.hostOverlayView];
        }
        return;
    }
    if (!self.overlayWindow) return;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            if (self.overlayWindow.windowScene != s) {
                self.overlayWindow.windowScene = (UIWindowScene *)s;
            }
            break;
        }
    }
    self.overlayWindow.hidden = NO;
}

// MARK: - 扫描已安装沙盒应用

+ (NSArray<LCSwitcherAppInfo *> *)scanInstalledApps {
    NSString *docs = [self realHostDocumentsDirectory];
    if (!docs.length) return @[];

    NSString *appsDir = [docs stringByAppendingPathComponent:@"Applications"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    if (!items.count) return @[];

    NSMutableArray<LCSwitcherAppInfo *> *results = [NSMutableArray array];

    for (NSString *item in items) {
        NSString *fullPath = [appsDir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) {
            continue;
        }
        if (![item hasSuffix:@".app"]) {
            continue;
        }

        NSString *infoPlistPath = [fullPath stringByAppendingPathComponent:@"Info.plist"];
        NSString *lcAppInfoPath = [fullPath stringByAppendingPathComponent:@"LCAppInfo.plist"];
        if (![fm fileExistsAtPath:infoPlistPath]) continue;

        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath] ?: @{};
        NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:lcAppInfoPath] ?: @{};

        NSString *name = plist[@"CFBundleDisplayName"] ?: plist[@"CFBundleName"] ?: [item stringByReplacingOccurrencesOfString:@".app" withString:@""];
        NSString *bundleId = plist[@"CFBundleIdentifier"] ?: @"";
        NSString *version = plist[@"CFBundleShortVersionString"] ?: @"";
        NSString *dataUUID = lcInfo[@"LCDataUUID"] ?: @"";
        BOOL isJIT = [lcInfo[@"isJITNeeded"] boolValue] || [lcInfo[@"isJITEnabled"] boolValue];

        UIImage *icon = [self extractAppIconFromAppPath:fullPath plist:plist];

        LCSwitcherAppInfo *info = [[LCSwitcherAppInfo alloc] initWithName:name
                                                                   folderName:item
                                                                     bundleId:bundleId
                                                                      version:version
                                                                     dataUUID:dataUUID
                                                                      appPath:fullPath
                                                                         icon:icon
                                                                 isJITEnabled:isJIT];
        [results addObject:info];
    }

    [results sortUsingComparator:^NSComparisonResult(LCSwitcherAppInfo *obj1, LCSwitcherAppInfo *obj2) {
        return [obj1.name localizedStandardCompare:obj2.name];
    }];

    return results;
}

+ (nullable UIImage *)extractAppIconFromAppPath:(NSString *)appPath plist:(NSDictionary *)plist {
    if (!appPath.length) return nil;

    static NSCache<NSString *, UIImage *> *s_tweakIconCache = nil;
    static dispatch_once_t cacheOnce;
    dispatch_once(&cacheOnce, ^{
        s_tweakIconCache = [[NSCache alloc] init];
        s_tweakIconCache.countLimit = 256;
    });

    UIImage *cached = [s_tweakIconCache objectForKey:appPath];
    if (cached) return cached;

    NSURL *bundleURL = [NSURL fileURLWithPath:appPath];

    // 阶段 0: 优先委托宿主引擎 LCMachOHelper (若当前进程已载入 Gnoix 底层)
    Class machOHelper = NSClassFromString(@"LCMachOHelper");
    SEL helperSel = NSSelectorFromString(@"extractAppIconForBundleURL:");
    if (machOHelper && [machOHelper respondsToSelector:helperSel]) {
        @try {
            typedef UIImage * (*HelperFunc)(id, SEL, NSURL *);
            Method m = class_getClassMethod(machOHelper, helperSel);
            if (m) {
                HelperFunc fn = (HelperFunc)method_getImplementation(m);
                UIImage *icon = fn(machOHelper, helperSel, bundleURL);
                if (icon && icon.size.width > 0) {
                    [s_tweakIconCache setObject:icon forKey:appPath];
                    return icon;
                }
            }
        } @catch (NSException *e) {}
    }

    // 阶段 1: 尝试 LiveContainer 原生 +[UIImage(LiveContainer) generateIconForBundleURL:style:hasBorder:]
    static dispatch_once_t fwLoadOnce;
    dispatch_once(&fwLoadOnce, ^{
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSURL *fwURL = [mainBundle.bundleURL URLByAppendingPathComponent:@"Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:fwURL.path]) {
            fwURL = [mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
        }
        if (fwURL && [[NSFileManager defaultManager] fileExistsAtPath:fwURL.path]) {
            dlopen(fwURL.path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        } else {
            const char *execName = _dyld_get_image_name(0);
            if (execName) {
                NSString *bundleDir = [[NSString stringWithUTF8String:execName] stringByDeletingLastPathComponent];
                NSString *fwPath = [bundleDir stringByAppendingPathComponent:@"Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:fwPath]) {
                    dlopen(fwPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
                }
            }
        }
    });

    SEL lcSel = NSSelectorFromString(@"generateIconForBundleURL:style:hasBorder:");
    if ([UIImage respondsToSelector:lcSel]) {
        @try {
            typedef UIImage * (*LCGenIconFunc)(id, SEL, NSURL *, NSInteger, BOOL);
            Method method = class_getClassMethod([UIImage class], lcSel);
            if (method) {
                LCGenIconFunc func = (LCGenIconFunc)method_getImplementation(method);
                UIImage *icon = func([UIImage class], lcSel, bundleURL, 0, YES);
                if (icon && icon.size.width > 0) {
                    [s_tweakIconCache setObject:icon forKey:appPath];
                    return icon;
                }
            }
        } @catch (NSException *e) {}
    }

    // 阶段 2: 尝试系统私有框架 IconServices.framework
    static dispatch_once_t isToken;
    static BOOL isAvailable = NO;
    dispatch_once(&isToken, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW);
        if (h) isAvailable = YES;
    });

    if (isAvailable) {
        Class ISBundleIconCls = NSClassFromString(@"ISBundleIcon");
        Class ISImageDescriptorCls = NSClassFromString(@"ISImageDescriptor");
        Class ISGenRequestCls = NSClassFromString(@"ISGenerationRequest");
        if (ISBundleIconCls && ISImageDescriptorCls && ISGenRequestCls) {
            @try {
                id bundleIcon = [[ISBundleIconCls alloc] performSelector:NSSelectorFromString(@"initWithBundleURL:") withObject:bundleURL];
                id descriptor = [ISImageDescriptorCls performSelector:NSSelectorFromString(@"imageDescriptorNamed:") withObject:@"com.apple.IconServices.ImageDescriptor.HomeScreen"];
                if (bundleIcon && descriptor) {
                    CGFloat scale = [UIScreen mainScreen].scale;
                    if ([descriptor respondsToSelector:NSSelectorFromString(@"setScale:")]) {
                        ((void (*)(id, SEL, CGFloat))objc_msgSend)(descriptor, NSSelectorFromString(@"setScale:"), scale);
                    }
                    if ([descriptor respondsToSelector:NSSelectorFromString(@"setAppearance:")]) {
                        ((void (*)(id, SEL, NSInteger))objc_msgSend)(descriptor, NSSelectorFromString(@"setAppearance:"), 0);
                    }
                    if ([descriptor respondsToSelector:NSSelectorFromString(@"setDrawBorder:")]) {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(descriptor, NSSelectorFromString(@"setDrawBorder:"), YES);
                    }
                    if ([descriptor respondsToSelector:NSSelectorFromString(@"setShouldApplyMask:")]) {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(descriptor, NSSelectorFromString(@"setShouldApplyMask:"), YES);
                    }
                    id request = [[ISGenRequestCls alloc] init];
                    if ([request respondsToSelector:NSSelectorFromString(@"setIcon:")]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"setIcon:"), bundleIcon);
                    }
                    if ([request respondsToSelector:NSSelectorFromString(@"setImageDescriptor:")]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"setImageDescriptor:"), descriptor);
                    }
                    if ([request respondsToSelector:NSSelectorFromString(@"setIgnoreCache:")]) {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(request, NSSelectorFromString(@"setIgnoreCache:"), YES);
                    }
                    if ([request respondsToSelector:NSSelectorFromString(@"generateImageReturningRecordIdentifiers:")]) {
                        id isImage = ((id (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"generateImageReturningRecordIdentifiers:"), nil);
                        if (isImage && [isImage respondsToSelector:NSSelectorFromString(@"CGImage")]) {
                            CGImageRef cgImage = ((CGImageRef (*)(id, SEL))objc_msgSend)(isImage, NSSelectorFromString(@"CGImage"));
                            if (cgImage) {
                                UIImage *icon = [UIImage imageWithCGImage:cgImage scale:scale orientation:UIImageOrientationUp];
                                if (icon && icon.size.width > 0) {
                                    [s_tweakIconCache setObject:icon forKey:appPath];
                                    return icon;
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}
        }
    }

    // 阶段 3: 提取候选图标名列表
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    id iconsDict = plist[@"CFBundleIcons"];
    if ([iconsDict isKindOfClass:[NSDictionary class]]) {
        id primary = iconsDict[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            NSArray *files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]]) {
                for (id f in [files reverseObjectEnumerator]) {
                    if ([f isKindOfClass:[NSString class]] && [f length] > 0) [candidates addObject:f];
                }
            }
            id iconName = primary[@"CFBundleIconName"];
            if ([iconName isKindOfClass:[NSString class]] && [iconName length] > 0) [candidates addObject:iconName];
        }
    }
    id ipadIcons = plist[@"CFBundleIcons~ipad"];
    if ([ipadIcons isKindOfClass:[NSDictionary class]]) {
        id primary = ipadIcons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            NSArray *files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]]) {
                for (id f in [files reverseObjectEnumerator]) {
                    if ([f isKindOfClass:[NSString class]] && [f length] > 0) [candidates addObject:f];
                }
            }
            id iconName = primary[@"CFBundleIconName"];
            if ([iconName isKindOfClass:[NSString class]] && [iconName length] > 0) [candidates addObject:iconName];
        }
    }
    id iconFile = plist[@"CFBundleIconFile"];
    if ([iconFile isKindOfClass:[NSString class]] && [iconFile length] > 0) [candidates addObject:iconFile];
    id iconFiles = plist[@"CFBundleIconFiles"];
    if ([iconFiles isKindOfClass:[NSArray class]]) {
        for (id f in [iconFiles reverseObjectEnumerator]) {
            if ([f isKindOfClass:[NSString class]] && [f length] > 0) [candidates addObject:f];
        }
    }
    [candidates addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon76x76", @"AppIcon", @"icon", @"Icon"]];

    // 阶段 4: 从客态 NSBundle 解压提取 Assets.car (支持 Lanerc/Flutter/现代 Xcode 打包)
    NSBundle *guestBundle = [NSBundle bundleWithPath:appPath];
    if (guestBundle) {
        for (NSString *name in candidates) {
            UIImage *img = [UIImage imageNamed:name inBundle:guestBundle compatibleWithTraitCollection:nil];
            if (img && img.size.width > 0) {
                [s_tweakIconCache setObject:img forKey:appPath];
                return img;
            }
        }
    }

    // 阶段 5: 磁盘文件精准与多倍率扫描
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *suffixes = @[@"@3x.png", @"@2x.png", @".png", @""];
    for (NSString *base in candidates) {
        for (NSString *sfx in suffixes) {
            NSString *fullName = [base hasSuffix:@".png"] ? base : [base stringByAppendingString:sfx];
            NSString *fullFilePath = [appPath stringByAppendingPathComponent:fullName];
            if ([fm fileExistsAtPath:fullFilePath]) {
                UIImage *img = [UIImage imageWithContentsOfFile:fullFilePath];
                if (img && img.size.width > 0) {
                    [s_tweakIconCache setObject:img forKey:appPath];
                    return img;
                }
            }
        }
    }

    // 阶段 6: 磁盘文件模糊枚举兜底 (按体积降序)
    NSArray<NSString *> *subpaths = [fm contentsOfDirectoryAtPath:appPath error:nil];
    if (subpaths) {
        NSMutableArray<NSString *> *fuzzyCandidates = [NSMutableArray array];
        for (NSString *sub in subpaths) {
            NSString *lower = [sub lowercaseString];
            if ([lower containsString:@"icon"] && [lower hasSuffix:@".png"]) {
                [fuzzyCandidates addObject:sub];
            } else if ([lower isEqualToString:@"itunesartwork"] || [lower isEqualToString:@"itunesartwork@2x"]) {
                [fuzzyCandidates addObject:sub];
            }
        }
        [fuzzyCandidates sortUsingComparator:^NSComparisonResult(NSString *f1, NSString *f2) {
            NSString *p1 = [appPath stringByAppendingPathComponent:f1];
            NSString *p2 = [appPath stringByAppendingPathComponent:f2];
            NSDictionary *a1 = [fm attributesOfItemAtPath:p1 error:nil];
            NSDictionary *a2 = [fm attributesOfItemAtPath:p2 error:nil];
            NSNumber *s1 = a1[NSFileSize] ?: @0;
            NSNumber *s2 = a2[NSFileSize] ?: @0;
            return [s2 compare:s1];
        }];
        for (NSString *cand in fuzzyCandidates) {
            NSString *candPath = [appPath stringByAppendingPathComponent:cand];
            UIImage *img = [UIImage imageWithContentsOfFile:candPath];
            if (img && img.size.width > 0) {
                [s_tweakIconCache setObject:img forKey:appPath];
                return img;
            }
        }
    }

    return nil;
}

// MARK: - 平滑无缝切入其他沙盒应用

+ (void)presentTransitionAndSwitchToApp:(LCSwitcherAppInfo *)app completion:(nullable void (^)(BOOL finished))completion {
    [self setupIfNeeded];

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
    [feedback impactOccurred];

    if (gIsMultitaskHostMode) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *docs = [self realHostDocumentsDirectory];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *appsDir = docs.length ? [docs stringByAppendingPathComponent:@"Applications"] : @"";
            NSString *resolvedFolder = app.folderName ?: @"";
            NSString *appPath = appsDir.length ? [appsDir stringByAppendingPathComponent:resolvedFolder] : @"";
            if (appPath.length && ![fm fileExistsAtPath:appPath] && [fm fileExistsAtPath:[appPath stringByAppendingString:@".app"]]) {
                appPath = [appPath stringByAppendingString:@".app"];
                resolvedFolder = [resolvedFolder stringByAppendingString:@".app"];
            }
            NSString *finalUUID = app.dataUUID ?: @"";
            if (!finalUUID.length && appPath.length) {
                NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
                finalUUID = lcInfo[@"LCDataUUID"] ?: @"";
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES);
                // 1. 若多任务舞台中已存在该应用窗口，完整恢复（含 alpha/transform/PiP）并置顶
                Class dvcCls = LCFindHostClass(@"DecoratedAppSceneViewController");
                if (dvcCls && finalUUID.length) {
                    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                            if (!win.rootViewController) continue;
                            NSMutableArray<UIViewController *> *q = [NSMutableArray arrayWithObject:win.rootViewController];
                            while (q.count > 0) {
                                UIViewController *vc = q.firstObject;
                                [q removeObjectAtIndex:0];
                                if ([vc isKindOfClass:dvcCls] && vc.view.superview != nil && vc.view.window != nil) {
                                    @try {
                                        NSString *uuid = [vc valueForKey:@"dataUUID"];
                                        BOOL stillUsing = YES;
                                        Class mmCls = LCFindHostClass(@"MultitaskManager");
                                        SEL isUsingSel = NSSelectorFromString(@"isUsingWithContainer:");
                                        if (mmCls && [mmCls respondsToSelector:isUsingSel]) {
                                            stillUsing = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(mmCls, isUsingSel, finalUUID);
                                        }
                                        if (stillUsing && [uuid isEqualToString:finalUUID]) {
                                            BOOL isCurrentlyVisible = (!vc.view.hidden && vc.view.alpha > 0.1);
                                            BOOL isTopmostVisible = NO;
                                            if (isCurrentlyVisible && vc.view.superview) {
                                                for (UIView *sib in [vc.view.superview.subviews reverseObjectEnumerator]) {
                                                    if (sib.hidden || sib.alpha < 0.1) continue;
                                                    isTopmostVisible = (sib == vc.view);
                                                    break;
                                                }
                                            }
                                            if (isCurrentlyVisible && isTopmostVisible) {
                                                // 已在最前台：点击切换到后台（最小化）
                                                SEL minSel = NSSelectorFromString(@"minimizeWindow");
                                                if ([vc respondsToSelector:minSel]) {
                                                    [vc performSelector:minSel];
                                                } else {
                                                    vc.view.hidden = YES;
                                                }
                                                return;
                                            }
                                            // 在后台或被遮挡：点击切回前台并置顶
                                            Class pipCls = LCFindHostClass(@"PiPManager");
                                            if (pipCls && [pipCls respondsToSelector:@selector(shared)]) {
                                                id pipMgr = [pipCls valueForKey:@"shared"];
                                                SEL isPiPDecSel = NSSelectorFromString(@"isPiPWithDecoratedVC:");
                                                if ([pipMgr respondsToSelector:isPiPDecSel]) {
                                                    BOOL inPiP = ((BOOL (*)(id, SEL, id))objc_msgSend)(pipMgr, isPiPDecSel, vc);
                                                    if (inPiP) [pipMgr performSelector:NSSelectorFromString(@"stopPiP")];
                                                }
                                            }
                                            vc.view.hidden = NO;
                                            vc.view.alpha = 1.0;
                                            vc.view.transform = CGAffineTransformIdentity;
                                            [vc.view.superview bringSubviewToFront:vc.view];
                                            [[LCSwitcher sharedManager] ensureWindowAttached];
                                            return;
                                        }
                                    } @catch (__unused NSException *e) {}
                                }
                                if (vc.presentedViewController) [q addObject:vc.presentedViewController];
                                [q addObjectsFromArray:vc.childViewControllers];
                            }
                        }
                    }
                }
                // 2. 未打开则先写入 selected / selectedContainer，再直接调用原版 LCUtils.launchMultitaskGuestApp:completionHandler:
                NSString *requestID = [NSUUID UUID].UUIDString;
                [self syncLaunchSelectionToHost:resolvedFolder dataUUID:finalUUID requestID:requestID isJIT:app.isJITEnabled];
                Class lcUtilsCls = LCFindHostClass(@"LCUtils");
                SEL launchSel = NSSelectorFromString(@"launchMultitaskGuestApp:completionHandler:");
                if (lcUtilsCls && [lcUtilsCls respondsToSelector:launchSel]) {
                    void (^cb)(NSNumber *, NSError *) = ^(NSNumber *pid, NSError *error) {
                        if (error) {
                            NSLog(@"[LCSwitcher] ⚠️ 多任务启动失败: %@", error.localizedDescription);
                        }
                    };
                    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(lcUtilsCls, launchSel, app.name ?: resolvedFolder, cb);
                    return;
                }
                NSString *encodedFolder = [resolvedFolder stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: resolvedFolder;
                NSString *urlStr = [NSString stringWithFormat:@"livecontainer://livecontainer-launch?bundle-name=%@", encodedFolder];
                NSURL *url = [NSURL URLWithString:urlStr];
                if (url) {
                    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                }
            });
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *docs = [self realHostDocumentsDirectory];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *appsDir = docs.length ? [docs stringByAppendingPathComponent:@"Applications"] : @"";
        NSString *appPath = appsDir.length ? [appsDir stringByAppendingPathComponent:app.folderName] : @"";
        NSString *resolvedFolder = app.folderName;

        if (appPath.length && ![fm fileExistsAtPath:appPath] && [fm fileExistsAtPath:[appPath stringByAppendingString:@".app"]]) {
            appPath = [appPath stringByAppendingString:@".app"];
            resolvedFolder = [resolvedFolder stringByAppendingString:@".app"];
        }

        NSString *finalUUID = app.dataUUID;
        if (!finalUUID.length && appPath.length) {
            NSString *lcAppInfoPath = [appPath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            finalUUID = lcInfo[@"LCDataUUID"] ?: @"";
        }
        if (!finalUUID.length) {
            finalUUID = [NSUUID UUID].UUIDString;
            if (appPath.length) {
                NSString *lcAppInfoPath = [appPath stringByAppendingPathComponent:@"LCAppInfo.plist"];
                NSMutableDictionary *mutableLCInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath] ?: [NSMutableDictionary dictionary];
                mutableLCInfo[@"LCDataUUID"] = finalUUID;
                [mutableLCInfo writeToFile:lcAppInfoPath atomically:YES];
            }
        }

        // 预先确保目标独立沙盒应用数据目录结构完整
        if (docs.length) {
            NSString *dataRoot = [[docs stringByAppendingPathComponent:@"Data/Application"] stringByAppendingPathComponent:finalUUID];
            [fm createDirectoryAtPath:dataRoot withIntermediateDirectories:YES attributes:nil error:nil];
            [fm createDirectoryAtPath:[dataRoot stringByAppendingPathComponent:@"Documents"] withIntermediateDirectories:YES attributes:nil error:nil];
            [fm createDirectoryAtPath:[dataRoot stringByAppendingPathComponent:@"Library/Preferences"] withIntermediateDirectories:YES attributes:nil error:nil];
            [fm createDirectoryAtPath:[dataRoot stringByAppendingPathComponent:@"tmp"] withIntermediateDirectories:YES attributes:nil error:nil];
        }

        NSString *requestID = [NSUUID UUID].UUIDString;
        // 核心同步：向 LiveContainer 宿主写入切换目标，跳过过渡画面以获得丝滑切换体验
        [self syncLaunchSelectionToHost:resolvedFolder dataUUID:finalUUID requestID:requestID isJIT:app.isJITEnabled];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES);
            [self dispatchSwitchToApp:resolvedFolder dataUUID:finalUUID];
        });
    });
}

// MARK: - 平滑退出沙盒返回宿主主页

+ (void)presentTransitionAndReturnHomeWithCompletion:(nullable void (^)(BOOL finished))completion {
    [self setupIfNeeded];

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    if (gIsMultitaskHostMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
            if (dockMgrCls && [dockMgrCls respondsToSelector:@selector(shared)]) {
                id dockMgr = [dockMgrCls valueForKey:@"shared"];
                SEL minSel = NSSelectorFromString(@"minimizeAllWindowsWithExcept:");
                if ([dockMgr respondsToSelector:minSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(dockMgr, minSel, nil);
                }
            }
            if (completion) completion(YES);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self clearLaunchSelectionFromHost];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES);
            [self dispatchReturnHome];
        });
    });
}

// MARK: - 跨沙盒同步启动凭据至 LiveContainer 宿主

+ (void)syncLaunchSelectionToHost:(NSString *)folderName
                         dataUUID:(NSString *)dataUUID
                        requestID:(NSString *)requestID
                            isJIT:(BOOL)isJIT {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // 1. 写入 LiveContainer 官方 lcUserDefaults / lcSharedDefaults (这是 LiveContainer 识别启动目标的根本途径)
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcUserDefaults")]) {
        NSUserDefaults *lcUD = [NSUserDefaults performSelector:NSSelectorFromString(@"lcUserDefaults")];
        [lcUD setObject:folderName forKey:@"selected"];
        [lcUD setObject:dataUUID forKey:@"selectedContainer"];
        [lcUD setObject:dataUUID forKey:@"lastLaunchDataUUID"];
        [lcUD setObject:requestID forKey:@"GnoixContainerLaunchRequestID"];
        [lcUD setDouble:now forKey:@"GnoixContainerLaunchRequestTime"];
        [lcUD setBool:NO forKey:@"LCKeepSelectedWhenQuit"];
        [lcUD setBool:!isJIT forKey:@"LCIgnoreJITOnLaunch"];
        [lcUD synchronize];
    }
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcSharedDefaults")]) {
        NSUserDefaults *sharedUD = [NSUserDefaults performSelector:NSSelectorFromString(@"lcSharedDefaults")];
        [sharedUD setObject:folderName forKey:@"selected"];
        [sharedUD setObject:dataUUID forKey:@"selectedContainer"];
        [sharedUD setObject:dataUUID forKey:@"lastLaunchDataUUID"];
        [sharedUD setObject:requestID forKey:@"GnoixContainerLaunchRequestID"];
        [sharedUD setDouble:now forKey:@"GnoixContainerLaunchRequestTime"];
        [sharedUD setBool:NO forKey:@"LCKeepSelectedWhenQuit"];
        [sharedUD setBool:!isJIT forKey:@"LCIgnoreJITOnLaunch"];
        [sharedUD synchronize];
    }

    // 2. 写入 AppGroup 共享 Suites
    NSMutableArray<NSString *> *suites = [NSMutableArray arrayWithArray:@[
        @"group.com.kdt.livecontainer.shared",
        @"group.cn.oily.gnoix.lcdata"
    ]];
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    if (sharedUtils && [sharedUtils respondsToSelector:NSSelectorFromString(@"appGroupID")]) {
        NSString *gid = [sharedUtils performSelector:NSSelectorFromString(@"appGroupID")];
        if (gid.length && ![suites containsObject:gid]) {
            [suites addObject:gid];
        }
    }
    for (NSString *suiteName in suites) {
        NSUserDefaults *grpUD = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [grpUD setObject:folderName forKey:@"selected"];
        [grpUD setObject:dataUUID forKey:@"selectedContainer"];
        [grpUD setObject:dataUUID forKey:@"lastLaunchDataUUID"];
        [grpUD setObject:requestID forKey:@"GnoixContainerLaunchRequestID"];
        [grpUD setDouble:now forKey:@"GnoixContainerLaunchRequestTime"];
        [grpUD setBool:NO forKey:@"LCKeepSelectedWhenQuit"];
        [grpUD setBool:!isJIT forKey:@"LCIgnoreJITOnLaunch"];
        [grpUD synchronize];
    }

    // 3. 写入当前进程 standardUserDefaults (针对未开启数据隔离的应用)
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:folderName forKey:@"selected"];
    [ud setObject:dataUUID forKey:@"selectedContainer"];
    [ud setObject:dataUUID forKey:@"lastLaunchDataUUID"];
    [ud setObject:requestID forKey:@"GnoixContainerLaunchRequestID"];
    [ud setDouble:now forKey:@"GnoixContainerLaunchRequestTime"];
        [ud setBool:NO forKey:@"LCKeepSelectedWhenQuit"];
    [ud setBool:!isJIT forKey:@"LCIgnoreJITOnLaunch"];
    [ud setBool:YES forKey:@"GnoixSkipGuestLaunchOverlay"];
    [ud synchronize];

    // 4. 写入物理凭据文件 next_launch_container.plist (支持 Gnoix 及原生冷启动机制)
    NSString *docs = [self realHostDocumentsDirectory];
    if (docs.length) {
        NSString *nextLaunchPath = [docs stringByAppendingPathComponent:@"next_launch_container.plist"];
        NSDictionary *payload = @{
            @"selected": folderName,
            @"selectedContainer": dataUUID ?: @"",
            @"lastLaunchDataUUID": dataUUID ?: @"",
            @"GnoixContainerLaunchRequestID": requestID,
            @"GnoixContainerLaunchRequestTime": @(now),
            @"GnoixNeedInternalJIT": @(isJIT),
            @"LCIgnoreJITOnLaunch": @(!isJIT),
            @"GnoixSkipGuestLaunchOverlay": @YES
        };
        [payload writeToFile:nextLaunchPath atomically:YES];

        // 关键安全清理：提前移除 container_launch_in_progress.flag，防止新进程被 CrashGuard 判定为异常强杀
        NSString *flagPath = [docs stringByAppendingPathComponent:@"container_launch_in_progress.flag"];
        [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
    }
}

// MARK: - 清理启动凭据以安全返回宿主

+ (void)clearLaunchSelectionFromHost {
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcUserDefaults")]) {
        NSUserDefaults *lcUD = [NSUserDefaults performSelector:NSSelectorFromString(@"lcUserDefaults")];
        [lcUD removeObjectForKey:@"selected"];
        [lcUD removeObjectForKey:@"selectedContainer"];
        [lcUD removeObjectForKey:@"lastLaunchDataUUID"];
        [lcUD removeObjectForKey:@"GnoixContainerLaunchRequestID"];
        [lcUD removeObjectForKey:@"GnoixContainerLaunchRequestTime"];
        [lcUD synchronize];
    }
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcSharedDefaults")]) {
        NSUserDefaults *sharedUD = [NSUserDefaults performSelector:NSSelectorFromString(@"lcSharedDefaults")];
        [sharedUD removeObjectForKey:@"selected"];
        [sharedUD removeObjectForKey:@"selectedContainer"];
        [sharedUD removeObjectForKey:@"lastLaunchDataUUID"];
        [sharedUD removeObjectForKey:@"GnoixContainerLaunchRequestID"];
        [sharedUD removeObjectForKey:@"GnoixContainerLaunchRequestTime"];
        [sharedUD synchronize];
    }
    NSMutableArray<NSString *> *suites = [NSMutableArray arrayWithArray:@[
        @"group.com.kdt.livecontainer.shared",
        @"group.cn.oily.gnoix.lcdata"
    ]];
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    if (sharedUtils && [sharedUtils respondsToSelector:NSSelectorFromString(@"appGroupID")]) {
        NSString *gid = [sharedUtils performSelector:NSSelectorFromString(@"appGroupID")];
        if (gid.length && ![suites containsObject:gid]) {
            [suites addObject:gid];
        }
    }
    for (NSString *suiteName in suites) {
        NSUserDefaults *grpUD = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [grpUD removeObjectForKey:@"selected"];
        [grpUD removeObjectForKey:@"selectedContainer"];
        [grpUD removeObjectForKey:@"lastLaunchDataUUID"];
        [grpUD removeObjectForKey:@"GnoixContainerLaunchRequestID"];
        [grpUD removeObjectForKey:@"GnoixContainerLaunchRequestTime"];
        [grpUD synchronize];
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:@"selected"];
    [ud removeObjectForKey:@"selectedContainer"];
    [ud removeObjectForKey:@"lastLaunchDataUUID"];
    [ud removeObjectForKey:@"GnoixContainerLaunchRequestID"];
    [ud removeObjectForKey:@"GnoixContainerLaunchRequestTime"];
    [ud synchronize];

    NSString *docs = [self realHostDocumentsDirectory];
    if (docs.length) {
        NSString *nextLaunchPath = [docs stringByAppendingPathComponent:@"next_launch_container.plist"];
        [[NSFileManager defaultManager] removeItemAtPath:nextLaunchPath error:nil];
        NSString *flagPath = [docs stringByAppendingPathComponent:@"container_launch_in_progress.flag"];
        [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
    }
}

// MARK: - 调度交接重启至新应用

+ (void)dispatchSwitchToApp:(NSString *)folderName dataUUID:(NSString *)dataUUID {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");

    // 1. 获取宿主支持的有效 URL Scheme
    NSMutableArray<NSString *> *schemes = [NSMutableArray array];
    if (sharedUtils && [sharedUtils respondsToSelector:NSSelectorFromString(@"lcUrlSchemes")]) {
        NSArray *lcSchemes = [sharedUtils performSelector:NSSelectorFromString(@"lcUrlSchemes")];
        if ([lcSchemes isKindOfClass:[NSArray class]]) {
            for (id s in lcSchemes) {
                if ([s isKindOfClass:[NSString class]] && [s length] > 0) {
                    [schemes addObject:s];
                }
            }
        }
    }
    if (![schemes containsObject:@"livecontainer"]) [schemes addObject:@"livecontainer"];
    if (![schemes containsObject:@"gnoix"]) [schemes addObject:@"gnoix"];

    NSString *primaryScheme = schemes.firstObject ?: @"livecontainer";
    NSString *encodedFolder = [folderName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: folderName;
    NSString *encodedUUID = [dataUUID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: dataUUID;

    // 核心协议：livecontainer-launch 带参唤醒，兼容官方 LiveContainer 与 Gnoix 容器
    NSString *primaryUrlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@&folder-name=%@",
                               primaryScheme, encodedFolder, encodedUUID, encodedFolder];
    NSURL *primaryLaunchURL = [NSURL URLWithString:primaryUrlStr];

    NSLog(@"[LCSwitcher] 🚀 正在执行应用切入调度: target=%@, URL=%@", folderName, primaryUrlStr);

    void (^terminateCurrentGuest)(void) = ^{
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *docs = [self realHostDocumentsDirectory];
            if (docs.length) {
                NSString *flag = [docs stringByAppendingPathComponent:@"container_launch_in_progress.flag"];
                [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
            }
#if defined(__arm64__)
            __asm__ __volatile__ (
                "mov x0, #31\n"
                "mov x16, #26\n"
                "svc #0x80"
            );
#endif
            kill(getpid(), SIGKILL);
        });
    };

    // 核心通道 1：调用 LiveContainer 原生 launchToGuestAppWithURL: (由官方库完成参数解析、写入配置与冷启动接管)
    SEL launchWithURLSel = NSSelectorFromString(@"launchToGuestAppWithURL:");
    if (sharedUtils && [sharedUtils respondsToSelector:launchWithURLSel]) {
        BOOL ok = ((BOOL (*)(id, SEL, id))[sharedUtils methodForSelector:launchWithURLSel])(sharedUtils, launchWithURLSel, primaryLaunchURL);
        if (ok) {
            NSLog(@"[LCSwitcher] ✅ LCSharedUtils launchToGuestAppWithURL 调度成功");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                terminateCurrentGuest();
            });
            return;
        }
    }

    // 核心通道 2：UIApplication openURL 触发 livecontainer-launch Scheme 唤醒
    UIApplication *app = [UIApplication sharedApplication];
    for (NSString *sch in schemes) {
        NSString *uStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@&folder-name=%@",
                          sch, encodedFolder, encodedUUID, encodedFolder];
        NSURL *u = [NSURL URLWithString:uStr];
        if (u && [app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [app openURL:u options:@{} completionHandler:nil];
        }
    }

    // 核心通道 3：LSApplicationWorkspace 原生拉起
    NSString *bundleId = [self hostBundleIdentifier];
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = (wsClass && [wsClass respondsToSelector:@selector(defaultWorkspace)]) ? [wsClass performSelector:@selector(defaultWorkspace)] : nil;
    if (workspace) {
        Class configClass = NSClassFromString(@"_LSOpenConfiguration") ?: objc_lookUpClass("_LSOpenConfiguration");
        id config = configClass ? [[configClass alloc] init] : nil;
        if (config && primaryLaunchURL && [config respondsToSelector:@selector(setFrontBoardOptions:)]) {
            NSDictionary *opts = @{@"__URL__": primaryLaunchURL.absoluteString};
            [config performSelector:@selector(setFrontBoardOptions:) withObject:opts];
        }
        SEL openSel = @selector(openApplicationWithBundleIdentifier:configuration:completionHandler:);
        if (![workspace respondsToSelector:openSel]) {
            openSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:usingConfiguration:completionHandler:");
        }
        if ([workspace respondsToSelector:openSel]) {
            typedef void (*OpenAppFunc)(id, SEL, NSString *, id, void (^)(BOOL, NSError *));
            OpenAppFunc openFunc = (OpenAppFunc)[workspace methodForSelector:openSel];
            openFunc(workspace, openSel, bundleId, config, ^(BOOL ok, NSError *err) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    terminateCurrentGuest();
                });
            });
        }
    }

    // 核心通道 4：兜底调用 launchToGuestAppWithClassicMode:
    SEL classicSel = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if (sharedUtils && [sharedUtils respondsToSelector:classicSel]) {
        ((BOOL (*)(id, SEL, NSUInteger))[sharedUtils methodForSelector:classicSel])(sharedUtils, classicSel, 0);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        terminateCurrentGuest();
    });
}

// MARK: - 调度安全返回宿主主页

+ (void)dispatchReturnHome {
    [self clearLaunchSelectionFromHost];

    void (^terminateCurrentGuest)(void) = ^{
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *docs = [self realHostDocumentsDirectory];
            if (docs.length) {
                NSString *flag = [docs stringByAppendingPathComponent:@"container_launch_in_progress.flag"];
                [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
            }
#if defined(__arm64__)
            __asm__ __volatile__ (
                "mov x0, #31\n"
                "mov x16, #26\n"
                "svc #0x80"
            );
#endif
            kill(getpid(), SIGKILL);
        });
    };

    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    SEL classicSel = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if (sharedUtils && [sharedUtils respondsToSelector:classicSel]) {
        BOOL ok = ((BOOL (*)(id, SEL, NSUInteger))[sharedUtils methodForSelector:classicSel])(sharedUtils, classicSel, 0);
        if (ok) {
            NSLog(@"[LCSwitcher] ✅ 返回宿主：LCSharedUtils launchToGuestAppWithClassicMode 调度成功");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                terminateCurrentGuest();
            });
            return;
        }
    }

    // 兜底：openURL livecontainer-relaunch
    NSArray<NSString *> *schemes = @[@"livecontainer://livecontainer-relaunch", @"gnoix://livecontainer-relaunch"];
    UIApplication *app = [UIApplication sharedApplication];
    for (NSString *str in schemes) {
        NSURL *url = [NSURL URLWithString:str];
        if (url && [app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [app openURL:url options:@{} completionHandler:nil];
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        terminateCurrentGuest();
    });
}

+ (void)fallbackSwitchToFolder:(NSString *)folderName dataUUID:(NSString *)dataUUID isJIT:(BOOL)isJIT completion:(nullable void (^)(BOOL finished))completion {
    NSString *requestID = [NSUUID UUID].UUIDString;
    [self syncLaunchSelectionToHost:folderName dataUUID:dataUUID requestID:requestID isJIT:isJIT];
    if (completion) completion(YES);
    [self dispatchSwitchToApp:folderName dataUUID:dataUUID];
}

+ (void)fallbackReturnHomeWithCompletion:(nullable void (^)(BOOL finished))completion {
    [self clearLaunchSelectionFromHost];
    if (completion) completion(YES);
    [self dispatchReturnHome];
}

// MARK: - 真实环境路径推导与沙盒探测

+ (NSString *)realHostDocumentsDirectory {
    // 1. 优先读取 Gnoix 注入的环境变量
    const char *envRealDocs = getenv("GNOIX_REAL_DOCUMENTS");
    if (envRealDocs && strlen(envRealDocs) > 0) {
        NSString *path = [NSString stringWithUTF8String:envRealDocs];
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
            return path;
        }
    }

    // 2. 从 LC_HOME_PATH 推导
    const char *lcHome = getenv("LC_HOME_PATH");
    if (lcHome && strlen(lcHome) > 0) {
        NSString *path = [[NSString stringWithUTF8String:lcHome] stringByAppendingPathComponent:@"Documents"];
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
            return path;
        }
    }

    // 3. 从 HOME 环境变量向上推导（客态私有 Documents/Data/Application/<UUID>）
    const char *home = getenv("HOME");
    if (home && strlen(home) > 0) {
        NSString *homeStr = [NSString stringWithUTF8String:home];
        NSRange r = [homeStr rangeOfString:@"/Documents/Data/Application/"];
        if (r.location != NSNotFound) {
            NSString *docs = [homeStr substringToIndex:r.location + @"/Documents".length];
            struct stat st;
            if (stat(docs.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                return docs;
            }
        }
        NSRange rData = [homeStr rangeOfString:@"/Data/Application/"];
        if (rData.location != NSNotFound) {
            NSString *hostHome = [homeStr substringToIndex:rData.location];
            NSString *docs = [hostHome stringByAppendingPathComponent:@"Documents"];
            struct stat st;
            if (stat(docs.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                return docs;
            }
        }
        NSString *docs = [homeStr stringByAppendingPathComponent:@"Documents"];
        struct stat st;
        if (stat(docs.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
            return docs;
        }
    }

    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"";
}

+ (NSString *)currentGuestFolderName {
    // 1. 环境变量
    const char *envAppId = getenv("LC_APP_ID");
    if (envAppId && strlen(envAppId) > 0) {
        return [NSString stringWithUTF8String:envAppId];
    }

    // 2. LiveContainer 注入的客态标识 lcGuestAppId
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcGuestAppId")]) {
        NSString *gid = [NSUserDefaults performSelector:NSSelectorFromString(@"lcGuestAppId")];
        if (gid.length > 0) {
            return gid;
        }
    }

    // 3. lcUserDefaults selected
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcUserDefaults")]) {
        NSUserDefaults *lcUD = [NSUserDefaults performSelector:NSSelectorFromString(@"lcUserDefaults")];
        NSString *sel = [lcUD stringForKey:@"selected"];
        if (sel.length > 0) {
            return sel;
        }
    }

    // 4. guestAppInfo
    if ([NSUserDefaults respondsToSelector:@selector(guestAppInfo)]) {
        NSDictionary *info = [NSUserDefaults guestAppInfo];
        NSString *bundlePath = info[@"bundlePath"];
        if (bundlePath.length > 0) {
            return [bundlePath lastPathComponent];
        }
    }

    // 5. standardUserDefaults selected
    NSString *selected = [[NSUserDefaults standardUserDefaults] stringForKey:@"selected"];
    if (selected.length > 0) {
        return selected;
    }

    // 6. fallback mainBundle
    NSString *path = [NSBundle mainBundle].bundlePath;
    if ([path hasSuffix:@".app"]) {
        return [path lastPathComponent];
    }

    return @"";
}

+ (NSString *)hostBundleIdentifier {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"GnoixHostRealBundleIdentifier"];
    if (saved.length > 0) return saved;

    if ([NSUserDefaults respondsToSelector:@selector(lcMainBundle)]) {
        NSBundle *b = [NSUserDefaults lcMainBundle];
        if (b.bundleIdentifier.length > 0) return b.bundleIdentifier;
    }

    const char *envHostBid = getenv("LC_HOST_BUNDLE_ID");
    if (envHostBid && strlen(envHostBid) > 0) {
        return [NSString stringWithUTF8String:envHostBid];
    }

    return @"com.kdt.livecontainer";
}

+ (BOOL)isContainerGuestRunning {
    // 门禁 1：插件扩展 (.appex) 子进程不加载侧边栏
    if (LCIsMultitaskExtensionProcess()) return NO;

    // 门禁 2：LiveContainer / Gnoix 宿主自身进程（未加载单任务客体 App 时）绝不当作单任务客体
    if (LCIsLiveContainerHostProcess()) return NO;

    // 环境变量特征
    if (getenv("LC_APP_ID") || getenv("GNOIX_REAL_DOCUMENTS") || getenv("LC_HOME_PATH")) {
        return YES;
    }

    // Bundle 路径特征
    if ([[NSBundle mainBundle].bundlePath containsString:@"/Documents/Applications/"]) {
        return YES;
    }

    // LCMachOHelper 特征
    Class helperCls = NSClassFromString(@"LCMachOHelper");
    if (helperCls && [helperCls respondsToSelector:NSSelectorFromString(@"isContainerGuestRunning")]) {
        BOOL (*func)(id, SEL) = (BOOL (*)(id, SEL))[helperCls methodForSelector:NSSelectorFromString(@"isContainerGuestRunning")];
        return func(helperCls, NSSelectorFromString(@"isContainerGuestRunning"));
    }

    return NO;
}

@end

// MARK: - 宿主多任务侧边栏接管 (替代 LC / Gnoix 原生多任务侧边栏)

static CFMutableDictionaryRef gOrigDockDidMoveToWindowIMPs = NULL;
static CFMutableDictionaryRef gOrigDockSetHiddenIMPs = NULL;
static CFMutableDictionaryRef gOrigDockSetAlphaIMPs = NULL;

static void LCHideNativeMultitaskSidebarView(UIView *view) {
    if (!view) return;
    if (!view.hidden) view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
}

static void LCActivateMultitaskHostSwitcherIfNeeded(BOOL active) {
    if (active) {
        if (!gIsMultitaskHostMode) {
            gIsMultitaskHostMode = YES;
            [LCSwitcher setupIfNeeded];
        } else {
            [[LCSwitcher sharedManager] performSetup];
        }
    } else if (gIsMultitaskHostMode && ![LCSwitcher isContainerGuestRunning]) {
        gIsMultitaskHostMode = NO;
        LCSwitcher *mgr = [LCSwitcher sharedManager];
        if (mgr.hostOverlayView) {
            mgr.hostOverlayView.hidden = YES;
        }
        if (mgr.overlayWindow) {
            mgr.overlayWindow.hidden = YES;
        }
    }
}

static void hook_NativeDock_didMoveToWindow(id self, SEL _cmd) {
    if (gOrigDockDidMoveToWindowIMPs) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        IMP orig = m ? (IMP)CFDictionaryGetValue(gOrigDockDidMoveToWindowIMPs, m) : NULL;
        if (orig) {
            ((void (*)(id, SEL))orig)(self, _cmd);
        }
    }
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        if (view.window != nil && !view.hidden) {
            LCHideNativeMultitaskSidebarView(view);
            LCActivateMultitaskHostSwitcherIfNeeded(YES);
        } else if (view.window == nil) {
            LCActivateMultitaskHostSwitcherIfNeeded(NO);
        }
    }
}

static void hook_NativeDock_setHidden(id self, SEL _cmd, BOOL hidden) {
    if (gOrigDockSetHiddenIMPs) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        IMP orig = m ? (IMP)CFDictionaryGetValue(gOrigDockSetHiddenIMPs, m) : NULL;
        if (orig) {
            ((void (*)(id, SEL, BOOL))orig)(self, _cmd, YES);
        }
    }
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        if (!hidden && view.window != nil) {
            LCActivateMultitaskHostSwitcherIfNeeded(YES);
        } else if (hidden) {
            LCActivateMultitaskHostSwitcherIfNeeded(NO);
        }
    }
}

static void hook_NativeDock_setAlpha(id self, SEL _cmd, CGFloat alpha) {
    if (gOrigDockSetAlphaIMPs) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        IMP orig = m ? (IMP)CFDictionaryGetValue(gOrigDockSetAlphaIMPs, m) : NULL;
        if (orig) {
            ((void (*)(id, SEL, CGFloat))orig)(self, _cmd, 0.0);
        }
    }
    if ([self isKindOfClass:[UIView class]] && alpha > 0.01) {
        UIView *view = (UIView *)self;
        if (view.window != nil) {
            LCActivateMultitaskHostSwitcherIfNeeded(YES);
        }
    }
}

static BOOL LCIsNativeMultitaskDockClassName(NSString *clsName) {
    if (!clsName.length || [clsName hasPrefix:@"LCSwitcher"]) return NO;
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"keyboard"] || [lower containsString:@"input"] || [lower containsString:@"statusbar"]) {
        return NO;
    }
    return [lower containsString:@"gnoixmultitaskdockview"] ||
           [lower containsString:@"lcfloatingmenu"] ||
           [lower containsString:@"lcmultitaskdockview"] ||
           [lower containsString:@"multitaskdock"] ||
           [lower containsString:@"multitasksidebar"] ||
           [lower containsString:@"floatingmenu"];
}

static BOOL LCViewTreeContainsSceneHostingView(UIView *root) {
    if (!root) return NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *clsName = NSStringFromClass([v class]);
        if ([clsName containsString:@"SceneHosting"] || [clsName containsString:@"_UISceneLayerHostContainerView"]) {
            return YES;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return NO;
}

static void LCScanHostMultitaskStateAndHideOverlayWindows(NSSet<Class> *dockClasses) {
    if (LCIsMultitaskExtensionProcess() || [LCSwitcher isContainerGuestRunning]) return;

    BOOL hasMultitaskScene = NO;
    Class singleTaskOverlayWinCls = NSClassFromString(@"LCSwitcherOverlayWindow");

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (singleTaskOverlayWinCls && [win isKindOfClass:singleTaskOverlayWinCls]) continue;
            if (win.hidden) continue;

            if (LCViewTreeContainsSceneHostingView(win)) {
                hasMultitaskScene = YES;
            }

            if (dockClasses.count > 0) {
                NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
                while (queue.count > 0) {
                    UIView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if ([dockClasses containsObject:[v class]]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            hasMultitaskScene = YES;
                        }
                        LCHideNativeMultitaskSidebarView(v);
                    }
                    [queue addObjectsFromArray:v.subviews];
                }
            }
        }
    }

    if (hasMultitaskScene) {
        // 隐藏原版 LC 可能使用的独立悬浮侧边栏窗口（windowLevel > Normal 且非系统窗口）
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                if (singleTaskOverlayWinCls && [win isKindOfClass:singleTaskOverlayWinCls]) continue;
                NSString *clsName = NSStringFromClass([win class]);
                if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"] || [clsName containsString:@"StatusBar"]) continue;
                if (win.windowLevel > UIWindowLevelNormal && !LCViewTreeContainsSceneHostingView(win)) {
                    win.hidden = YES;
                    win.alpha = 0.0;
                    win.userInteractionEnabled = NO;
                }
            }
        }
        LCActivateMultitaskHostSwitcherIfNeeded(YES);
    } else if (gIsMultitaskHostMode) {
        LCActivateMultitaskHostSwitcherIfNeeded(NO);
    }
}

static void LCScanExistingWindowsForNativeDock(NSSet<Class> *dockClasses) {
    LCScanHostMultitaskStateAndHideOverlayWindows(dockClasses);
}

static void (*orig_DockMgr_showDock)(id, SEL) = NULL;
static void (*orig_DockMgr_showDockFromHidden)(id, SEL) = NULL;
static void (*orig_DockMgr_hideDock)(id, SEL) = NULL;
static void (*orig_DockMgr_addRunningApp)(id, SEL, id, id, id) = NULL;
static void (*orig_DockMgr_removeRunningApp)(id, SEL, id) = NULL;
static void (*orig_DecoratedVC_viewDidAppear)(id, SEL, BOOL) = NULL;

static void LCHideLCMultitaskDockWindow(id dockMgr) {
    UIView *windowHostingView = nil;
    if (dockMgr) {
        @try {
            windowHostingView = [dockMgr valueForKey:@"windowHostingView"];
        } @catch (__unused NSException *e) {}
    }

    // 原版 LiveContainer 3.8.x 把 MultitaskDockSwiftView (UIHostingController.view) 直接 addSubview 到 keyWindow 上
    // 注意 hostingController 在 Swift 中不是 @objc 属性，不能用 KVC，直接遍历宿主 keyWindow.subviews 精准隐藏！
    Class overlayWinCls = NSClassFromString(@"LCSwitcherOverlayWindow");
    Class virtualHostCls = NSClassFromString(@"VirtualWindowsHostView");
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (overlayWinCls && [win isKindOfClass:overlayWinCls]) continue;
            if (win.hidden) continue;
            UIView *rootView = win.rootViewController.view;
            for (UIView *sub in win.subviews) {
                if (sub == rootView) continue;
                if ([sub isKindOfClass:[LCSwitcherPassthroughView class]]) continue;
                if (windowHostingView && sub == windowHostingView) continue;
                if (virtualHostCls && [sub isKindOfClass:virtualHostCls]) continue;
                NSString *subClsName = NSStringFromClass([sub class]);
                BOOL isSwiftUIHostingDock = [subClsName containsString:@"UIHostingView"];
                BOOL isChildHostingControllerView = ([sub.nextResponder isKindOfClass:[UIViewController class]] &&
                                                     sub.nextResponder != win.rootViewController &&
                                                     [NSStringFromClass([sub.nextResponder class]) containsString:@"UIHostingController"]);
                if (isSwiftUIHostingDock || isChildHostingControllerView) {
                    // 仅隐藏侧边栏尺寸的浮层（避免误伤全屏内容）
                    CGFloat screenW = MAX(win.bounds.size.width, 1.0);
                    if (sub.bounds.size.width <= screenW * 0.55) {
                        sub.hidden = YES;
                        sub.alpha = 0.0;
                        sub.userInteractionEnabled = NO;
                    }
                }
            }
        }
    }
}

static BOOL LCIsHostCurrentlyMultitasking(id *outDockMgr) {
    Class dockMgrCls = LCFindHostClass(@"MultitaskDockManager");
    Class multitaskMgrCls = LCFindHostClass(@"MultitaskManager");

    id dockMgr = nil;
    if (dockMgrCls && [dockMgrCls respondsToSelector:@selector(shared)]) {
        dockMgr = [dockMgrCls valueForKey:@"shared"];
    }
    if (outDockMgr) *outDockMgr = dockMgr;

    // 1. 检查 @objc public var windowHostingView (VirtualWindowsHostView) 是否有运行中的多任务子窗口
    if (dockMgr) {
        @try {
            UIView *hostView = [dockMgr valueForKey:@"windowHostingView"];
            if ([hostView isKindOfClass:[UIView class]] && hostView.subviews.count > 0) {
                return YES;
            }
        } @catch (__unused NSException *e) {}
    }

    // 2. 检查 @objc class func MultitaskManager.isMultitasking()
    SEL isMultiSel = NSSelectorFromString(@"isMultitasking");
    if (multitaskMgrCls && [multitaskMgrCls respondsToSelector:isMultiSel]) {
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        if (fn(multitaskMgrCls, isMultiSel)) {
            return YES;
        }
    }

    return NO;
}

static void (*orig_Window_didAddSubview)(id, SEL, UIView *) = NULL;

static void hook_Window_didAddSubview(UIWindow *self, SEL _cmd, UIView *subview) {
    if (orig_Window_didAddSubview) {
        orig_Window_didAddSubview(self, _cmd, subview);
    } else {
        struct objc_super sup = { self, [UIView class] };
        ((void (*)(struct objc_super *, SEL, UIView *))objc_msgSendSuper)(&sup, _cmd, subview);
    }
    if (!LCIsLiveContainerHostProcess() || !subview) return;
    if ([subview isKindOfClass:[LCSwitcherPassthroughView class]]) return;
    if (subview == self.rootViewController.view) return;
    Class virtualHostCls = NSClassFromString(@"VirtualWindowsHostView");
    if (virtualHostCls && [subview isKindOfClass:virtualHostCls]) return;

    NSString *subClsName = NSStringFromClass([subview class]);
    if ([subClsName containsString:@"UIHostingView"]) {
        CGFloat screenW = MAX(self.bounds.size.width, 1.0);
        if (subview.bounds.size.width <= screenW * 0.55) {
            // 第一时间同步隐藏，避免原生多任务 Dock 闪现
            subview.hidden = YES;
            subview.alpha = 0.0;
            subview.userInteractionEnabled = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                subview.hidden = YES;
                subview.alpha = 0.0;
                subview.userInteractionEnabled = NO;
            });
        }
    }
}

static void LCInstallMultitaskSidebarReplacementHooksIfNeeded(void) {
    if (LCIsMultitaskExtensionProcess()) return;
    if ([LCSwitcher isContainerGuestRunning]) return;
    if (!LCIsLiveContainerHostProcess()) return;
    if (gMultitaskHooksInstalled) return;
    gMultitaskHooksInstalled = YES;

    // 仅给 UIWindow 自身添加 didAddSubview:，第一时间拦截原版 Dock 浮层（不修改 UIView 基类）
    SEL didAddSel = @selector(didAddSubview:);
    if (!class_addMethod([UIWindow class], didAddSel, (IMP)hook_Window_didAddSubview, "v@:@")) {
        Method m = class_getInstanceMethod([UIWindow class], didAddSel);
        if (m && method_getImplementation(m) != (IMP)hook_Window_didAddSubview) {
            orig_Window_didAddSubview = (void (*)(id, SEL, UIView *))method_setImplementation(m, (IMP)hook_Window_didAddSubview);
        }
    }

    // 延时 0.8 秒待宿主就绪后启动 0.15s 轻量级多任务状态同步
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        static NSTimer *sHostMultitaskSyncTimer = nil;
        if (sHostMultitaskSyncTimer) return;
        sHostMultitaskSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (LCIsMultitaskExtensionProcess() || [LCSwitcher isContainerGuestRunning]) {
                [timer invalidate];
                sHostMultitaskSyncTimer = nil;
                return;
            }
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                return;
            }
            id dockMgr = nil;
            BOOL hasMultitask = LCIsHostCurrentlyMultitasking(&dockMgr);
            if (hasMultitask) {
                LCHideLCMultitaskDockWindow(dockMgr);
                LCActivateMultitaskHostSwitcherIfNeeded(YES);
                // 若当前处于全局完全全屏（isCollapsed），新拉起的子进程也自动进入最大化完全全屏
                BOOL collapsed = NO;
                @try { collapsed = [[dockMgr valueForKey:@"isCollapsed"] boolValue]; } @catch (__unused NSException *e) {}
                if (collapsed) {
                    LCSwitcher *mgr = [LCSwitcher sharedManager];
                    for (UIViewController *dvc in [mgr.overlayController allActiveDecoratedSceneVCs]) {
                        @try {
                            BOOL isMax = [[dvc valueForKey:@"isMaximized"] boolValue];
                            if (!isMax && [dvc respondsToSelector:NSSelectorFromString(@"maximizeWindow")]) {
                                [dvc performSelector:NSSelectorFromString(@"maximizeWindow")];
                            }
                        } @catch (__unused NSException *e) {}
                    }
                }
            } else if (gIsMultitaskHostMode) {
                LCActivateMultitaskHostSwitcherIfNeeded(NO);
            }
        }];
    });
}

// MARK: - 动态库构造器入口 (自动监听生命周期 + dlopen 延迟注入立即挂载)

__attribute__((constructor)) static void LCSwitcherInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            LCInstallMultitaskSidebarReplacementHooksIfNeeded();
            [LCSwitcher setupIfNeeded];
        });

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            LCInstallMultitaskSidebarReplacementHooksIfNeeded();
            [LCSwitcher setupIfNeeded];
        }];

        [nc addObserverForName:UISceneWillConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            LCInstallMultitaskSidebarReplacementHooksIfNeeded();
            [LCSwitcher setupIfNeeded];
        }];

        [nc addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            LCInstallMultitaskSidebarReplacementHooksIfNeeded();
            [LCSwitcher setupIfNeeded];
        }];
    }
}
