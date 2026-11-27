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

static id _Nullable LCGnoixBridge(void) {
    Class bridgeCls = NSClassFromString(@"GnoixMultitaskBridge");
    if (!bridgeCls) bridgeCls = NSClassFromString(@"GnoixHostUI.GnoixMultitaskBridge");
    if (!bridgeCls) bridgeCls = NSClassFromString(@"Gnoix.GnoixMultitaskBridge");
    if (bridgeCls && [bridgeCls respondsToSelector:@selector(shared)]) {
        return [bridgeCls valueForKey:@"shared"];
    }
    return nil;
}

static BOOL LCIsLiveContainerHostProcess(void) {
    if (LCIsMultitaskExtensionProcess()) return NO;
    NSString *bundlePath = [NSBundle mainBundle].bundlePath ?: @"";
    if ([bundlePath containsString:@"/Documents/Applications/"]) {
        return NO;
    }
    if (LCGnoixBridge() != nil ||
        NSClassFromString(@"DecoratedAppSceneViewController") != nil ||
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

static NSString *const LCSwitcherConfigDidChangeNotification = @"LCSwitcherConfigDidChangeNotification";

static NSString *LCSharedConfigPath(void) {
    NSString *docs = [LCSwitcher realHostDocumentsDirectory];
    if (!docs.length) return nil;
    NSString *dir = [docs stringByAppendingPathComponent:@"MultitaskControl"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"lcswitcher_config.plist"];
}

static NSDictionary *LCLoadSharedConfig(void) {
    NSString *path = LCSharedConfigPath();
    if (path.length) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            return dict;
        }
    }
    return @{};
}

static void LCSaveSharedConfigDict(NSDictionary *updates) {
    NSString *path = LCSharedConfigPath();
    if (!path.length) return;
    NSMutableDictionary *merged = [LCLoadSharedConfig() mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:updates];
    [merged writeToFile:path atomically:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:LCSwitcherConfigDidChangeNotification object:nil];
}

static void LCSaveSharedConfig(NSString *sidebarStyle, NSString *beadStyle, double collapsedOpacity, BOOL defaultFollowRotate) {
    double clamped = fmin(fmax(collapsedOpacity, 0.4), 1.0);
    LCSaveSharedConfigDict(@{
        @"sidebarStyle": sidebarStyle ?: @"floatingBead",
        @"beadStyle": beadStyle ?: @"minimalLine",
        @"collapsedOpacity": @(clamped),
        @"defaultFollowSystemOrientation": @(defaultFollowRotate)
    });
}

static NSUInteger LCSharedGridColumns(void) {
    NSNumber *n = LCLoadSharedConfig()[@"gridColumns"];
    if ([n isKindOfClass:[NSNumber class]]) {
        NSUInteger v = n.unsignedIntegerValue;
        if (v == 1 || v == 3 || v == 4 || v == 5) return v;
    }
    // 默认采用精致单列玻璃卡片列表（告别拥挤的 4 列小图标），支持在设置中自由切换 列表 / 3列 / 4列 / 5列
    return 1;
}

static BOOL LCSharedShowAppNames(void) {
    NSNumber *n = LCLoadSharedConfig()[@"showAppNames"];
    if ([n isKindOfClass:[NSNumber class]]) {
        return n.boolValue;
    }
    return YES;
}

static NSArray<NSString *> *LCSharedPinnedFolders(void) {
    NSArray *arr = LCLoadSharedConfig()[@"pinnedFolders"];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

static void LCTogglePinnedFolder(NSString *folderName) {
    if (!folderName.length) return;
    NSMutableArray<NSString *> *pinned = [LCSharedPinnedFolders() mutableCopy];
    if ([pinned containsObject:folderName]) {
        [pinned removeObject:folderName];
    } else {
        [pinned insertObject:folderName atIndex:0];
    }
    LCSaveSharedConfigDict(@{@"pinnedFolders": pinned});
}

static NSString *LCSharedSidebarStyle(void) {
    NSString *s = LCLoadSharedConfig()[@"sidebarStyle"];
    if ([s isEqualToString:@"edgeSwipe"]) return @"edgeSwipe";
    return @"floatingBead";
}

static NSString *LCSharedBeadStyle(void) {
    NSString *s = LCLoadSharedConfig()[@"beadStyle"];
    if (s.length) return s;
    return @"minimalLine";
}

static CGFloat LCSharedCollapsedOpacity(void) {
    NSNumber *n = LCLoadSharedConfig()[@"collapsedOpacity"];
    if ([n isKindOfClass:[NSNumber class]]) {
        return (CGFloat)fmin(fmax(n.doubleValue, 0.4), 1.0);
    }
    return 0.80;
}

static BOOL LCSharedDefaultFollowSystemOrientation(void) {
    NSNumber *n = LCLoadSharedConfig()[@"defaultFollowSystemOrientation"];
    if ([n isKindOfClass:[NSNumber class]]) {
        return n.boolValue;
    }
    return YES;
}

static BOOL LCLoadForceAutoRotateForFolder(NSString *folderName) {
    NSString *key = LCForceAutoRotateKeyForFolder(folderName);
    id val = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return val ? [val boolValue] : LCSharedDefaultFollowSystemOrientation();
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
- (void)applyBeadStyle:(NSString *)style;

@end

@implementation LCSwitcherBeadView {
    UIView *_grabberBarView;
    BOOL _didTriggerSwipeOpen;
    NSString *_currentBeadStyle;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isPinnedRight = YES;
        [self setupUI];
    }
    return self;
}

- (void)setIsPinnedRight:(BOOL)isPinnedRight {
    if (_isPinnedRight != isPinnedRight) {
        _isPinnedRight = isPinnedRight;
        [self setNeedsLayout];
    }
}

- (void)setupUI {
    self.clipsToBounds = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.004];
    self.autoresizingMask = UIViewAutoresizingNone;

    // 极简贴边光条（与多任务折叠微珠 1:1 一致，无厚重毛玻璃灰壳）
    _grabberBarView = [[UIView alloc] initWithFrame:CGRectZero];
    _grabberBarView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.84];
    _grabberBarView.layer.cornerRadius = 2.25;
    _grabberBarView.layer.cornerCurve = kCACornerCurveContinuous;
    _grabberBarView.layer.shadowColor = [UIColor blackColor].CGColor;
    _grabberBarView.layer.shadowOpacity = 0.36;
    _grabberBarView.layer.shadowRadius = 3.5;
    _grabberBarView.layer.shadowOffset = CGSizeZero;
    _grabberBarView.userInteractionEnabled = NO;
    [self addSubview:_grabberBarView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];

    // 普通轻滑仅用于向内呼出抽屉，绝不位移微珠
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    // 按住 0.5 秒后解锁拖动位移
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPressMove:)];
    longPress.minimumPressDuration = 0.5;
    longPress.cancelsTouchesInView = YES;
    [self addGestureRecognizer:longPress];
}

