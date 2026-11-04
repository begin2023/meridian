# Privacy and Local Data

[简体中文](PRIVACY.md) · **English**

## How features handle data

- Screenshots and GIFs use local screen capture; text recognition uses the system Vision framework.
- Capture history, thumbnails, GIFs, and user-exported files remain on the local Mac.
- System monitoring reads CPU, memory, network-interface counters, disk information, and process information. Measuring throughput does not require reading web pages or capturing network content.
- The current Meridian host has no account, screenshot-upload, cloud-OCR, or telemetry-upload service.
- The egress public IP lookup is off by default and makes no network request. Only after the user turns it on (in “Telemetry → Sampling” or on the network details page) does Meridian query `ipinfo.io`, falling back to `freeipapi.com`; both services see the requester's egress IP, and the IP, region, and provider returned are cached only in local memory. Turning the switch off cancels any in-flight query and clears the result.
- The administrator helpers handle local display overrides and fan-register writes. Both talk only over a Unix socket under `/var/run`; each helper verifies the caller's code signature before acting and no longer polls a user-writable request file.

## Default storage locations

| Data | Location |
| --- | --- |
| Capture history, index, and thumbnails | `~/Library/Application Support/ScreenshotLab/History/` |
| Quick-save directory | Defaults to `~/Pictures/ScreenshotLab/`; configurable on the Capture page |
| Main app preferences | UserDefaults domain `app.meridian.control`, retained for compatibility with older builds |
| Module preferences | `app.meridian.control.capture`, `.pointer`, `.display`, `.thermal` |
| Display HiDPI overrides and ownership receipts | `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-*/` (written by the helper; only files with a Meridian receipt are replaced) |
| Helper configuration | `/Library/PrivilegedHelperTools/app.meridian.<display\|thermal>.*` and the matching plists under `/Library/LaunchDaemons/` |

Development builds can override some data directories with environment variables. Existing local builds may also retain custom paths. Use the app settings and actual files as the source of truth.

## Cleanup and feedback

Capture history and exported files can contain passwords, conversations, or personal information. Deleting the app does not automatically delete this data, and user-exported copies are not covered by the history-retention limit.

Before uninstalling, restore system fan and native display control, remove the administrator services, and quit the app before deciding whether to delete the files listed above. Do not delete a running service's state files while it is active.

Before sharing logs, screenshots, or diagnostic reports, check for usernames, paths, process names, and screen contents.
