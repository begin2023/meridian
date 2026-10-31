# 开发与构建

## 环境

- macOS 26+，当前验证环境为 Apple Silicon。
- Swift 6.2+；当前源码使用 Swift 5 语言模式。
- 可提供 macOS 26+ API 的 Xcode 或 Command Line Tools。
- 图标生成需要 AppKit 与系统 `iconutil`。

## 仓库结构

```text
Package.swift                  宿主 Swift Package
Sources/Meridian/                App、模块模型、SwiftUI 页面与菜单栏
Modules/Capture/               截图、Vision 识字、贴图与 GIF
Modules/Scrolling/             滚轮事件处理与设置
Modules/Monitoring/            系统采样及监控库
Modules/Display/               显示器、DDC、虚拟屏与覆盖助手
Modules/Thermal/               SMC 读取、温度与风扇控制服务
Resources/                     App 元数据、图标候选
scripts/                       构建、安装和图标生成
docs/                          使用、验证与发布说明
```

所有包路径都在仓库内。主应用直接链接五个库；显示覆盖助手和风扇服务作为单独可执行文件打包。无需其他同级目录。

## 构建应用

```bash
scripts/build-app.sh release
```

产物为 `dist/Meridian.app`。构建脚本会依次构建主应用和两个助手，复制元数据、启动配置与图标，然后由内到外签名并验证。

脚本默认使用当前开发机钥匙串中的稳定本地签名身份 `Toolbox Local Signing`。这个名称来自项目早期目录，暂不改名是为了避免现有辅助功能、屏幕录制和输入监控授权失效；正式分发必须改用 Developer ID Application。开发时不要使用 `MERIDIAN_SIGN_IDENTITY=-` 的 ad-hoc 签名，否则每次重建都可能被系统当作新应用而要求重新授权。其他开发者可显式设置 `MERIDIAN_SIGN_IDENTITY` 为自己的本地或 Developer ID 身份。

开发临时签名不能替代 Developer ID 公证。签名变化可能影响系统权限授权；不要把开发证书私钥提交到仓库。

## 安装到本机

```bash
scripts/install.sh
# 或者只安装，不启动
scripts/install.sh --no-open
```

脚本会退出 `/Applications/Meridian.app`，将旧应用移到废纸篓，再复制新应用。它不是对外分发的安装器，也不负责安装 root 助手。

## 模块检查

下面是仓库包含的现有嵌入模块检查入口。它们可能临时显示模块窗口并读取硬件信息，请在本机桌面会话运行。

```bash
swift run --package-path Modules/Capture ScreenshotLabKitSmoke
swift run --package-path Modules/Scrolling ScrollLabKitSmoke
swift run --package-path Modules/Monitoring MonitoringLabKitSmoke
swift run --package-path Modules/Display DisplayLabKitSmoke
swift run --package-path Modules/Thermal FanControlLabKitSmoke
```

这些检查不能替代首次权限、真实屏幕录制、硬件写入、升级和卸载的端到端验证。风扇检查应保持只读，不应为了构建验证而接管真实风扇。

## 状态与性能

UI 模型在主线程发布状态，系统采样使用后台串行队列。控制中心和主窗口关闭时卸载内容；进程排行只在详情可见时采样。不要在视图 `body` 中执行硬件读取或同步文件操作。

监控库还保留独立模块的界面代码与可选公网 IP 归属地查询代码；Meridian 宿主使用 `SystemSampler` 本地采样，不实例化该界面与在线查询路径。若以后接入在线功能，应先完善产品开关和隐私说明。

性能观测见 [PERFORMANCE.md](PERFORMANCE.md)，真机历史记录见 [VERIFICATION.md](VERIFICATION.md)。

## 图标

当前构建图标由 `scripts/make-icon.swift` 生成。另一个独立候选可这样重新生成：

```bash
swift scripts/make-icon-v2.swift Resources/IconDesign
iconutil -c icns Resources/IconDesign/AppIcon-v2.iconset \
  -o Resources/IconDesign/AppIcon-v2.icns
```

候选未自动替换生产图标，设计说明见 [ICON_DESIGN.md](ICON_DESIGN.md)。
