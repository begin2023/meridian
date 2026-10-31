# Meridian {{VERSION}}

## 简体中文

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
4. 正常打开 Meridian。

本安装包应使用 Developer ID Application 签名、完成 Apple 公证并附加公证票据后再发布。可执行以下检查：

```bash
codesign --verify --strict --deep /Applications/Meridian.app
spctl --assess --type execute --verbose=4 /Applications/Meridian.app
xcrun stapler validate /Applications/Meridian.app
```

---

## English

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
4. Open Meridian normally.

This package must be built with Developer ID Application, notarized by Apple, and stapled before publication. Verify it with:

```bash
codesign --verify --strict --deep /Applications/Meridian.app
spctl --assess --type execute --verbose=4 /Applications/Meridian.app
xcrun stapler validate /Applications/Meridian.app
```