- (void)applyBeadStyle:(NSString *)style {
    _currentBeadStyle = style.length ? [style copy] : @"minimalLine";
    NSMutableArray<CALayer *> *toRemove = [NSMutableArray array];
    for (CALayer *sub in _grabberBarView.layer.sublayers) {
        if ([sub.name isEqualToString:@"lcBeadGrad"]) {
            [toRemove addObject:sub];
        }
    }
    for (CALayer *sub in toRemove) {
        [sub removeFromSuperlayer];
    }
    _grabberBarView.layer.borderWidth = 0.0;

    if ([_currentBeadStyle isEqualToString:@"glassCapsule"]) {
        _grabberBarView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.62];
        _grabberBarView.layer.cornerRadius = 6.0;
    } else if ([_currentBeadStyle isEqualToString:@"neonGlow"]) {
        _grabberBarView.backgroundColor = [UIColor clearColor];
        _grabberBarView.layer.cornerRadius = 3.0;
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.name = @"lcBeadGrad";
        grad.frame = CGRectIsEmpty(_grabberBarView.bounds) ? CGRectMake(0, 0, 4.5, 52.0) : _grabberBarView.bounds;
        grad.colors = @[(__bridge id)[UIColor systemCyanColor].CGColor, (__bridge id)[UIColor systemPurpleColor].CGColor];
        grad.startPoint = CGPointMake(0.5, 0.0);
        grad.endPoint = CGPointMake(0.5, 1.0);
        grad.cornerRadius = 3.0;
        [_grabberBarView.layer insertSublayer:grad atIndex:0];
    } else if ([_currentBeadStyle isEqualToString:@"obsidianDot"]) {
        _grabberBarView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.80];
        _grabberBarView.layer.cornerRadius = 9.0;
    } else if ([_currentBeadStyle isEqualToString:@"auroraPill"]) {
        _grabberBarView.backgroundColor = [UIColor clearColor];
        _grabberBarView.layer.cornerRadius = 5.0;
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.name = @"lcBeadGrad";
        grad.frame = CGRectIsEmpty(_grabberBarView.bounds) ? CGRectMake(0, 0, 4.5, 52.0) : _grabberBarView.bounds;
        grad.colors = @[
            (__bridge id)[UIColor colorWithRed:0.30 green:0.65 blue:1.0 alpha:0.85].CGColor,
            (__bridge id)[UIColor colorWithRed:0.58 green:0.40 blue:1.0 alpha:0.85].CGColor
        ];
        grad.startPoint = CGPointMake(0.0, 0.0);
        grad.endPoint = CGPointMake(1.0, 1.0);
        grad.cornerRadius = 5.0;
        [_grabberBarView.layer insertSublayer:grad atIndex:0];
    } else {
        // minimalLine（默认：灵动液态半胶囊耳翼）
        _grabberBarView.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:0.62];
        _grabberBarView.layer.shadowColor = [UIColor blackColor].CGColor;
        _grabberBarView.layer.shadowOpacity = 0.28;
        _grabberBarView.layer.shadowRadius = 6.0;
        _grabberBarView.layer.shadowOffset = CGSizeZero;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // 纤细悬浮胶囊微珠：不贴死边缘，全圆角纤细形态，居中柔光核心
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat pillW = MIN(MAX(w, 6.0), 8.0);
    CGFloat pillH = MIN(h, 60.0);
    CGFloat pillX = (w - pillW) * 0.5;
    CGFloat pillY = (h - pillH) * 0.5;
    _grabberBarView.frame = CGRectMake(pillX, pillY, pillW, pillH);
    _grabberBarView.layer.cornerRadius = pillW * 0.5;
    _grabberBarView.layer.cornerCurve = kCACornerCurveContinuous;
    _grabberBarView.layer.maskedCorners = (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);

    // 居中纤细发光内芯
    UIView *innerGlow = [_grabberBarView viewWithTag:9091];
    if (!innerGlow) {
        innerGlow = [[UIView alloc] init];
        innerGlow.tag = 9091;
        innerGlow.userInteractionEnabled = NO;
        innerGlow.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.90];
        innerGlow.layer.cornerRadius = 1.25;
        [_grabberBarView addSubview:innerGlow];
    }
    CGFloat glowW = 2.5;
    CGFloat glowH = 30.0;
    innerGlow.frame = CGRectMake((pillW - glowW) * 0.5, (pillH - glowH) * 0.5, glowW, glowH);

    for (CALayer *sub in _grabberBarView.layer.sublayers) {
        if ([sub.name isEqualToString:@"lcBeadGrad"]) {
            sub.frame = _grabberBarView.bounds;
            sub.cornerRadius = _grabberBarView.layer.cornerRadius;
        }
    }
    [CATransaction commit];
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
        case UIGestureRecognizerStateBegan:
            _didTriggerSwipeOpen = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            if (_didTriggerSwipeOpen) return;
            CGPoint translation = [gesture translationInView:superview];
            CGPoint velocity = [gesture velocityInView:superview];
            BOOL swipedInward = self.isPinnedRight
                ? (translation.x < -14.0 || velocity.x < -120.0)
                : (translation.x > 14.0 || velocity.x > 120.0);
            if (swipedInward) {
                _didTriggerSwipeOpen = YES;
                if (self.onSwipeToOpen) {
                    self.onSwipeToOpen();
                } else if (self.onTap) {
                    self.onTap();
                }
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            _didTriggerSwipeOpen = NO;
            break;
        default:
            break;
    }
}

- (void)handleLongPressMove:(UILongPressGestureRecognizer *)gesture {
    if (self.onUserInteraction) self.onUserInteraction();
    UIView *superview = self.superview;
    if (!superview) return;
    CGPoint loc = [gesture locationInView:superview];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            [UIView animateWithDuration:0.16 animations:^{
                self.transform = CGAffineTransformMakeScale(1.18, 1.12);
                self.alpha = 1.0;
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            self.center = loc;
            if (self.onPanMoved) self.onPanMoved(loc);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
                self.transform = CGAffineTransformIdentity;
            } completion:nil];
            if (self.onPanEnded) self.onPanEnded(self.center);
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
        id gnoix = LCGnoixBridge();
        if (gnoix) {
            @try { return [[gnoix valueForKey:@"isFocusedInPiP"] boolValue]; } @catch (__unused NSException *e) {}
        }
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
        id gnoix = LCGnoixBridge();
        if (gnoix) {
            SEL toggleSel = NSSelectorFromString(@"toggleFocusedPiP");
            if ([gnoix respondsToSelector:toggleSel]) {
                ((void (*)(id, SEL))objc_msgSend)(gnoix, toggleSel);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    BOOL activeNow = NO;
                    @try { activeNow = [[gnoix valueForKey:@"isFocusedInPiP"] boolValue]; } @catch (__unused NSException *e) {}
                    if (completion) completion(activeNow, nil);
                });
                return;
            }
        }
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
@property (nonatomic, copy, nullable) void (^onOpenSettings)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onUserInteraction)(void);

- (void)reloadWithApps:(NSArray<LCSwitcherAppInfo *> *)apps runningFolder:(NSString *)runningFolder foregroundUUID:(nullable NSString *)foregroundUUID runningUUIDs:(nullable NSSet<NSString *> *)runningUUIDs;
- (void)playEntranceWaveFromRight:(BOOL)fromRight;
- (void)setAutoRotateEnabled:(BOOL)enabled;
- (void)setAutoRotateRowHidden:(BOOL)hidden;
- (void)setScreenScale:(CGFloat)scale;
- (void)setPiPActive:(BOOL)active;
- (void)setTrueFullscreenActive:(BOOL)active;

@end

