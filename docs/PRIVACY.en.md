# Privacy and Local Data

[简体中文](PRIVACY.md) · **English**

## How features handle data

- Screenshots and GIFs use local screen capture; text recognition uses the system Vision framework.
- Capture history, thumbnails, GIFs, and user-exported files remain on the local Mac.
- System monitoring reads CPU, memory, network-interface counters, disk information, and process information. Measuring throughput does not require reading web pages or capturing network content.
- The current Meridian host has no account, screenshot-upload, cloud-OCR, or telemetry-upload service.
- The network details page requests the public egress IP from `api.ipify.org` only when the user opens that page. The service receives the requester's egress IP. The result is cached only in local memory and is not uploaded to a project server.
- The administrator helper is used for local display overrides and fan-register writes.

The monitoring library contains an optional public-IP location lookup implementation, but the embedded Meridian host does not use that location feature.

## Default storage locations

| Data | Location |
| --- | --- |
| Capture history, index, and thumbnails | `~/Library/Application Support/ScreenshotLab/History/` |
| Quick-save directory | Defaults to `~/Pictures/ScreenshotLab/`; configurable on the Capture page |
| Main app preferences | UserDefaults domain `app.meridian.control`, retained for compatibility with older builds |
| Module preferences | `app.meridian.control.capture`, `.pointer`, `.display`, `.thermal` |
| Fan-control state | `~/Library/Application Support/FanControlLab/desired.json` |
| Display-override requests and results | `~/Library/Application Support/DisplayLab/` |

Development builds can override some data directories with environment variables. Existing local builds may also retain custom paths. Use the app settings and actual files as the source of truth.

## Cleanup and feedback

Capture history and exported files can contain passwords, conversations, or personal information. Deleting the app does not automatically delete this data, and user-exported copies are not covered by the history-retention limit.

Before uninstalling, restore system fan and native display control, remove the administrator services, and quit the app before deciding whether to delete the files listed above. Do not delete a running service's state files while it is active.

Before sharing logs, screenshots, or diagnostic reports, check for usernames, paths, process names, and screen contents.
