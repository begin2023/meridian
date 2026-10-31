# Meridian {{VERSION}}

## 简体中文

> 当前安装包使用 ad-hoc 临时签名，未经过 Apple 公证，macOS 可能在首次启动时阻止打开。

### 系统要求

- macOS 26 或更新版本
- Apple Silicon（arm64）

### 安装

1. 下载 ZIP 安装包和 `SHA256SUMS` 校验文件。
2. 打开“终端”，进入两个文件所在的目录并校验下载：

   ```bash
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS
   ```

   输出中应包含 `OK`。

3. 解压 ZIP，将 `Meridian.app` 拖入“应用程序”文件夹。
4. 在“访达”中按住 Control 点击 `Meridian.app`，选择“打开”。
5. 如果 macOS 仍然阻止打开，请前往“系统设置 → 隐私与安全性”，找到 Meridian 的提示并选择“仍要打开”。

终端备用方式：

```bash
xattr -dr com.apple.quarantine /Applications/Meridian.app
open /Applications/Meridian.app
```

只有在 ZIP 校验值与本次 Release 完全一致，并且你信任本项目源码时，才应使用该备用方式。Ad-hoc 签名不代表 Apple 已验证开发者身份；更新到不同签名的版本后，系统可能会再次要求授权。

---

## English

> This build is ad-hoc signed and not notarized by Apple. macOS may block its first launch.

### Requirements

- macOS 26 or later
- Apple Silicon (arm64)

### Install

1. Download the ZIP and the `SHA256SUMS` checksum file.
2. Open Terminal, change to the directory containing both files, and verify the download:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS
   ```

   The output should include `OK`.

3. Unzip the archive and move `Meridian.app` into `/Applications`.
4. In Finder, Control-click `Meridian.app` and choose **Open**.
5. If macOS still blocks it, open **System Settings → Privacy & Security**, find the Meridian message, and choose **Open Anyway**.

Terminal fallback:

```bash
xattr -dr com.apple.quarantine /Applications/Meridian.app
open /Applications/Meridian.app
```

Only use this fallback when the ZIP checksum matches this release and you trust the source. An ad-hoc signature is not an Apple-verified developer identity. Updating to a differently signed build may require allowing access again.