@implementation LCSwitcherDrawerView {
    UIVisualEffectView *_blurView;
    CAGradientLayer *_glassSheenLayer;
    UIView *_headerView;
    UIView *_statusPill;
    UIView *_statusDot;
    UILabel *_titleLabel;
    UILabel *_countBadge;
    UIButton *_gridToggleButton;
    UIButton *_closeButton;
    UIView *_gridTrayView;
    UIView *_controlsPanel;
    UIStackView *_controlsStack;
    UIView *_scalePopoverBar;
    BOOL _isScalePopoverOpen;
    UIView *_bottomDockContainer;
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
    UIButton *_settingsActionButton;
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

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glassSheenLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)setupUI {
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:0.32];
    self.autoresizingMask = UIViewAutoresizingNone;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blurView];

    // Liquid Glass 顶部高光漫反射层
    _glassSheenLayer = [CAGradientLayer layer];
    _glassSheenLayer.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.06].CGColor
    ];
    _glassSheenLayer.locations = @[@0.0, @0.38, @1.0];
    _glassSheenLayer.startPoint = CGPointMake(0.1, 0.0);
    _glassSheenLayer.endPoint = CGPointMake(0.9, 1.0);
    [self.layer addSublayer:_glassSheenLayer];

    self.layer.cornerRadius = 28.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.35;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.42;
    self.layer.shadowRadius = 26.0;
    self.layer.shadowOffset = CGSizeMake(0, 10);

    // 1. 极简无顶栏、无中间嵌套层设计：应用卡片直接铺陈在液态玻璃面板内，干脆通透
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.contentInset = UIEdgeInsetsMake(4.0, 0, 6.0, 0);
    [self addSubview:_scrollView];

    _stackView = [[UIStackView alloc] init];
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.spacing = 10.0;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.distribution = UIStackViewDistributionFill;
    [_scrollView addSubview:_stackView];

    [self setupControlsPanel];
    [self addSubview:_controlsPanel];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
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
    btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.09];
    btn.layer.cornerRadius = 14.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.layer.borderWidth = 0.0;
    btn.accessibilityLabel = title;
    [btn addTarget:self action:@selector(handleTileTouchDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:self action:@selector(handleTileTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16.5 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.userInteractionEnabled = NO;
    iv.tintColor = tintColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [btn addSubview:iv];

    if (outTitleLabel) *outTitleLabel = nil;

    [NSLayoutConstraint activateConstraints:@[
        [btn.heightAnchor constraintEqualToConstant:40.0],
        [iv.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:20.0],
        [iv.heightAnchor constraintEqualToConstant:20.0]
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
    _scalePopoverBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    _scalePopoverBar.layer.cornerRadius = 14.0;
    _scalePopoverBar.layer.cornerCurve = kCACornerCurveContinuous;
    _scalePopoverBar.layer.borderWidth = 0.0;
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

    // 快捷缩放预设胶囊（75% · 85% · 100% · 125%）
    UIStackView *presetStack = [[UIStackView alloc] init];
    presetStack.translatesAutoresizingMaskIntoConstraints = NO;
    presetStack.axis = UILayoutConstraintAxisHorizontal;
    presetStack.spacing = 6.0;
    presetStack.distribution = UIStackViewDistributionFillEqually;
    [_scalePopoverBar addSubview:presetStack];

    NSArray<NSNumber *> *presets = @[@(0.75), @(0.85), @(1.00), @(1.25)];
    for (NSNumber *p in presets) {
        UIButton *pBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        pBtn.tag = (NSInteger)llround(p.doubleValue * 100.0);
        [pBtn setTitle:[NSString stringWithFormat:@"%ld%%", (long)pBtn.tag] forState:UIControlStateNormal];
        [pBtn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.90] forState:UIControlStateNormal];
        pBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
        pBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        pBtn.layer.cornerRadius = 7.0;
        pBtn.layer.cornerCurve = kCACornerCurveContinuous;
        [pBtn addTarget:self action:@selector(handleScalePresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetStack addArrangedSubview:pBtn];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_scalePopoverBar.heightAnchor constraintEqualToConstant:70.0],
        [minLbl.leadingAnchor constraintEqualToAnchor:_scalePopoverBar.leadingAnchor constant:10.0],
        [minLbl.topAnchor constraintEqualToAnchor:_scalePopoverBar.topAnchor constant:12.0],
        [_scaleValueBadge.trailingAnchor constraintEqualToAnchor:_scalePopoverBar.trailingAnchor constant:-8.0],
        [_scaleValueBadge.centerYAnchor constraintEqualToAnchor:minLbl.centerYAnchor],
        [_scaleValueBadge.widthAnchor constraintEqualToConstant:44.0],
        [_scaleValueBadge.heightAnchor constraintEqualToConstant:22.0],
        [_scaleSlider.leadingAnchor constraintEqualToAnchor:minLbl.trailingAnchor constant:6.0],
        [_scaleSlider.trailingAnchor constraintEqualToAnchor:_scaleValueBadge.leadingAnchor constant:-8.0],
        [_scaleSlider.centerYAnchor constraintEqualToAnchor:minLbl.centerYAnchor],

        [presetStack.leadingAnchor constraintEqualToAnchor:_scalePopoverBar.leadingAnchor constant:8.0],
        [presetStack.trailingAnchor constraintEqualToAnchor:_scalePopoverBar.trailingAnchor constant:-8.0],
        [presetStack.bottomAnchor constraintEqualToAnchor:_scalePopoverBar.bottomAnchor constant:-7.0],
        [presetStack.heightAnchor constraintEqualToConstant:24.0]
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

    _settingsActionButton = [self createBottomActionButtonWithSymbol:@"slider.horizontal.3"
                                                               title:@"微珠"
                                                               tint:[UIColor colorWithRed:0.78 green:0.84 blue:1.0 alpha:1.0]
                                                          titleLabel:nil
                                                              action:@selector(handleOpenSettingsTapped)];
    [_bottomButtonsStack addArrangedSubview:_settingsActionButton];
}

- (void)handleOpenSettingsTapped {
    if (self.onUserInteraction) self.onUserInteraction();
    if (self.onOpenSettings) self.onOpenSettings();
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
    _pipActionButton.hidden = !hidden;
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

- (void)handleScalePresetTapped:(UIButton *)sender {
    if (self.onUserInteraction) self.onUserInteraction();
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    CGFloat val = (CGFloat)sender.tag / 100.0;
    _scaleSlider.value = (float)val;
    [self updateScaleBadge:val];
    if (self.onChangeScreenScale) {
        self.onChangeScreenScale(val);
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
    if (gIsMultitaskHostMode) {
        NSUInteger activeCount = runningUUIDs.count;
        _titleLabel.text = activeCount > 0 ? [NSString stringWithFormat:@"多任务 · 运行中 %lu", (unsigned long)activeCount] : @"多任务切换";
    } else {
        NSString *display = runningFolder.length ? [runningFolder stringByDeletingPathExtension] : @"单开切换";
        _titleLabel.text = display;
    }
    _countBadge.text = [NSString stringWithFormat:@" %lu ", (unsigned long)apps.count];

    for (UIView *sub in [_stackView.arrangedSubviews copy]) {
        [_stackView removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    // 排序优先级（参考 LCGridLayout）：前台运行 → 后台运行 → 用户置顶收藏 → 其余应用
    NSArray<NSString *> *pinnedFolders = LCSharedPinnedFolders();
    NSArray<LCSwitcherAppInfo *> *orderedApps = apps;
    if (apps.count > 1) {
        orderedApps = [apps sortedArrayUsingComparator:^NSComparisonResult(LCSwitcherAppInfo *a, LCSwitcherAppInfo *b) {
            int rankA = 3;
            int rankB = 3;
            if (gIsMultitaskHostMode) {
                if (foregroundUUID.length && [a.dataUUID isEqualToString:foregroundUUID]) rankA = 0;
                else if ([runningUUIDs containsObject:a.dataUUID]) rankA = 1;
                else if ([pinnedFolders containsObject:a.folderName]) rankA = 2;

                if (foregroundUUID.length && [b.dataUUID isEqualToString:foregroundUUID]) rankB = 0;
                else if ([runningUUIDs containsObject:b.dataUUID]) rankB = 1;
                else if ([pinnedFolders containsObject:b.folderName]) rankB = 2;
            } else {
                if (runningFolder.length && [a.folderName isEqualToString:runningFolder]) rankA = 0;
                else if ([pinnedFolders containsObject:a.folderName]) rankA = 2;

                if (runningFolder.length && [b.folderName isEqualToString:runningFolder]) rankB = 0;
                else if ([pinnedFolders containsObject:b.folderName]) rankB = 2;
            }
            if (rankA != rankB) return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
            if (rankA == 2 && rankB == 2) {
                NSUInteger idxA = [pinnedFolders indexOfObject:a.folderName];
                NSUInteger idxB = [pinnedFolders indexOfObject:b.folderName];
                if (idxA != idxB) return idxA < idxB ? NSOrderedAscending : NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
    }

    const NSUInteger columns = LCSharedGridColumns();
    const BOOL showNames = LCSharedShowAppNames();
    NSUInteger count = orderedApps.count;

    if (columns == 1) {
        // 精致单列液态玻璃卡片列表（VisionOS / iOS 26 悬浮侧边栏质感）
        _stackView.spacing = 7.0;
        for (NSUInteger i = 0; i < count; i++) {
            LCSwitcherAppInfo *app = orderedApps[i];
            BOOL isForeground = NO;
            BOOL isRunning = NO;
            if (gIsMultitaskHostMode) {
                isForeground = (foregroundUUID.length > 0 && app.dataUUID.length > 0 && [app.dataUUID isEqualToString:foregroundUUID]);
                isRunning = isForeground || (app.dataUUID.length > 0 && [runningUUIDs containsObject:app.dataUUID]);
            } else {
                isForeground = (runningFolder.length > 0 && [app.folderName isEqualToString:runningFolder]);
                isRunning = isForeground;
            }
            BOOL isPinned = [pinnedFolders containsObject:app.folderName];
            UIView *rowCard = [self createGlassListRowWithApp:app isForeground:isForeground isRunning:isRunning isPinned:isPinned];
            [_stackView addArrangedSubview:rowCard];
        }
    } else {
        _stackView.spacing = 11.0;
        for (NSUInteger i = 0; i < count; i += columns) {
            UIStackView *rowStack = [[UIStackView alloc] init];
            rowStack.axis = UILayoutConstraintAxisHorizontal;
            rowStack.spacing = (columns == 5) ? 5.0 : 8.0;
            rowStack.alignment = UIStackViewAlignmentTop;
            rowStack.distribution = UIStackViewDistributionFillEqually;

            for (NSUInteger c = 0; c < columns; c++) {
                NSUInteger idx = i + c;
                if (idx < count) {
                    LCSwitcherAppInfo *app = orderedApps[idx];
                    BOOL isForeground = NO;
                    BOOL isRunning = NO;
                    if (gIsMultitaskHostMode) {
                        isForeground = (foregroundUUID.length > 0 && app.dataUUID.length > 0 && [app.dataUUID isEqualToString:foregroundUUID]);
                        isRunning = isForeground || (app.dataUUID.length > 0 && [runningUUIDs containsObject:app.dataUUID]);
                    } else {
                        isForeground = (runningFolder.length > 0 && [app.folderName isEqualToString:runningFolder]);
                        isRunning = isForeground;
                    }
                    BOOL isPinned = [pinnedFolders containsObject:app.folderName];
                    UIView *tile = [self createAppTileWithApp:app isForeground:isForeground isRunning:isRunning isPinned:isPinned columns:columns showName:showNames];
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
}

- (void)playEntranceWaveFromRight:(BOOL)fromRight {
    NSArray<UIView *> *rows = _stackView.arrangedSubviews;
    CGFloat dx = fromRight ? 18.0 : -18.0;
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *row = rows[i];
        row.alpha = 0.0;
        row.transform = CGAffineTransformConcat(
            CGAffineTransformMakeScale(0.93, 0.93),
            CGAffineTransformMakeTranslation(dx, 4.0)
        );
        NSTimeInterval delay = MIN(i * 0.022, 0.18);
        [UIView animateWithDuration:0.34
                              delay:delay
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.65
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            row.alpha = 1.0;
            row.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (UIView *)createGlassListRowWithApp:(LCSwitcherAppInfo *)app isForeground:(BOOL)isForeground isRunning:(BOOL)isRunning isPinned:(BOOL)isPinned {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.borderWidth = 0.0;
    if (isForeground) {
        card.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.42 alpha:0.18];
    } else if (isRunning) {
        card.backgroundColor = [UIColor colorWithRed:0.24 green:0.66 blue:1.0 alpha:0.13];
    } else {
        card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
    }
    card.layer.cornerRadius = 15.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIImage *rawIcon = app.icon ?: [UIImage systemImageNamed:@"app.fill"];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:rawIcon];
    iconView.alpha = isRunning ? 1.0 : 0.90;
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 9.5;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.layer.borderWidth = 0.0;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    [card addSubview:iconView];

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1.5;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = app.name;
    nameLabel.font = [UIFont systemFontOfSize:13.5 weight:(isForeground ? UIFontWeightBold : UIFontWeightSemibold)];
    nameLabel.textColor = isRunning ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.86];
    nameLabel.numberOfLines = 1;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    UILabel *subLabel = [[UILabel alloc] init];
    if (isForeground) {
        subLabel.text = @"前台运行中";
        subLabel.textColor = [UIColor colorWithRed:0.35 green:0.95 blue:0.56 alpha:0.95];
    } else if (isRunning) {
        subLabel.text = @"后台运行中";
        subLabel.textColor = [UIColor colorWithRed:0.46 green:0.84 blue:1.0 alpha:0.92];
    } else if (isPinned) {
        subLabel.text = @"已置顶 · 轻点启动";
        subLabel.textColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.36 alpha:0.88];
    } else {
        subLabel.text = @"轻点启动";
        subLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    }
    subLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    subLabel.numberOfLines = 1;

    [textStack addArrangedSubview:nameLabel];
    [textStack addArrangedSubview:subLabel];
    [card addSubview:textStack];

    UIView *trailingView = nil;
    if (isForeground || isRunning) {
        UIView *dot = [[UIView alloc] init];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        dot.userInteractionEnabled = NO;
        UIColor *dotColor = isForeground
            ? [UIColor colorWithRed:0.24 green:0.94 blue:0.48 alpha:1.0]
            : [UIColor colorWithRed:0.36 green:0.80 blue:1.0 alpha:1.0];
        dot.backgroundColor = dotColor;
        dot.layer.cornerRadius = 4.5;
        dot.layer.shadowColor = dotColor.CGColor;
        dot.layer.shadowRadius = 5.0;
        dot.layer.shadowOpacity = 0.9;
        dot.layer.shadowOffset = CGSizeZero;
        if (isForeground) {
            // 前台活跃应用呼吸脉冲光效
            CABasicAnimation *pulseScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            pulseScale.fromValue = @0.92;
            pulseScale.toValue = @1.32;
            pulseScale.duration = 1.15;
            pulseScale.autoreverses = YES;
            pulseScale.repeatCount = HUGE_VALF;
            pulseScale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [dot.layer addAnimation:pulseScale forKey:@"lcBreathScale"];

            CABasicAnimation *pulseOpacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulseOpacity.fromValue = @1.0;
            pulseOpacity.toValue = @0.55;
            pulseOpacity.duration = 1.15;
            pulseOpacity.autoreverses = YES;
            pulseOpacity.repeatCount = HUGE_VALF;
            [dot.layer addAnimation:pulseOpacity forKey:@"lcBreathOpacity"];
        }
        [card addSubview:dot];
        [NSLayoutConstraint activateConstraints:@[
            [dot.widthAnchor constraintEqualToConstant:9.0],
            [dot.heightAnchor constraintEqualToConstant:9.0]
        ]];
        trailingView = dot;
    } else if (isPinned) {
        UIImageSymbolConfiguration *pinCfg = [UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *pinIv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill" withConfiguration:pinCfg]];
        pinIv.translatesAutoresizingMaskIntoConstraints = NO;
        pinIv.userInteractionEnabled = NO;
        pinIv.tintColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.34 alpha:0.90];
        [card addSubview:pinIv];
        trailingView = pinIv;
    } else {
        UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg]];
        chev.translatesAutoresizingMaskIntoConstraints = NO;
        chev.userInteractionEnabled = NO;
        chev.tintColor = [UIColor colorWithWhite:1.0 alpha:0.30];
        [card addSubview:chev];
        trailingView = chev;
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:52.0],
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:9.0],
        [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:35.0],
        [iconView.heightAnchor constraintEqualToConstant:35.0],

        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10.0],
        [textStack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:trailingView.leadingAnchor constant:-8.0],

        [trailingView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [trailingView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]
    ]];

    objc_setAssociatedObject(card, "LCAppInfoObject", app, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [card addTarget:self action:@selector(handleTileTouchDown:) forControlEvents:UIControlEventTouchDown];
    [card addTarget:self action:@selector(handleTileTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [card addTarget:self action:@selector(handleAppCardTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *cardLP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleAppCardLongPressed:)];
    cardLP.minimumPressDuration = 0.35;
    [card addGestureRecognizer:cardLP];
    return card;
}

- (UIView *)createAppTileWithApp:(LCSwitcherAppInfo *)app isForeground:(BOOL)isForeground isRunning:(BOOL)isRunning isPinned:(BOOL)isPinned columns:(NSUInteger)columns showName:(BOOL)showName {
    UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = [UIColor clearColor];

    CGFloat iconSide = (columns == 5) ? 38.0 : (columns == 3 ? 48.0 : 44.0);
    UIImage *rawIcon = app.icon ?: [UIImage systemImageNamed:@"app.fill"];
    UIImageView *iconView = [[UIImageView alloc] init];
    // 全彩原生图标展示（告别灰白图标），通过右上角发光状态点区分前台/后台运行态
    iconView.image = rawIcon;
    iconView.alpha = isRunning ? 1.0 : 0.90;
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = (columns == 5) ? 9.5 : 12.0;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.layer.borderWidth = isForeground ? 1.4 : 0.0;
    if (isForeground) {
        iconView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.44 alpha:0.95].CGColor;
    }
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    [tile addSubview:iconView];

    if (isForeground || isRunning) {
        UIView *statusDot = [[UIView alloc] init];
        statusDot.translatesAutoresizingMaskIntoConstraints = NO;
        statusDot.userInteractionEnabled = NO;
        statusDot.backgroundColor = isForeground
            ? [UIColor colorWithRed:0.20 green:0.90 blue:0.42 alpha:1.0]
            : [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
        statusDot.layer.cornerRadius = 4.5;
        statusDot.layer.borderWidth = 1.4;
        statusDot.layer.borderColor = [UIColor colorWithWhite:0.08 alpha:0.9].CGColor;
        [tile addSubview:statusDot];

        [NSLayoutConstraint activateConstraints:@[
            [statusDot.topAnchor constraintEqualToAnchor:iconView.topAnchor constant:-2.0],
            [statusDot.trailingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:2.0],
            [statusDot.widthAnchor constraintEqualToConstant:9.0],
            [statusDot.heightAnchor constraintEqualToConstant:9.0]
        ]];
    } else if (isPinned) {
        UIImageSymbolConfiguration *pinCfg = [UIImageSymbolConfiguration configurationWithPointSize:7.5 weight:UIImageSymbolWeightBold];
        UIImageView *pinBadge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill" withConfiguration:pinCfg]];
        pinBadge.translatesAutoresizingMaskIntoConstraints = NO;
        pinBadge.userInteractionEnabled = NO;
        pinBadge.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.28 alpha:0.95];
        [tile addSubview:pinBadge];
        [NSLayoutConstraint activateConstraints:@[
            [pinBadge.topAnchor constraintEqualToAnchor:iconView.topAnchor constant:-2.0],
            [pinBadge.trailingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:2.0],
            [pinBadge.widthAnchor constraintEqualToConstant:11.0],
            [pinBadge.heightAnchor constraintEqualToConstant:11.0]
        ]];
    }

    if (showName) {
        UILabel *nameLabel = [[UILabel alloc] init];
        nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        nameLabel.userInteractionEnabled = NO;
        nameLabel.text = app.name;
        nameLabel.font = [UIFont systemFontOfSize:(columns == 5 ? 9.5 : 10.5) weight:(isForeground ? UIFontWeightSemibold : UIFontWeightRegular)];
        nameLabel.textColor = isRunning ? [UIColor colorWithWhite:1.0 alpha:(isForeground ? 1.0 : 0.88)] : [UIColor colorWithWhite:1.0 alpha:0.52];
        nameLabel.textAlignment = NSTextAlignmentCenter;
        nameLabel.numberOfLines = 1;
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [tile addSubview:nameLabel];

        [NSLayoutConstraint activateConstraints:@[
            [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor constant:2.0],
            [iconView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
            [iconView.widthAnchor constraintEqualToConstant:iconSide],
            [iconView.heightAnchor constraintEqualToConstant:iconSide],

            [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:4.0],
            [nameLabel.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:1.0],
            [nameLabel.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-1.0],
            [nameLabel.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-2.0]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor constant:3.0],
            [iconView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
            [iconView.widthAnchor constraintEqualToConstant:iconSide],
            [iconView.heightAnchor constraintEqualToConstant:iconSide],
            [iconView.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-3.0]
        ]];
    }

    objc_setAssociatedObject(tile, "LCAppInfoObject", app, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tile addTarget:self action:@selector(handleTileTouchDown:) forControlEvents:UIControlEventTouchDown];
    [tile addTarget:self action:@selector(handleTileTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [tile addTarget:self action:@selector(handleAppCardTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *tileLP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleAppCardLongPressed:)];
    tileLP.minimumPressDuration = 0.35;
    [tile addGestureRecognizer:tileLP];
    return tile;
}

- (void)handleTileTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.10 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.91, 0.91);
    }];
}

- (void)handleTileTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        sender.transform = CGAffineTransformIdentity;
    } completion:nil];
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

// MARK: - 原生微珠设置面板 (LCSwitcherSettingsViewController)

@interface LCSwitcherSettingsViewController : UITableViewController
@end

static void LCReleaseModalHostWindowIfUnused(void);

@implementation LCSwitcherSettingsViewController {
    NSString *_sidebarStyle;
    NSString *_beadStyle;
    CGFloat _collapsedOpacity;
    BOOL _defaultFollowRotate;
    NSUInteger _gridColumns;
    BOOL _showAppNames;
    UILabel *_opacityValueLabel;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微珠与网格设置";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(handleDone)];
    _sidebarStyle = LCSharedSidebarStyle();
    _beadStyle = LCSharedBeadStyle();
    _collapsedOpacity = LCSharedCollapsedOpacity();
    _defaultFollowRotate = LCSharedDefaultFollowSystemOrientation();
    _gridColumns = LCSharedGridColumns();
    _showAppNames = LCSharedShowAppNames();
    self.tableView.allowsSelection = NO;
}

- (void)handleDone {
    [self dismissViewControllerAnimated:YES completion:^{
        LCReleaseModalHostWindowIfUnused();
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LCReleaseModalHostWindowIfUnused();
        });
    }
}

- (void)persistConfig {
    NSUInteger validCols = (_gridColumns == 1 || _gridColumns == 3 || _gridColumns == 4 || _gridColumns == 5) ? _gridColumns : 1;
    LCSaveSharedConfigDict(@{
        @"sidebarStyle": _sidebarStyle ?: @"floatingBead",
        @"beadStyle": _beadStyle ?: @"minimalLine",
        @"collapsedOpacity": @(fmin(fmax((double)_collapsedOpacity, 0.4), 1.0)),
        @"defaultFollowSystemOrientation": @(_defaultFollowRotate),
        @"gridColumns": @(validCols),
        @"showAppNames": @(_showAppNames)
    });
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)beadStyleOptions {
    return @[
        @{@"id": @"minimalLine",  @"title": @"极简光条"},
        @{@"id": @"glassCapsule", @"title": @"无框毛玻璃"},
        @{@"id": @"neonGlow",     @"title": @"青紫霓虹"},
        @{@"id": @"obsidianDot",  @"title": @"黑曜圆珠"},
        @{@"id": @"auroraPill",   @"title": @"极光液态"}
    ];
}

- (NSString *)titleForBeadStyle:(NSString *)styleId {
    for (NSDictionary<NSString *, NSString *> *opt in [[self class] beadStyleOptions]) {
        if ([opt[@"id"] isEqualToString:styleId]) return opt[@"title"];
    }
    return @"极简光条";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return [_sidebarStyle isEqualToString:@"floatingBead"] ? 3 : 1;
    }
    if (section == 1) {
        return 2;
    }
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"手势与微珠";
    if (section == 1) return @"抽屉网格布局";
    return @"单开模式";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"单任务与多任务实时共用；折叠微珠模式下按住微珠 0.5 秒可拖动位置。";
    }
    if (section == 1) {
        return @"参考 LCGridLayout：支持 4/5 列切换与隐藏应用名；抽屉内长按应用图标可置顶收藏或关闭进程。";
    }
    return @"开启后单开应用默认随系统重力感应与竖排锁自由旋转（可在抽屉内按单应用随时切换）。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"唤出方式";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"折叠微珠", @"边缘手势"]];
            seg.selectedSegmentIndex = [_sidebarStyle isEqualToString:@"edgeSwipe"] ? 1 : 0;
            [seg addTarget:self action:@selector(handleSidebarStyleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"微珠样式";
            UIButton *menuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
            cfg.title = [self titleForBeadStyle:_beadStyle];
            cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
            cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
            cfg.imagePadding = 4.0;
            cfg.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightSemibold];
            menuBtn.configuration = cfg;
            menuBtn.showsMenuAsPrimaryAction = YES;

            __weak typeof(self) weakSelf = self;
            NSMutableArray<UIAction *> *actions = [NSMutableArray array];
            for (NSDictionary<NSString *, NSString *> *opt in [[self class] beadStyleOptions]) {
                NSString *sid = opt[@"id"];
                NSString *title = opt[@"title"];
                UIAction *act = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    strongSelf->_beadStyle = sid;
                    [strongSelf persistConfig];
                    [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
                }];
                act.state = [_beadStyle isEqualToString:sid] ? UIMenuElementStateOn : UIMenuElementStateOff;
                [actions addObject:act];
            }
            menuBtn.menu = [UIMenu menuWithTitle:@"" children:actions];
            [menuBtn sizeToFit];
            cell.accessoryView = menuBtn;
        } else {
            UIStackView *vStack = [[UIStackView alloc] init];
            vStack.axis = UILayoutConstraintAxisVertical;
            vStack.spacing = 6.0;
            vStack.translatesAutoresizingMaskIntoConstraints = NO;

            UIStackView *hStack = [[UIStackView alloc] init];
            hStack.axis = UILayoutConstraintAxisHorizontal;
            UILabel *titleLbl = [[UILabel alloc] init];
            titleLbl.text = @"微珠折叠透明度";
            titleLbl.font = [UIFont systemFontOfSize:16.0];
            UILabel *valLbl = [[UILabel alloc] init];
            valLbl.text = [NSString stringWithFormat:@"%d%%", (int)lroundf((float)_collapsedOpacity * 100.0f)];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
            valLbl.textColor = [UIColor secondaryLabelColor];
            _opacityValueLabel = valLbl;
            [hStack addArrangedSubview:titleLbl];
            [hStack addArrangedSubview:valLbl];

            UISlider *slider = [[UISlider alloc] init];
            slider.minimumValue = 0.40f;
            slider.maximumValue = 1.00f;
            slider.value = (float)_collapsedOpacity;
            slider.continuous = YES;
            [slider addTarget:self action:@selector(handleOpacityChanged:) forControlEvents:UIControlEventValueChanged];

            [vStack addArrangedSubview:hStack];
            [vStack addArrangedSubview:slider];
            [cell.contentView addSubview:vStack];
            [NSLayoutConstraint activateConstraints:@[
                [vStack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
                [vStack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
                [vStack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
                [vStack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0]
            ]];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"展示样式";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"列表", @"3列", @"4列", @"5列"]];
            seg.selectedSegmentIndex = (_gridColumns == 1) ? 0 : ((_gridColumns == 3) ? 1 : ((_gridColumns == 4) ? 2 : 3));
            [seg addTarget:self action:@selector(handleGridColumnsChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
        } else {
            cell.textLabel.text = @"宫格显示应用名";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = _showAppNames;
            [sw addTarget:self action:@selector(handleShowNamesChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else {
        cell.textLabel.text = @"单开默认随系统旋转";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = _defaultFollowRotate;
        [sw addTarget:self action:@selector(handleRotateDefaultChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    return cell;
}

- (void)handleGridColumnsChanged:(UISegmentedControl *)seg {
    switch (seg.selectedSegmentIndex) {
        case 0: _gridColumns = 1; break;
        case 1: _gridColumns = 3; break;
        case 2: _gridColumns = 4; break;
        default: _gridColumns = 5; break;
    }
    [self persistConfig];
}

- (void)handleShowNamesChanged:(UISwitch *)sw {
    _showAppNames = sw.isOn;
    [self persistConfig];
}

- (void)handleSidebarStyleChanged:(UISegmentedControl *)seg {
    _sidebarStyle = (seg.selectedSegmentIndex == 1) ? @"edgeSwipe" : @"floatingBead";
    [self persistConfig];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)handleOpacityChanged:(UISlider *)slider {
    CGFloat stepped = roundf(slider.value * 20.0f) / 20.0f;
    _collapsedOpacity = stepped;
    _opacityValueLabel.text = [NSString stringWithFormat:@"%d%%", (int)lroundf((float)stepped * 100.0f)];
    [self persistConfig];
}

- (void)handleRotateDefaultChanged:(UISwitch *)sw {
    _defaultFollowRotate = sw.isOn;
    [self persistConfig];
}

@end

static UIWindow *gLCModalHostWindow = nil;

static void LCReleaseModalHostWindowIfUnused(void) {
    if (!gLCModalHostWindow) return;
    UIViewController *root = gLCModalHostWindow.rootViewController;
    if (!root.presentedViewController || root.presentedViewController.isBeingDismissed) {
        gLCModalHostWindow.hidden = YES;
        gLCModalHostWindow.rootViewController = nil;
        gLCModalHostWindow = nil;
    }
}

static UIViewController *LCEnsureTopLevelModalHostController(void) {
    UIWindowScene *activeScene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)s;
                break;
            }
            if (!activeScene) activeScene = (UIWindowScene *)s;
        }
    }
    if (!activeScene) return nil;

    if (!gLCModalHostWindow) {
        UIWindow *win = [[UIWindow alloc] initWithWindowScene:activeScene];
        win.windowLevel = UIWindowLevelAlert + 80.0;
        win.backgroundColor = [UIColor clearColor];
        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = [UIColor clearColor];
        win.rootViewController = root;
        gLCModalHostWindow = win;
    }
    gLCModalHostWindow.hidden = NO;
    [gLCModalHostWindow makeKeyAndVisible];
    UIViewController *top = gLCModalHostWindow.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

static UIViewController *LCTopMostPresenterViewController(void) {
    UIViewController *modalRoot = LCEnsureTopLevelModalHostController();
    if (modalRoot) return modalRoot;
    UIWindow *keyWin = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) {
            if (w.hidden || !w.rootViewController) continue;
            if ([NSStringFromClass([w class]) isEqualToString:@"LCSwitcherOverlayWindow"]) continue;
            if (w.isKeyWindow) { keyWin = w; break; }
            if (!keyWin) keyWin = w;
        }
        if (keyWin) break;
    }
    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

static void LCPresentBeadSettingsSheet(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = LCEnsureTopLevelModalHostController();
        if (!presenter) return;
        if ([presenter isKindOfClass:[UINavigationController class]]) {
            UIViewController *topVC = ((UINavigationController *)presenter).topViewController;
            if ([topVC isKindOfClass:[LCSwitcherSettingsViewController class]]) return;
        }
        LCSwitcherSettingsViewController *vc = [[LCSwitcherSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:nav animated:YES completion:nil];
    });
}

@interface LCSwitcherNavBarActionTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openBeadSettings;
@end

@implementation LCSwitcherNavBarActionTarget
+ (instancetype)sharedTarget {
    static LCSwitcherNavBarActionTarget *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[self alloc] init]; });
    return s;
}
- (void)openBeadSettings {
    LCPresentBeadSettingsSheet();
}
@end

static void LCInspectAndAttachNavBarSettingsButtonInVC(UIViewController *vc) {
    if (!vc) return;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        NSString *t = top.navigationItem.title.length ? top.navigationItem.title : (top.title ?: @"");
        NSString *lower = t.lowercaseString;
        if ([lower containsString:@"multitask"] || [t containsString:@"多任务"]) {
            BOOL alreadyAdded = NO;
            for (UIBarButtonItem *item in top.navigationItem.rightBarButtonItems) {
                if ([item.accessibilityIdentifier isEqualToString:@"LCSwitcherSettingsBarButton"]) {
                    alreadyAdded = YES;
                    break;
                }
            }
            if (!alreadyAdded) {
                UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"微珠设置"
                                                                        style:UIBarButtonItemStylePlain
                                                                       target:[LCSwitcherNavBarActionTarget sharedTarget]
                                                                       action:@selector(openBeadSettings)];
                btn.accessibilityIdentifier = @"LCSwitcherSettingsBarButton";
                NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithArray:top.navigationItem.rightBarButtonItems ?: @[]];
                [items addObject:btn];
                top.navigationItem.rightBarButtonItems = items;
            }
        }
    }
    if (vc.presentedViewController) {
        LCInspectAndAttachNavBarSettingsButtonInVC(vc.presentedViewController);
    }
    for (UIViewController *child in vc.childViewControllers) {
        LCInspectAndAttachNavBarSettingsButtonInVC(child);
    }
}

static void LCAttachBeadSettingsButtonToMultitaskNavBarIfNeeded(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) {
            if (w.hidden || !w.rootViewController) continue;
            if ([NSStringFromClass([w class]) isEqualToString:@"LCSwitcherOverlayWindow"]) continue;
            LCInspectAndAttachNavBarSettingsButtonInVC(w.rootViewController);
        }
    }
}

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
    UIView *_edgeSwipeView;
    NSString *_sharedSidebarStyle;
    NSString *_sharedBeadStyle;
    CGFloat _sharedCollapsedOpacity;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    _beadSize = 44.0;
    _drawerWidth = 280.0;
    _beadCenterYRatio = 0.45;
    _isBeadPinnedRight = YES;
    _sharedSidebarStyle = @"floatingBead";
    _sharedBeadStyle = @"minimalLine";
    _sharedCollapsedOpacity = 0.80;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadSharedConfig)
                                                 name:LCSwitcherConfigDidChangeNotification
                                               object:nil];

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

    if ([_sharedSidebarStyle isEqualToString:@"edgeSwipe"]) {
        if (!_edgeSwipeView.hidden && CGRectContainsPoint(_edgeSwipeView.frame, viewPoint)) {
            return _edgeSwipeView;
        }
        return nil;
    }

    CGRect beadHitFrame = CGRectInset(self.beadView.frame, -24.0, -16.0);
    if (!self.beadView.hidden && CGRectContainsPoint(beadHitFrame, viewPoint)) {
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
    self.drawerView.onOpenSettings = ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        [weakSelf setDrawerOpen:NO animated:YES];
        LCPresentBeadSettingsSheet();
    };
    self.drawerView.onLongPressApp = ^(LCSwitcherAppInfo *app) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback impactOccurred];
        if (gIsMultitaskHostMode) {
            [weakSelf closeMultitaskProcessForApp:app];
        }
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
        if (gIsMultitaskHostMode) {
            id gnoix = LCGnoixBridge();
            if (gnoix) {
                SEL scaleSel = NSSelectorFromString(@"setFocusedScale:");
                if ([gnoix respondsToSelector:scaleSel]) {
                    ((void (*)(id, SEL, CGFloat))objc_msgSend)(gnoix, scaleSel, scale);
                }
                return;
            }
        }
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
    self.beadView = [[LCSwitcherBeadView alloc] initWithFrame:CGRectMake(0, 0, 10.0, 60.0)];
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

    // 3.5 边缘手势隐形热区（唤出方式切为「边缘手势」时生效）
    _edgeSwipeView = [[UIView alloc] initWithFrame:CGRectZero];
    _edgeSwipeView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.004];
    _edgeSwipeView.userInteractionEnabled = YES;
    UIPanGestureRecognizer *edgePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdgeSwipePan:)];
    [_edgeSwipeView addGestureRecognizer:edgePan];
    [self.view addSubview:_edgeSwipeView];

    // 4. 全屏平滑过渡交接遮罩
    self.transitionOverlayView = [[LCSwitcherHandoffView alloc] initWithFrame:self.view.bounds];
    self.transitionOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.transitionOverlayView];

    [self loadSavedBeadPosition];
    [self reloadSharedConfig];
    CGSize canvasSize = (self.view.bounds.size.width > 0 && self.view.bounds.size.height > 0) ? self.view.bounds.size : [UIScreen mainScreen].bounds.size;
    [self updateLayoutForCanvasSize:canvasSize];
    [self resetInactivityTimer];
}

