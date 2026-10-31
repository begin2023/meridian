# Meridian User Guide

[简体中文](USER_GUIDE.md) · **English**

This guide describes the current source build. Architecture, signing, and known issues for official downloads are defined by the corresponding Release.

## First launch

1. Move the app into Applications and open it. The Meridian icon appears in the menu bar.
2. Open **General** in the main window and enable the features and menu bar widgets you need.
3. Request permissions from each feature page and follow the macOS prompts.
4. Return to the app and check the permission status. Some macOS permissions take effect only after quitting and reopening the app.

Appearance offers **System**, **Light**, and **Dark**. **System** follows the current macOS appearance; the other choices override Meridian's appearance.

## Menu bar and main window

| Action | Result |
| --- | --- |
| Left-click the main icon | Open the control center |
| Left-click the CPU, memory, network, or another widget | Open the corresponding details |
| Right-click the main icon | Show the quick actions menu |
| Click Meridian at the top of the panel | Return to the control center home page |
| `⌘,` | Open General settings |
| Close the main window | Keep Meridian running in the menu bar |
| Choose **Quit Meridian** from the menu | Quit completely and restore hardware control where possible |

## Capture, OCR, and pinned screenshots

- **Area capture:** press `⌘⇧2`, select an area, then use the selection toolbar to annotate, copy, save, pin, or recognize text.
- **Text recognition from screen:** press `⌘⇧1`, drag over the text, and release the mouse to use on-device OCR.
- **Pinned screenshot:** select the pin action in the control center or configure a shortcut in Settings. The selection remains visible on screen.
- **Other captures:** the Capture page provides full-screen, current-window, previous-area, and three-second-delay actions.
- **History:** open it from the Capture page or the menu bar context menu. Retention count, save location, and output size can be changed in Settings.
- **Pinned screenshot management:** show, hide, or close all current pins from the Capture page.
- **Cancel:** press `Esc` while selecting an area.

Capture history is stored locally. Do not attach screenshots containing private information to public bug reports.

## GIF recording

1. Press `⌥⇧G` or select the GIF action in the control center.
2. Select the area to record and start.
3. Press the shortcut again or use the on-screen stop button to finish.

The maximum recording length is 30 seconds. Frame rate and maximum width can be adjusted on the Capture page. Lower values reduce file size and encoding overhead.

## Displays

The Displays page exposes the brightness, resolution, refresh rate, and HDR controls supported by each display. External display DDC capabilities depend on the display, cable, adapter, and connection method.

- **Brightness:** Meridian prefers the control method supported by the device. Software dimming changes the display output and does not replace backlight control.
- **5K HiDPI:** mirrors through a higher-resolution virtual display and scales the result to the physical display, improving text appearance at the cost of additional rendering work.
- **More Space:** increases the logical desktop area, making interface elements smaller.
- **Restore Native:** stops upscaling and restores the physical display mode.
- **F1/F2:** enable brightness-key handling on the Displays page and grant Input Monitoring if macOS asks.
- **Display overrides:** installing or removing system display overrides requires the administrator helper. This is separate from temporary virtual-display upscaling.

If the screen goes black, flickers, or windows are rearranged, first restore the native mode, disable the relevant display feature, and check the connection. Avoid letting multiple tools continuously write brightness or color tables to the same display.

## Fans and thermals

Fan speeds and temperatures are available in the menu bar and detail pages. The current temperature catalog is a built-in candidate set, and not every label or machine-specific meaning has been verified. Unavailable readings do not constitute a complete hardware diagnosis.

| Mode | Meaning |
| --- | --- |
| System Auto | Return fan control to macOS |
| Fixed RPM | Set a target RPM within the range allowed by the app |
| Temperature curve | Calculate target speed from the selected temperature and the start/full-speed thresholds |
| Full-speed preset | Use the app's configured effective maximum, limited by the maximum-speed percentage |

After changing Fixed RPM or the Temperature curve, click **Apply**. Non-automatic control requires compatible fan hardware and the administrator-installed control service.

Use System Auto if temperature readings are missing, abnormal, or inconsistent with the Mac model. The helper and thermal catalog still have release-verification items; see the [release checklist](RELEASING.md).

## Scroll enhancement

Configure smooth scrolling, direction reversal, and per-app exceptions on the Scrolling page. Use the menu bar quick menu or a custom shortcut to pause and resume without losing the configured values.

If scrolling jumps, moves in the wrong direction, or window dragging becomes unreliable, pause Scroll Enhancement and retest. Then quit other tools that process mouse events one at a time. Pausing a feature does not erase its settings.

## System monitoring

The menu bar can show CPU, memory, network, temperature, and fan widgets. Monitoring details include per-core CPU, memory categories, network throughput, disk activity, and process rankings.

Process ranking requests samples only while the relevant details are visible. Live rankings, GIF recording, and other workloads increase resource use. Closing a details view removes the corresponding interface subscription.

## Permissions

| Permission | Purpose | When it is needed |
| --- | --- | --- |
| Screen Recording | Capture, OCR, GIF | When using screen-capture features |
| Accessibility | Scroll enhancement | When enabling the feature |
| Input Monitoring | Optional external-display brightness-key handling | When requested by macOS |
| Administrator authorization | Fan control service and display override helper | When installing or removing those services |

If the app does not appear in a macOS permission list, choose **Show Meridian in Finder** on the relevant feature page, then use the add control in System Settings to select it. After granting permission, quit and reopen the app, then check its status again.

## Updates and uninstall

Before updating, stop GIF recording, return fans to System Auto, restore native display mode, and quit Meridian before replacing the app. Updates between different signing identities or ad-hoc builds may require granting permissions again.

Before uninstalling, disable Launch at Login, return fans to automatic control, restore native displays, and remove the installed fan and display-override services. Then quit the app and move `Meridian.app` to the Trash. Moving only the app does not automatically remove the root helper or delete capture history. Complete service uninstall and upgrade verification remain release-checklist items.

See [Privacy](PRIVACY.en.md) for local data locations.
