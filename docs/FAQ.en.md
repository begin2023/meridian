# Frequently Asked Questions

[简体中文](FAQ.md) · **English**

## Why does the app keep running after I close its window?

Meridian is a menu bar app. Closing the main window only hides the interface. To quit completely, choose **Quit Meridian** from the menu bar menu.

## macOS says the app cannot be opened or the developer cannot be verified

First confirm that the download came from this repository's Releases and check the signing, notarization, and checksum information for that version. The current locally signed build is not equivalent to a notarized distribution.

If you trust a test build that is explicitly marked as unnotarized, you may choose whether to allow that specific app through the macOS **Privacy & Security** prompt. Do not disable macOS security globally. If the archive is damaged or its signature does not match, download it again and report the issue.

## Does Meridian support older macOS versions or Intel Macs?

The current minimum is macOS 26. Existing builds have been verified on Apple Silicon, and no verified Intel or Universal release exists. The fact that Swift source can compile does not prove compatibility with every architecture.

## Why does capture or scrolling not work?

Check whether the feature is enabled and whether Screen Recording or Accessibility permission has been granted. Reopen the app after granting permission. A shortcut conflict can be changed in **General**. Rebuilding with a different signature may also require granting permission again.

## Why is brightness, HDR, or a specific resolution unavailable?

Availability depends on the display, macOS, cable, adapter, and connection method. Software dimming and backlight control have different effects. First confirm that the display works correctly in macOS Display settings, then try the available Meridian controls.

## Does 5K HiDPI increase CPU, GPU, or memory use?

It may. Rendering happens at a higher resolution and is then scaled to the physical display. Refresh rate, the number of external displays, and screen content all affect overhead. Restore native mode when the feature is not needed.

## Why are some temperature readings missing or marked as candidates?

The public source does not include an external sensor table whose redistribution terms have not been cleared. It uses a built-in read-only candidate set instead of a complete per-model hardware database. Fan RPM readings are independent of the temperature label catalog, but temperature-based control should rely on verified readings.

## Why does scrolling or window dragging behave unexpectedly?

First pause Meridian's Scroll Enhancement and retest, then disable other tools that process mouse events one at a time. If the problem remains after quitting Meridian, continue checking other background tools and the system state. Include reproduction steps in a report without assuming the cause in advance.

## Does Meridian upload screenshots or recognized text?

The current code uses local capture, Vision OCR, and local storage. It has no configured screenshot upload, cloud OCR, account, or telemetry service. History images and exported files may still contain private information; see [Privacy](PRIVACY.en.md).

## Why does Launch at Login not work?

Login items are managed by macOS `SMAppService`. Check the app switch, the system Login Items settings, and whether approval is pending. Signing, install location, and macOS version may all affect the result. Verification across more devices is still pending.

## How should I report a problem?

Open an Issue in this repository and include the app version, macOS version, chip, connection method, reproduction steps, expected result, and actual result. Remove usernames, paths, screen contents, and other private information from screenshots and logs before attaching them.