- (void)reloadSharedConfig {
    _sharedSidebarStyle = LCSharedSidebarStyle();
    _sharedBeadStyle = LCSharedBeadStyle();
    _sharedCollapsedOpacity = LCSharedCollapsedOpacity();
    [self.beadView applyBeadStyle:_sharedBeadStyle];
    BOOL isEdge = [_sharedSidebarStyle isEqualToString:@"edgeSwipe"];
    self.beadView.hidden = isEdge;
    _edgeSwipeView.hidden = !isEdge;
    if (!self.isDrawerOpen && !isEdge) {
        self.beadView.alpha = _sharedCollapsedOpacity;
    }
    CGSize canvasSize = (self.view.bounds.size.width > 0 && self.view.bounds.size.height > 0) ? self.view.bounds.size : [UIScreen mainScreen].bounds.size;
    [self updateLayoutForCanvasSize:canvasSize];
    if (self.isDrawerOpen) {
        [self refreshAppList];
    }
}

- (void)handleEdgeSwipePan:(UIPanGestureRecognizer *)gesture {
    if (![_sharedSidebarStyle isEqualToString:@"edgeSwipe"] || self.isDrawerOpen) return;
    if (gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded) {
        CGPoint trans = [gesture translationInView:self.view];
        CGPoint vel = [gesture velocityInView:self.view];
        BOOL swipedInward = _isBeadPinnedRight
            ? (trans.x < -16.0 || vel.x < -140.0)
            : (trans.x > 16.0 || vel.x > 140.0);
        if (swipedInward) {
            gesture.state = UIGestureRecognizerStateCancelled;
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            [self setDrawerOpen:YES animated:YES];
        }
    }
}

