# GitHub 与 Release 发布清单

当前仓库是发布准备版本。源码整理完成与应用可面向所有用户稳定分发是不同阶段；下列未完成项目不能通过添加开源协议代替。

## 已整理

- 主应用与五个依赖模块已收进同一个仓库，不再依赖作者机器上的同级目录。
- 添加 0BSD 协议、资源说明、README、使用手册、FAQ、隐私说明和贡献指南。
- 清理了参考产品名称、比较式注释、提示文案及相关硬编码应用检测条目。
- 构建不再复制许可未核清的传感器 XML；传感器目录只使用内置只读候选集。
- Developer ID 身份构建时，签名脚本为主程序与助手启用 hardened runtime 和 timestamp。
- 原本的本机采样与实测记录保留为历史，不能视为跨机型发布认证。

## 公开源码之前

- [ ] 确认待公开文件的来源和授权。0BSD 只覆盖作者有权授权的内容，不会自动解决未知来源内容的权利问题。
- [ ] 检查首次 Git 提交的文件清单和秘密信息；不提交 `.build/`、`dist/`、私钥、证书私钥包、私人日志、研究资料或用户截图。
- [ ] 确定 GitHub 仓库所属账号、仓库名称和可见性，创建 Git 仓库及远程地址。当前目录尚未完成这一步。
- [ ] 在干净路径复制或克隆源码后构建，确认不依赖本机其他项目和缓存。
- [ ] 将 README、Release 文案中的下载入口指向实际仓库，避免编造地址。

## 提供下载包之前

### 1. 管理员助手与硬件控制

当前显示覆盖和风扇助手仍通过用户目录 JSON 文件接收命令，以管理员授权脚本安装为 root 服务。本机可用不代表已完成公开分发的安全审查。

公开二进制之前需要完成：

- 请求方身份与授权校验。带签名要求和调用方校验的 XPC 是可选改造方向；仅拥有正式证书不会自动验证请求方。
- 用户目录、符号链接、命令和结果文件的属主、权限、原子写入与重放边界检查。
- 风扇参数在服务端按设备能力验证，拒绝非有限值、非法模式、过长有效期和越界转速。
- 验证温度传感器缺失、异常及陈旧读数时的行为；不能把候选温度当作已验证的控制依据。
- 验证服务重启、应用崩溃、睡眠唤醒、用户切换、升级和卸载后的恢复行为。
- 让用户明确区分临时显示上采样与持久的系统显示覆盖，并提供经验证的恢复路径。

这些事项尚未完成。首次版本建议标记为预发布测试版，并在解决核心助手和硬件控制问题后再提供公开下载。

### 2. 签名与公证

当前开发机只有本地自签名身份，没有 Developer ID Application 身份。其他 Mac 默认不信任该证书。

无需付费证书也可分发明确标注的未公证测试包，但用户可能需要自行允许打开；要获得通常的直接下载安装体验，应使用 Apple Developer ID 签名并完成 Apple 公证。这不是 GitHub 上传文件的要求。

有对应证书后可构建：

```bash
MERIDIAN_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
  scripts/build-app.sh release
codesign --verify --strict --deep dist/Meridian.app
```

其中身份名称需替换为钥匙串内实际的 Developer ID。根应用和两个可执行助手都要检查 hardened runtime、时间戳及最终签名。

公证采用单次提交加短轮询方式。把凭证保存在钥匙串中，不提交到 GitHub：

```bash
# 按 Apple 当前工具提示配置名为 meridian-notary 的钥匙串凭证后：
ditto -c -k --sequesterRsrc --keepParent dist/Meridian.app dist/Meridian-notary.zip
xcrun notarytool submit dist/Meridian-notary.zip \
  --keychain-profile meridian-notary --no-wait

# 记录返回的 submission id；每次独立查看，不做无限等待
xcrun notarytool info SUBMISSION_ID --keychain-profile meridian-notary
```

确认状态为 Accepted 后再执行：

```bash
xcrun stapler staple dist/Meridian.app
xcrun stapler validate dist/Meridian.app
spctl --assess --type execute --verbose=4 dist/Meridian.app
```

公证完成后重新压缩最终应用，不能发布公证前的旧 ZIP。工具可用性和结果以实际环境为准，目前未执行公证。

### 3. 版本、架构与回归

- 在 `Resources/Info.plist` 设置发布版本号和递增构建号，确保 tag 与版本号一致（当前为 `1.0.1` / `2`）。
- 当前为 arm64；若只发布 Apple Silicon 包，在文件名和页面写明，不能声称 Universal。
- 验证最低支持的 macOS 26，而不只验证当前开发机系统。
- 在未运行过开发版的 Mac 或干净用户中测试首次安装、各权限授权、登录项、更新和卸载。
- 逐项验证截图、识字、贴图、GIF、滚动例外、主窗口和菜单栏；硬件功能记录具体机型、连接及结果。
- 发布包构建后检查资源清单，确保没有外部 XML 表、源码备份、开发凭证或私人数据。

### 4. 打包与 GitHub Release

最初用 ZIP 即可；拖拽安装 DMG、自动更新和 Homebrew 分发可以以后再补。

```bash
# 仅在通过签名、公证及功能验证后打包
ditto -c -k --sequesterRsrc --keepParent dist/Meridian.app \
  dist/Meridian-VERSION-macOS-arm64.zip
shasum -a 256 dist/Meridian-VERSION-macOS-arm64.zip > dist/SHA256SUMS
```

先创建 GitHub 草稿 Release，核对 tag、提交、版本号、附件与校验值，然后发布。Release 文案至少包含系统与架构、安装方法、权限、签名公证状态、已知限制及变更记录。

证书私钥、开发目录和 `.build` 不作为附件。对外发布前仍需确认实际仓库及作者身份，当前任务没有创建远程仓库、推送源码或发布 Release。

## 无需 Developer ID 的 GitHub Actions 流程

仓库带有 `.github/workflows/release-unsigned.yml`，用于生成明确标注的未公证预发布包：

- 在 Actions 页面手动输入一个已存在的 tag，或推送形如 `v1.0.0` 的 tag。
- CI 使用 `macos-26` arm64 运行器和 ad-hoc 签名构建。
- ZIP、`SHA256SUMS` 和安装说明作为 workflow artifact 与 Draft Release 附件。
- Release 始终保持草稿和 pre-release 状态，必须在网页中人工检查后发布。
- 发布前必须让 `Resources/Info.plist` 的版本号与 tag 完全一致。

用户首次运行需要右键打开，或在“系统设置 → 隐私与安全性”中选择“仍要打开”。
终端兜底命令是：

```bash
xattr -dr com.apple.quarantine /Applications/Meridian.app
```

ad-hoc 签名不包含可验证的开发者身份，不能用 `spctl` 当作可信分发包。每次签名内容变化后，
系统也可能重新要求用户确认。只有在用户核对 Release 中的 SHA256 并信任下载来源时才应使用。

本地预演：

```bash
cd /path/to/meridian
MERIDIAN_SIGN_IDENTITY=- scripts/build-app.sh release
scripts/package-release.sh v1.0.0 unsigned
```

将来取得 Developer ID 后，应新增独立 workflow，导入证书、公证、staple，再调用
`scripts/package-release.sh "$TAG" signed`。未公证 workflow 不应被误认为正式稳定分发渠道。
