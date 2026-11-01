<div align="center">

[简体中文](README.md) · **English**

# Meridian

**Everyday Mac utilities, brought together in your menu bar.**

Capture & OCR · Display control · Fans & thermals · Scroll enhancement · System monitoring

![macOS](https://img.shields.io/badge/macOS-26%2B-166978)
![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-166978)
![Swift](https://img.shields.io/badge/Swift-6.2%2B-F06A36)
![License](https://img.shields.io/badge/license-0BSD-166978)

[Quick start](#quick-start) · [User guide](docs/USER_GUIDE.en.md) · [FAQ](docs/FAQ.en.md) · [Development](docs/DEVELOPMENT.md)

</div>

Meridian means "meridian": a reference line for observing and calibrating the state of a system. This native macOS menu bar control center brings screen capture, system load, displays, cooling, and scrolling controls together. Features can be enabled as needed, and the app keeps running in the menu bar after its main window is closed.

The interface is built with SwiftUI and AppKit and supports light, dark, and system appearance. Features run in the same application process. Display overrides and fan writes that require administrator access are handled by a separate helper.

> **Project status: 1.0.1.** The GitHub build is an unnotarized Apple Silicon build, so macOS may require the user to allow it manually. Developer ID notarization and testing on additional Mac models have not been completed. Download and signing details are defined by the corresponding [Release](https://github.com/begin2023/meridian/releases). See the release checklist in [docs/RELEASING.md](docs/RELEASING.md) for internal details.

## Features

| Module | What it does |
| --- | --- |
| Capture & OCR | Area, window, full-screen, and timed captures; annotations; on-device text recognition; pinned screenshots; history; area GIF recording up to 30 seconds |
| Displays | External display brightness, software dimming, HiDPI resolution sizes and refresh rate, HDR (SDR brightness and brightness boost), virtual displays; availability depends on the display and macOS |
| Fans & thermals | Fan speed and readable temperatures; system auto, fixed RPM, temperature curve, and full-speed presets; control requires the administrator helper and compatible hardware |
| Scroll enhancement | Smooth scrolling, direction reversal, per-app profiles, and temporary pause |
| System monitoring | CPU, memory, network, disk, and process rankings; menu bar widgets can be enabled independently |
| General | Global shortcuts, launch at login, permission status, and appearance settings |

Temperature labels use a built-in candidate detection set and do not yet represent a verified per-model sensor database. Macs without fans do not expose fan controls, and unsupported display features may be unavailable.

## Requirements

- **macOS 26 or later.** The current interface directly uses system materials and APIs from that release.
- The current build and verification target is **Apple Silicon (arm64)**. No Intel or Universal download has been provided or verified.
- Existing real-device testing covers a Mac mini M4 running macOS 27.2. Release regression testing on macOS 26 and other Mac models is still pending.
- Screen Recording, Accessibility, and administrator permissions are requested only by features that need them. See [Permissions](docs/USER_GUIDE.en.md#permissions).

## Download and install

Download the appropriate build from the **Releases** page.

1. Download and extract the release archive, then move `Meridian.app` into Applications.
2. Open Meridian and use its menu bar icon to access the control center.
3. Enable the features you need and grant their permissions.

Signing, notarization, architecture, and OS requirements are defined by each Release. The GitHub build is ad-hoc signed, so other Macs do not treat its developer identity as verified by Apple. On first launch, you may need to Control-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security**. Read the [FAQ](docs/FAQ.en.md) before changing any global security setting.

## Quick start

1. **Open the control center:** left-click the main menu bar icon. Click a CPU, memory, or fan widget to open its details.
2. **Take a screenshot:** press `⌘⇧2`, select an area, then annotate, copy, save, or pin it.
3. **Recognize text:** press `⌘⇧1`, drag over the text, and release the mouse.
4. **Record a GIF:** press `⌥⇧G`, select an area, and press the shortcut again to stop.
5. **Change settings:** right-click the menu bar icon to open the main window, then press `⌘,` to open General settings.

These are the default shortcuts for a fresh installation. Upgrading from an older local build preserves existing settings. Pin, scroll pause, and control-center shortcuts can also be customized.

## Everyday use

- Left-click the main menu bar icon to open the panel. Right-click it for capture, OCR, GIF, history, and quit actions.
- The main window sidebar contains Overview, five feature pages, and General settings.
- Closing the main window does not quit the app. To exit completely, choose **Quit Meridian** from the menu.
- On a normal quit, the app asks to return fans to system control and cleans up virtual displays, software dimming, and brightness boost. Abnormal-exit and restart behavior still needs verification across devices.
- Multiple tools that process scroll-wheel events or control the same hardware may conflict. Pause them one at a time when troubleshooting.

See the [User Guide](docs/USER_GUIDE.en.md) for detailed instructions and the [FAQ](docs/FAQ.en.md) for troubleshooting.

## Privacy and data

Captures, OCR, and history are processed by local modules. The current code has no cloud OCR, account system, or telemetry upload configured. Capture history, exported files, and preferences remain on the local Mac and may contain sensitive content.

See [Privacy](docs/PRIVACY.en.md) for the complete explanation and storage locations.

## Build from source

Swift 6.2+ and an SDK that supports macOS 26+ APIs are required. Install the appropriate Xcode or Command Line Tools, then run the following from the repository root:

```bash
# Development build without a locally installed signing certificate
scripts/build-app.sh release

# Output: dist/Meridian.app
# Optional: install into /Applications and launch
scripts/install.sh
```

The repository includes the five local modules required by the app, so no sibling project directories are needed. Local ad-hoc signing is suitable for development, but rebuilding may require granting system permissions again. See the release checklist in [docs/RELEASING.md](docs/RELEASING.md) for distribution signing and notarization.

See [Development](docs/DEVELOPMENT.md) for the directory layout, module checks, and signing details.

## Performance

In one local Release comparison, average background CPU use with the main window and panel closed fell from 3.50% to 1.55%. After using and then closing the interface, memory fell from approximately 92–93 MB to 81–83 MB.

This is a short, configuration-specific result and does not represent every Mac or workload. See [Performance notes](docs/PERFORMANCE.md) for methodology, conditions, and limitations.

## Feedback and contributions

Please report problems through this repository's Issues. Include the macOS version, chip model, display connection method, reproduction steps, and app version. Remove private information from logs and screenshots before posting.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code. Cross-device compatibility, first-time permission prompts, the administrator helper, and release verification are current priorities.

## License

Meridian is released under the [BSD Zero Clause License (0BSD)](LICENSE). To the extent contributors can grant rights, you may use, modify, commercially use, and redistribute the software without attribution. The software is provided as-is without warranty.

System frameworks and any third-party components added in the future remain subject to their own terms. See [NOTICES.md](NOTICES.md) for bundled resources and attribution.