- (void)loadSavedBeadPosition {
    // 优先读取全局共享配置（所有单开/多任务应用共用最新微珠位置）
    NSDictionary *sharedCfg = LCLoadSharedConfig();
    NSNumber *sharedRatio = sharedCfg[@"beadCenterYRatio"];
    NSNumber *sharedPinnedRight = sharedCfg[@"beadPinnedRight"];
    if ([sharedRatio isKindOfClass:[NSNumber class]]) {
        double v = sharedRatio.doubleValue;
        if (v >= 0.0 && v <= 1.0) {
            _beadCenterYRatio = (CGFloat)v;
        }
    } else {
        double savedRatio = [[NSUserDefaults standardUserDefaults] doubleForKey:@"LCSwitcher_BeadCenterYRatio"];
        if (savedRatio > 0.1 && savedRatio < 0.9) {
            _beadCenterYRatio = (CGFloat)savedRatio;
        }
    }
    if ([sharedPinnedRight isKindOfClass:[NSNumber class]]) {
        _isBeadPinnedRight = sharedPinnedRight.boolValue;
    } else if ([[NSUserDefaults standardUserDefaults] objectForKey:@"LCSwitcher_BeadPinnedRight"]) {
        _isBeadPinnedRight = [[NSUserDefaults standardUserDefaults] boolForKey:@"LCSwitcher_BeadPinnedRight"];
    }
}

