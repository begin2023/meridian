import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

struct ScreenSnapshot {
    let image: CGImage
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let scale: CGFloat
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "需要屏幕录制权限才能截图。请在“系统设置 > 隐私与安全性 > 屏幕录制”中允许 \(ScreenshotLabIdentity.displayName)。"
        case .displayNotFound:
            return "没有找到可截取的显示器。"
        case .windowNotFound:
            return "没有找到可截取的活动窗口。"
        case .captureFailed(let message):
            return "截屏失败：\(message)"
        }
    }
}

enum ScreenCaptureService {
    static func screenAtMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    static func capture(screen requestedScreen: NSScreen? = nil) async throws -> ScreenSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        let screen = requestedScreen ?? screenAtMouse()
        let snapshot: ScreenSnapshot
        do {
            snapshot = try await captureWithScreenCaptureKit(screen: screen)
        } catch {
            snapshot = try await captureWithSystemTool(screen: screen)
        }
        let result = downsample(snapshot, factor: AppSettings.shared.screenshotScale)
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        NSLog("[Capture] screen capture %dx%d in %.0f ms", result.image.width, result.image.height, elapsedMS)
        return result
    }

    private static func downsample(_ snapshot: ScreenSnapshot, factor: Double) -> ScreenSnapshot {
        let factor = min(1, max(0.25, factor))
        guard factor < 0.999 else { return snapshot }
        let width = max(1, Int((Double(snapshot.image.width) * factor).rounded()))
        let height = max(1, Int((Double(snapshot.image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return snapshot }
        context.interpolationQuality = .high
        context.draw(snapshot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return snapshot }
        return ScreenSnapshot(
            image: image,
            screen: snapshot.screen,
            displayID: snapshot.displayID,
            screenFrame: snapshot.screenFrame,
            scale: CGFloat(image.width) / max(1, snapshot.screenFrame.width)
        )
    }

    private static func captureWithScreenCaptureKit(
        screen: NSScreen
    ) async throws -> ScreenSnapshot {
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        let displayID = CGDirectDisplayID(screenNumber?.uint32Value ?? CGMainDisplayID())

        let content: SCShareableContent
        let contentStarted = DispatchTime.now().uptimeNanoseconds
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
        NSLog("[Capture] ScreenCaptureKit content discovery in %.0f ms",
              Double(DispatchTime.now().uptimeNanoseconds - contentStarted) / 1_000_000)

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }

        // SCDisplay.width/height are reported in points; SCStreamConfiguration
        // expects pixels. Skip the scale factor and a 5K display is captured at
        // 2560 px, which silently halves the resolution of every screenshot.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelScale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((CGFloat(display.width) * pixelScale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * pixelScale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let captureStarted = DispatchTime.now().uptimeNanoseconds
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            NSLog("[Capture] ScreenCaptureKit image in %.0f ms",
                  Double(DispatchTime.now().uptimeNanoseconds - captureStarted) / 1_000_000)
            return ScreenSnapshot(
                image: image,
                screen: screen,
                displayID: displayID,
                screenFrame: screen.frame,
                scale: CGFloat(image.width) / max(1, screen.frame.width)
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    private static func captureWithSystemTool(
        screen: NSScreen
    ) async throws -> ScreenSnapshot {
        guard let index = NSScreen.screens.firstIndex(of: screen) else {
            throw ScreenCaptureError.displayNotFound
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotLab-\(UUID().uuidString).png")

        let result: CGImage = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [
                "-x",
                "-D\(index + 1)",
                outputURL.path,
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScreenCaptureError.captureFailed(
                    message?.isEmpty == false ? message! : "screencapture failed"
                )
            }

            guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else {
                throw ScreenCaptureError.captureFailed("无法读取系统截图")
            }
            try? FileManager.default.removeItem(at: outputURL)
            return image
        }.value

        return ScreenSnapshot(
            image: result,
            screen: screen,
            displayID: displayID(for: screen),
            screenFrame: screen.frame,
            scale: CGFloat(result.width) / max(1, screen.frame.width)
        )
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        return CGDirectDisplayID(screenNumber?.uint32Value ?? CGMainDisplayID())
    }

    static func captureWindow(ownerPID: pid_t) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == ownerPID
                && window.windowLayer == 0
                && window.frame.width >= 80
                && window.frame.height >= 60
        }
        guard let window = candidates.max(by: { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return !lhs.isActive
            }
            return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else {
            throw ScreenCaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}

enum ImageCropper {
    static func crop(
        snapshot: ScreenSnapshot,
        localSelection: CGRect
    ) -> CGImage? {
        let scale = snapshot.scale
        let pixelWidth = CGFloat(snapshot.image.width)
        let pixelHeight = CGFloat(snapshot.image.height)

        let pixelRect = CGRect(
            x: localSelection.minX * scale,
            y: (snapshot.screenFrame.height - localSelection.maxY) * scale,
            width: localSelection.width * scale,
            height: localSelection.height * scale
        ).integral

        let clamped = pixelRect.intersection(
            CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        )
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
            return nil
        }
        return snapshot.image.cropping(to: clamped)
    }
}
