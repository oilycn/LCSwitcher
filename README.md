# LCSwitcher

**专为 LiveContainer (3.8.0+) 与 Gnoix 打造的单任务 & 多任务全能侧边栏切换器插件**

纯原生 Objective-C / UIKit 零第三方依赖实现，无需修改 IPA，同时支持 **多任务模式（替代原版多任务侧边栏）** 与 **单任务模式（快速切应用 / 缩放 / 画中画 / 跟随系统旋转）**。

---

## 核心特性

### 1. 贴边无边框微珠 + 侧滑呼出
- **极简视觉**：`16×54pt` 无边框毛玻璃胶囊微珠，闲置 3 秒自动半隐，不遮挡内容。
- **手势交互**：
  - **向屏幕内侧轻滑** 或 **轻点微珠** → 呼出紧凑悬浮抽屉；
  - **按住拖动** → 自由调整上下高度或拖至屏幕左/右侧边缘自动吸附并持久化记忆。

### 2. 紧凑 4 列图标网格 & 三态视觉区分
- **4 列应用网格**：抽屉紧凑居中不占满整屏，超出部分自由滚动。
- **三态清晰区分**：
  - **当前前台应用**：彩色图标 + 绿色边框 + 右上角**绿点**
  - **后台运行中应用**：保持**彩色图标**（无绿点）
  - **未运行应用**：**灰度图标**
- **快捷操作**：
  - **轻点图标**：前台应用切后台（最小化）、后台应用置顶回前台、未运行应用直接启动；
  - **长按图标**：直接关闭对应多任务子进程。

### 3. 底部功能按钮栏
- **主页**：短按最小化所有多任务窗口返回主页（单任务下安全返回宿主）；**长按关闭所有运行中的子进程**。
- **缩放（50%–200%）**：点击展开滑块条，支持 `5%` 步进实时缩放当前应用画面，点击百分比胶囊一键重置 `100%`（单应用独立记忆）。
- **画中画**：多任务模式调用原生 `PiPManager.shared` 实现跨进程画中画；单任务模式支持 `AVPictureInPictureController` 投屏。
- **全屏（多任务模式）**：对接原生 `MultitaskDockManager.shared.toggleDockCollapse()`，一键对**所有多任务子进程**开启/退出无顶栏完全全屏。
- **旋转（单任务模式）**：单应用独立开关，强制放开竖屏/横屏锁定，关闭时无损恢复原始方法实现。

### 4. 无缝替代 LiveContainer 3.8.0+ 原生多任务侧边栏
- 仅在宿主主进程生效，通过 `_dyld_get_image_name(0)` 自动跳过 `.appex` 多任务子进程，绝不在子进程内重复显示。
- 宿主多任务模式下直接挂载在宿主 `keyWindow` 顶层（不新建 `UIWindow`、不抢 `rootViewController`），并在原版 `MultitaskDockSwiftView` 挂载同一帧立即隐藏，杜绝闪现。

---

## 安装指南（LiveContainer 3.8.0+，无需改 IPA）

1. 在 Releases 下载 `LCSwitcher.dylib`（或自行编译）。
2. 打开 **LiveContainer** → **Tweaks（模块）** → 全局根目录 → **Import Tweak** 导入 `LCSwitcher.dylib`。
3. 点击 Tweaks 页面右上角的**签名按钮**，使用当前证书重签 `.dylib`。
4. 进入 **Settings（设置）** → 拉到最底部**连续点击版本号 5 次** → 打开 **Developer Settings** → 开启 **`Load Tweaks to LiveContainer Itself`**。
5. **完全划掉退出 LiveContainer** 后重新打开即可生效。

> 越狱 / TrollStore 用户也可直接安装 `.deb` 或使用 TrollFools 注入宿主。

---

## 本地编译

环境要求：macOS + Xcode Command Line Tools（含 iOS SDK 16.0+）。

```bash
chmod +x build.sh
./build.sh
```

编译产物：
- `LCSwitcher.dylib`（arm64，已 `strip -x` 并 Ad-Hoc 签名，~190 KB）
- `LCSwitcher.plist`
- `LCSwitcher_1.0.0_iphoneos-arm.deb`
- `LCSwitcher.zip`

---

## 开源许可

本项目基于 [MIT License](LICENSE) 开源。