- (void)saveBeadPosition {
    // 写入全局共享配置，确保所有应用切入时统一记住最新位置
    NSString *path = LCSharedConfigPath();
    if (path.length) {
        NSMutableDictionary *merged = [LCLoadSharedConfig() mutableCopy] ?: [NSMutableDictionary dictionary];
        merged[@"beadCenterYRatio"] = @((double)_beadCenterYRatio);
        merged[@"beadPinnedRight"] = @(_isBeadPinnedRight);
        [merged writeToFile:path atomically:YES];
    }
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
    CGFloat beadW = 7.0;
    CGFloat beadH = 60.0;
    CGFloat edgeInset = 2.0;
    CGFloat usableHeight = MAX(size.height - safeTop - safeBottom - beadH, 100.0);

    CGFloat targetY = safeTop + usableHeight * _beadCenterYRatio;
    CGFloat targetX = _isBeadPinnedRight ? (size.width - beadW - edgeInset) : edgeInset;

    self.beadView.isPinnedRight = _isBeadPinnedRight;
    self.beadView.frame = CGRectMake(targetX, targetY, beadW, beadH);

    CGFloat edgeW = 24.0;
    CGFloat edgeX = _isBeadPinnedRight ? (size.width - edgeW) : 0.0;
    _edgeSwipeView.frame = CGRectMake(edgeX, safeTop + 20.0, edgeW, MAX(size.height - safeTop - safeBottom - 40.0, 120.0));

    BOOL isListMode = (LCSharedGridColumns() == 1);
    CGFloat maxDrawerH = MAX(size.height - safeTop - safeBottom - 36.0, 240.0);
    CGFloat drawerH = MIN(isListMode ? 404.0 : 368.0, maxDrawerH);
    CGFloat drawerY = safeTop + (size.height - safeTop - safeBottom - drawerH) / 2.0;
    CGFloat drawerActualW = MIN(isListMode ? 260.0 : 296.0, size.width - 28.0);

    if (self.isDrawerOpen) {
        CGFloat drawerX = _isBeadPinnedRight ? (size.width - drawerActualW - 10.0) : 10.0;
        self.drawerView.frame = CGRectMake(drawerX, drawerY, drawerActualW, drawerH);
    } else {
        CGFloat drawerHiddenX = _isBeadPinnedRight ? (size.width + 24.0) : (-drawerActualW - 24.0);
        self.drawerView.frame = CGRectMake(drawerHiddenX, drawerY, drawerActualW, drawerH);
    }
}

