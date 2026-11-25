//
//  LCSwitcher.h
//  LiveContainer / Gnoix 单任务 & 多任务全能侧边栏切换器插件 (Tweak)
//
//  功能：
//  - 注入到 LiveContainer 单任务（经典单开）客态应用中
//  - 屏幕侧边提供极简半透明磁吸悬浮微珠，支持拖拽、边缘吸附与闲置自动半隐
//  - 点击滑出磨砂玻璃风格抽屉侧边栏，罗列全部已安装的沙盒应用与运行状态
//  - 支持一键平滑无缝切入其他应用，或一键安全退出返回 LiveContainer 宿主主页
//  - 零外部依赖，纯原生 UIKit 实现，轻量、安全、即插即用
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - 沙盒应用元数据模型

@interface LCSwitcherAppInfo : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folderName;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *dataUUID;
@property (nonatomic, copy) NSString *appPath;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, assign) BOOL isJITEnabled;

- (instancetype)initWithName:(NSString *)name
                  folderName:(NSString *)folderName
                    bundleId:(NSString *)bundleId
                     version:(NSString *)version
                    dataUUID:(NSString *)dataUUID
                     appPath:(NSString *)appPath
                        icon:(nullable UIImage *)icon
                isJITEnabled:(BOOL)isJITEnabled;

@end

// MARK: - 插件核心中枢 (公开调度 API)

@interface LCSwitcher : NSObject

/// 单例对象
+ (instancetype)sharedManager;

/// 在当前 WindowScene 上安装/挂载悬浮微珠与侧边栏（若尚未初始化）
+ (void)setupIfNeeded;

/// 扫描 LiveContainer Documents/Applications 下已安装的应用列表
+ (NSArray<LCSwitcherAppInfo *> *)scanInstalledApps;

/// 展示无缝平滑交接 HUD 并热交接切入目标沙盒应用
+ (void)presentTransitionAndSwitchToApp:(LCSwitcherAppInfo *)app
                             completion:(nullable void (^)(BOOL finished))completion;

/// 展示无缝平滑交接 HUD 并安全退出客态返回 LiveContainer / Gnoix 宿主主页
+ (void)presentTransitionAndReturnHomeWithCompletion:(nullable void (^)(BOOL finished))completion;

/// 获取 LiveContainer / 宿主的真实 Documents 根目录
+ (NSString *)realHostDocumentsDirectory;

/// 获取当前正在运行的客态应用的文件夹名（如 "YouTube.app"）
+ (NSString *)currentGuestFolderName;

/// 获取宿主主程序的 Bundle Identifier（如 "com.kdt.livecontainer" 或 "cn.oily.Gnoix"）
+ (NSString *)hostBundleIdentifier;

/// 判断当前进程是否正处于 LiveContainer 沙盒客态运行环境
+ (BOOL)isContainerGuestRunning;

@end

NS_ASSUME_NONNULL_END