- (void)handleBeadPanEnded:(CGPoint)center {
    CGSize size = self.view.bounds.size;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat safeTop = insets.top > 0 ? insets.top : 44.0;
    CGFloat safeBottom = insets.bottom > 0 ? insets.bottom : 34.0;
    CGFloat beadW = 7.0;
    CGFloat beadH = 60.0;
    CGFloat edgeInset = 2.0;
    CGFloat usableHeight = MAX(size.height - safeTop - safeBottom - beadH, 100.0);

    CGFloat clampedY = MIN(MAX(center.y, safeTop + beadH / 2.0), size.height - safeBottom - beadH / 2.0);
    _beadCenterYRatio = MIN(MAX((clampedY - safeTop - beadH / 2.0) / usableHeight, 0.0), 1.0);

    _isBeadPinnedRight = (center.x >= size.width / 2.0);
    self.beadView.isPinnedRight = _isBeadPinnedRight;
    [self saveBeadPosition];

    CGFloat targetX = _isBeadPinnedRight ? (size.width - beadW - edgeInset) : edgeInset;
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
    BOOL isListMode = (LCSharedGridColumns() == 1);
    CGFloat maxDrawerH = MAX(size.height - safeTop - safeBottom - 36.0, 240.0);
    CGFloat drawerH = MIN(isListMode ? 404.0 : 368.0, maxDrawerH);
    CGFloat drawerY = safeTop + (size.height - safeTop - safeBottom - drawerH) / 2.0;
    CGFloat drawerActualW = MIN(isListMode ? 260.0 : 296.0, size.width - 28.0);

    CGFloat openX = _isBeadPinnedRight ? (size.width - drawerActualW - 10.0) : 10.0;
    CGFloat slideDeltaX = _isBeadPinnedRight ? 34.0 : -34.0;

    if (open) {
        self.drawerView.transform = CGAffineTransformIdentity;
        self.drawerView.frame = CGRectMake(openX, drawerY, drawerActualW, drawerH);
        [self.drawerView layoutIfNeeded];
        self.drawerView.alpha = 0.0;
        self.drawerView.transform = CGAffineTransformConcat(
            CGAffineTransformMakeScale(0.84, 0.88),
            CGAffineTransformMakeTranslation(slideDeltaX, 0)
        );
        [self.drawerView playEntranceWaveFromRight:_isBeadPinnedRight];
    }

    NSTimeInterval duration = animated ? (open ? 0.38 : 0.22) : 0.0;
    CGFloat damping = open ? 0.76 : 0.92;
    CGFloat velocity = open ? 0.70 : 0.30;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration
                          delay:0
         usingSpringWithDamping:damping
          initialSpringVelocity:velocity
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        weakSelf.dimmingMaskView.alpha = open ? 1.0 : 0.0;
        if (open) {
            weakSelf.drawerView.alpha = 1.0;
            weakSelf.drawerView.transform = CGAffineTransformIdentity;
            weakSelf.beadView.alpha = 0.0;
            weakSelf.beadView.transform = CGAffineTransformMakeScale(0.45, 0.45);
        } else {
            weakSelf.drawerView.alpha = 0.0;
            weakSelf.drawerView.transform = CGAffineTransformConcat(
                CGAffineTransformMakeScale(0.88, 0.90),
                CGAffineTransformMakeTranslation(slideDeltaX * 0.7, 0)
            );
            weakSelf.beadView.alpha = 1.0;
            weakSelf.beadView.transform = CGAffineTransformIdentity;
        }
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!open && strongSelf && !strongSelf.isDrawerOpen) {
            strongSelf.drawerView.transform = CGAffineTransformIdentity;
            strongSelf.drawerView.frame = CGRectMake(
                strongSelf->_isBeadPinnedRight ? (size.width + 24.0) : (-drawerActualW - 24.0),
                drawerY,
                drawerActualW,
                drawerH
            );
            [strongSelf resetInactivityTimer];
        }
    }];
}

- (void)refreshAppList {
    NSArray<LCSwitcherAppInfo *> *apps = [LCSwitcher scanInstalledApps];
    NSString *runningFolder = [LCSwitcher currentGuestFolderName];
    NSString *foregroundUUID = nil;
    NSMutableSet<NSString *> *runningUUIDs = [NSMutableSet set];
    if (gIsMultitaskHostMode) {
        id gnoix = LCGnoixBridge();
        if (gnoix) {
            @try {
                foregroundUUID = [gnoix valueForKey:@"focusedSessionUUID"];
                NSArray<NSString *> *uuids = [gnoix valueForKey:@"runningSessionUUIDs"];
                if ([uuids isKindOfClass:[NSArray class]]) {
                    [runningUUIDs addObjectsFromArray:uuids];
                }
            } @catch (__unused NSException *e) {}
        } else {
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
    }
    [self.drawerView setAutoRotateRowHidden:gIsMultitaskHostMode];
    [self.drawerView setAutoRotateEnabled:LCLoadForceAutoRotateForFolder(runningFolder)];
    CGFloat currentScale = LCLoadScreenScaleForFolder(runningFolder);
    if (gIsMultitaskHostMode) {
        id gnoix = LCGnoixBridge();
        if (gnoix) {
            @try { currentScale = (CGFloat)[[gnoix valueForKey:@"focusedScaleRatio"] doubleValue]; } @catch (__unused NSException *e) {}
        }
    }
    [self.drawerView setScreenScale:currentScale];
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
    id gnoix = LCGnoixBridge();
    if (gnoix) {
        SEL termAllSel = NSSelectorFromString(@"terminateAllSessions");
        if ([gnoix respondsToSelector:termAllSel]) {
            ((void (*)(id, SEL))objc_msgSend)(gnoix, termAllSel);
            return;
        }
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
    id gnoix = LCGnoixBridge();
    if (gnoix && targetUUID.length) {
        SEL termSel = NSSelectorFromString(@"terminateSessionWithDataUUID:");
        if ([gnoix respondsToSelector:termSel]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(gnoix, termSel, targetUUID);
            return;
        }
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
    id gnoix = LCGnoixBridge();
    if (gnoix) {
        @try { return [[gnoix valueForKey:@"isFocusedMaximized"] boolValue]; } @catch (__unused NSException *e) {}
    }
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
    id gnoix = LCGnoixBridge();
    if (gnoix) {
        SEL toggleSel = NSSelectorFromString(@"toggleFocusedFullscreen");
        if ([gnoix respondsToSelector:toggleSel]) {
            ((void (*)(id, SEL))objc_msgSend)(gnoix, toggleSel);
            BOOL nowMax = NO;
            @try { nowMax = [[gnoix valueForKey:@"isFocusedMaximized"] boolValue]; } @catch (__unused NSException *e) {}
            return nowMax;
        }
    }
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
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isDrawerOpen) return;
        [UIView animateWithDuration:0.35 animations:^{
            strongSelf.beadView.alpha = strongSelf->_sharedCollapsedOpacity;
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

+ (void)presentSettingsFromTopViewController {
    LCPresentBeadSettingsSheet();
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

    // 宿主多任务模式下立即挂载，单任务模式下轻量延时 0.2 秒极速挂载微珠
    if (gIsMultitaskHostMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self sharedManager] performSetup];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf performSetup];
        });
        return;
    }

    // 多任务宿主模式：直接作为 subview 挂载在最高层非系统窗口顶层（Gnoix 优先挂载在 GnoixPassthroughOverlayWindow 之上，LC 挂载在 keyWindow 之上）
    if (gIsMultitaskHostMode) {
        UIWindow *hostWin = nil;
        UIWindow *gnoixOverlayWin = nil;
        for (UIWindow *w in scene.windows) {
            if (w.hidden || !w.rootViewController) continue;
            NSString *wCls = NSStringFromClass([w class]);
            if ([wCls containsString:@"Keyboard"] || [wCls containsString:@"TextEffects"] || [wCls containsString:@"StatusBar"]) continue;
            if ([wCls containsString:@"GnoixPassthroughOverlayWindow"]) {
                gnoixOverlayWin = w;
                break;
            }
            if (w.isKeyWindow) { hostWin = w; }
            if (!hostWin) hostWin = w;
        }
        if (gnoixOverlayWin) hostWin = gnoixOverlayWin;
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
        UIWindow *targetWin = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.hidden || !w.rootViewController) continue;
                if ([NSStringFromClass([w class]) containsString:@"GnoixPassthroughOverlayWindow"]) {
                    targetWin = w;
                    break;
                }
            }
            if (targetWin) break;
        }
        if (targetWin && self.hostOverlayView.superview != targetWin) {
            [self.hostOverlayView removeFromSuperview];
            self.hostOverlayView.frame = targetWin.bounds;
            [targetWin addSubview:self.hostOverlayView];
        }
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
        id gnoix = LCGnoixBridge();
        if (gnoix) {
            SEL launchSel = NSSelectorFromString(@"launchOrToggleAppWithFolderName:dataUUID:");
            if ([gnoix respondsToSelector:launchSel]) {
                ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(gnoix, launchSel, app.folderName ?: @"", app.dataUUID ?: @"");
                if (completion) completion(YES);
                return;
            }
        }
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
            id gnoix = LCGnoixBridge();
            if (gnoix) {
                SEL minAllSel = NSSelectorFromString(@"minimizeAllSessions");
                if ([gnoix respondsToSelector:minAllSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(gnoix, minAllSel);
                    if (completion) completion(YES);
                    return;
                }
            }
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
    id gnoix = LCGnoixBridge();
    if (gnoix) {
        if (outDockMgr) *outDockMgr = nil;
        @try {
            return [[gnoix valueForKey:@"isActive"] boolValue];
        } @catch (__unused NSException *e) {}
    }

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

    // 监听 GnoixMultitaskBridge 状态广播（0ms 事件驱动刷新，无需等待定时器）
    [[NSNotificationCenter defaultCenter] addObserverForName:@"GnoixMultitaskSessionsDidChange"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        if (LCIsMultitaskExtensionProcess() || [LCSwitcher isContainerGuestRunning]) return;
        BOOL hasMultitask = LCIsHostCurrentlyMultitasking(NULL);
        LCActivateMultitaskHostSwitcherIfNeeded(hasMultitask);
        if (hasMultitask) {
            LCSwitcher *mgr = [LCSwitcher sharedManager];
            if (mgr.hostOverlayView && mgr.hostOverlayView.superview) {
                [mgr.hostOverlayView.superview bringSubviewToFront:mgr.hostOverlayView];
            }
            [mgr.overlayController refreshAppList];
        }
    }];

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
            LCAttachBeadSettingsButtonToMultitaskNavBarIfNeeded();
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
