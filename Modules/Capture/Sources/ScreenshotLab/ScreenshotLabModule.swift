import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

enum ScreenshotLabRuntime {
    static var isEmbedded = false
}

enum ScreenshotLabIdentity {
    static var displayName: String {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    static var buildVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0"
    }
}

public enum ScreenshotLabModuleError: Error, LocalizedError {
    case invalidPayload(String)
    case invalidSettings(String)
    case revisionConflict(expected: Int, actual: Int)
    case unsupportedCommand(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let message):
            return "Invalid payload: \(message)"
        case .invalidSettings(let message):
            return "Invalid settings: \(message)"
        case .revisionConflict(let expected, let actual):
            return "Settings revision conflict: expected \(expected), actual \(actual)"
        case .unsupportedCommand(let command):
            return "Unsupported command: \(command)"
        }
    }
}

/// Process-local facade used by ScreenshotLab standalone and by CaptureAgent.
///
/// The Agent owns capture windows, editors, pins, OCR tasks and image history.
/// Product-level preferences, login items and global shortcuts remain Shell
/// responsibilities. Calls must be made on the main thread because the facade
/// creates and manipulates AppKit windows.
@MainActor
public final class ScreenshotLabModule: NSObject, NSApplicationDelegate {
    public static let moduleID = "capture"
    public static let protocolMajor = 1
    public static let settingsSchemaVersion = 1
    public static let capabilities = [
        "capture", "annotate", "pin", "ocr", "history", "gif",
    ]

    public var onShowPreferences: (() -> Void)? {
        didSet {
            appDelegate.onShowPreferences = onShowPreferences
        }
    }

    private let embedded: Bool
    private let appDelegate: AppDelegate

    public init(embedded: Bool = true) {
        self.embedded = embedded
        ScreenshotLabRuntime.isEmbedded = embedded
        appDelegate = AppDelegate(embedded: embedded)
        super.init()
        appDelegate.onShowPreferences = onShowPreferences
    }

    public func start() {
        appDelegate.start()
    }

    public func stop() {
        appDelegate.stop()
    }

    public func showPreferences() {
        appDelegate.showPreferences()
    }

    // MARK: 类型化动作（宿主直接调用，无需字符串命令）

    public func beginCapture() { appDelegate.beginCapture() }
    public func beginOCRCapture() { appDelegate.beginOCRCapture() }
    public func beginPinCapture() { appDelegate.beginPinCapture() }
    public func captureLastArea() { appDelegate.captureLastArea() }
    public func captureFullScreen() { appDelegate.captureFullScreen() }
    public func captureActiveWindow() { appDelegate.captureActiveWindow() }
    public func captureDelayed(seconds: TimeInterval) { appDelegate.captureDelayed(seconds: seconds) }
    public func beginGIF() { appDelegate.beginGIFSelection() }
    public func stopGIF(save: Bool = true) { appDelegate.stopGIFRecording(save: save) }
    public var isGIFRecording: Bool { appDelegate.isGIFRecording }
    public func showHistory() { appDelegate.showScreenshotHistory() }
    public func openImagePanel() { appDelegate.beginOpenImagePanel() }
    public func openImage(at url: URL) { appDelegate.openImage(at: url) }
    public var pinCount: Int { appDelegate.pinCount }
    public func showAllPins() { appDelegate.showAllPins() }
    public func hideAllPins() { appDelegate.hideAllPins() }
    public func closeAllPins() { appDelegate.closeAllPins() }
    public var screenPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    public func summary() -> [String: Any] {
        appDelegate.summary(embedded: embedded)
    }

    /// Returns only module-owned values. Presentation metadata belongs in the
    /// Shell's settings field descriptions, not in this data snapshot.
    public func settingsSnapshot() -> [String: Any] {
        let settings = AppSettings.shared
        var snapshot: [String: Any] = [
            "schemaVersion": Self.settingsSchemaVersion,
            "revision": settings.revision,
            "captureHotKey": [
                "keyCode": Int(settings.captureHotKey.keyCode),
                "modifiers": Int(settings.captureHotKey.modifiers),
                "name": settings.captureHotKey.name,
            ],
            "gifHotKey": [
                "keyCode": Int(settings.gifHotKey.keyCode),
                "modifiers": Int(settings.gifHotKey.modifiers),
                "name": settings.gifHotKey.name,
            ],
            "copyImageAsFile": settings.copyImageAsFile,
            "quickSaveDirectory": settings.quickSaveDirectory.path,
            "screenshotScale": settings.screenshotScale,
            "screenshotHistoryLimit": settings.screenshotHistoryLimit,
            "gifMaximumWidth": settings.gifMaximumWidth,
            "gifFramesPerSecond": settings.gifFramesPerSecond,
        ]
        if let origin = settings.ocrPanelOrigin {
            snapshot["ocrPanelOrigin"] = [
                "x": Double(origin.x),
                "y": Double(origin.y),
            ]
        } else {
            snapshot["ocrPanelOrigin"] = NSNull()
        }
        if !embedded {
            snapshot["launchAtLogin"] = settings.launchAtLoginEnabled
        }
        return snapshot
    }

    /// Validates and atomically applies the validated value set. The return
    /// shape is intentionally small for the stdio IPC bridge.
    public func updateSettings(_ changes: [String: Any]) -> [String: Any] {
        do {
            try validateAndApply(changes)
            return ["ok": true]
        } catch {
            return [
                "ok": false,
                "error": error.localizedDescription,
            ]
        }
    }

    /// Small allow-listed command dispatcher. Commands only start local work
    /// and return promptly; capture, OCR and GIF progress remain event-driven.
    public func execute(
        command: String,
        payload: [String: Any] = [:]
    ) -> [String: Any] {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result: [String: Any]
            switch normalized {
            case "ping":
                result = [
                    "moduleID": Self.moduleID,
                    "protocolMajor": Self.protocolMajor,
                    "settingsSchemaVersion": Self.settingsSchemaVersion,
                    "buildVersion": ScreenshotLabIdentity.buildVersion,
                    "capabilities": Self.capabilities,
                    "started": appDelegate.isStarted,
                ]
            case "summary", "summary.get":
                result = summary()
            case "settings.snapshot", "settings.get":
                result = settingsSnapshot()
            case "settings.update":
                let changes: [String: Any]
                if let nested = payload["settings"] as? [String: Any] {
                    var merged = nested
                    if let expected = payload["expectedRevision"] {
                        merged["expectedRevision"] = expected
                    }
                    changes = merged
                } else {
                    changes = payload.filter { $0.key != "requestID" }
                }
                let update = updateSettings(changes)
                if update["ok"] as? Bool == false {
                    return [
                        "ok": false,
                        "command": normalized,
                        "error": update["error"] as? String
                            ?? "Settings update failed",
                    ]
                }
                result = update
            case "capture", "capture.begin":
                appDelegate.beginCapture()
                result = ["accepted": true]
            case "capture.lastArea":
                appDelegate.captureLastArea()
                result = ["accepted": true]
            case "capture.fullScreen":
                appDelegate.captureFullScreen()
                result = ["accepted": true]
            case "capture.window":
                try appDelegate.captureActiveWindowForAPI()
                result = ["accepted": true]
            case "capture.delayed":
                let seconds = try optionalDouble(
                    payload["seconds"],
                    key: "seconds"
                ) ?? 3
                guard (0...60).contains(seconds) else {
                    throw ScreenshotLabModuleError.invalidPayload(
                        "seconds must be between 0 and 60"
                    )
                }
                appDelegate.captureDelayed(seconds: seconds)
                result = ["accepted": true]
            case "gif.begin":
                appDelegate.beginGIFSelection()
                result = ["accepted": true]
            case "gif.stop":
                appDelegate.stopGIFRecording(save: true)
                result = ["accepted": true]
            case "gif.cancel":
                appDelegate.stopGIFRecording(save: false)
                result = ["accepted": true]
            case "history.show":
                appDelegate.showScreenshotHistory()
                result = ["accepted": true]
            case "image.open":
                appDelegate.beginOpenImagePanel()
                result = ["accepted": true]
            case "pins.show":
                appDelegate.showAllPins()
                result = ["accepted": true]
            case "pins.hide":
                appDelegate.hideAllPins()
                result = ["accepted": true]
            case "pins.close":
                appDelegate.closeAllPins()
                result = ["accepted": true]
            case "preferences.show":
                showPreferences()
                result = ["routedToHost": embedded]
            case "permission.status":
                result = [
                    "authorized": CGPreflightScreenCaptureAccess(),
                ]
            case "hotkeys.refresh":
                result = [
                    "registered": appDelegate.refreshHotKeys(),
                ]
            default:
                throw ScreenshotLabModuleError.unsupportedCommand(normalized)
            }
            return [
                "ok": true,
                "command": normalized,
                "result": result,
            ]
        } catch {
            return [
                "ok": false,
                "command": normalized,
                "error": error.localizedDescription,
            ]
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        appDelegate.showApplicationWindows()
        return false
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        appDelegate.handleOpenURLs(urls)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appDelegate.stop()
    }
}

private extension ScreenshotLabModule {
    func validateAndApply(_ changes: [String: Any]) throws {
        let allowedKeys: Set<String> = [
            "captureHotKey", "gifHotKey", "copyImageAsFile",
            "quickSaveDirectory", "screenshotScale",
            "screenshotHistoryLimit", "gifMaximumWidth",
            "gifFramesPerSecond", "ocrPanelOrigin",
        ]
        let metadataKeys: Set<String> = [
            "expectedRevision", "requestID", "schemaVersion", "revision",
        ]
        let unknown = Set(changes.keys).subtracting(allowedKeys.union(metadataKeys))
        guard unknown.isEmpty else {
            throw ScreenshotLabModuleError.invalidSettings(
                "unknown keys: \(unknown.sorted().joined(separator: ", "))"
            )
        }

        let settings = AppSettings.shared
        if let schema = try optionalInt(
            changes["schemaVersion"],
            key: "schemaVersion"
        ), schema != Self.settingsSchemaVersion {
            throw ScreenshotLabModuleError.invalidSettings(
                "unsupported schemaVersion \(schema)"
            )
        }
        if let expected = try optionalInt(
            changes["expectedRevision"],
            key: "expectedRevision"
        ), expected != settings.revision {
            throw ScreenshotLabModuleError.revisionConflict(
                expected: expected,
                actual: settings.revision
            )
        }

        var captureHotKey: HotKeyChoice?
        var gifHotKey: HotKeyChoice?
        var copyImageAsFile: Bool?
        var quickSaveDirectory: URL?
        var screenshotScale: Double?
        var screenshotHistoryLimit: Int?
        var gifMaximumWidth: Int?
        var gifFramesPerSecond: Int?
        var hasOCRPanelOrigin = false
        var ocrPanelOrigin: CGPoint?

        if let value = changes["captureHotKey"] {
            captureHotKey = try hotKey(value, key: "captureHotKey")
        }
        if let value = changes["gifHotKey"] {
            gifHotKey = try hotKey(value, key: "gifHotKey")
        }
        if let value = changes["copyImageAsFile"] {
            copyImageAsFile = try bool(value, key: "copyImageAsFile")
        }
        if let value = changes["quickSaveDirectory"] {
            guard let path = value as? String, path.hasPrefix("/") else {
                throw ScreenshotLabModuleError.invalidSettings(
                    "quickSaveDirectory must be an absolute path"
                )
            }
            if path != settings.quickSaveDirectory.path {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw ScreenshotLabModuleError.invalidSettings(
                        "quickSaveDirectory must be an existing directory"
                    )
                }
            }
            quickSaveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let value = changes["screenshotScale"] {
            let scale = try double(value, key: "screenshotScale")
            guard [1.0, 0.75, 0.5, 0.25].contains(scale) else {
                throw ScreenshotLabModuleError.invalidSettings(
                    "screenshotScale must be 1, 0.75, 0.5 or 0.25"
                )
            }
            screenshotScale = scale
        }
        if let value = changes["screenshotHistoryLimit"] {
            let limit = try int(value, key: "screenshotHistoryLimit")
            guard (1...100).contains(limit) else {
                throw ScreenshotLabModuleError.invalidSettings(
                    "screenshotHistoryLimit must be between 1 and 100"
                )
            }
            screenshotHistoryLimit = limit
        }
        if let value = changes["gifMaximumWidth"] {
            let width = try int(value, key: "gifMaximumWidth")
            guard [480, 640, 960, 1280].contains(width) else {
                throw ScreenshotLabModuleError.invalidSettings(
                    "gifMaximumWidth must be 480, 640, 960 or 1280"
                )
            }
            gifMaximumWidth = width
        }
        if let value = changes["gifFramesPerSecond"] {
            let fps = try int(value, key: "gifFramesPerSecond")
            guard [5, 10, 15, 20].contains(fps) else {
                throw ScreenshotLabModuleError.invalidSettings(
                    "gifFramesPerSecond must be 5, 10, 15 or 20"
                )
            }
            gifFramesPerSecond = fps
        }
        if let value = changes["ocrPanelOrigin"] {
            hasOCRPanelOrigin = true
            if !(value is NSNull) {
                let origin = try point(value, key: "ocrPanelOrigin")
                ocrPanelOrigin = origin
            }
        }

        if let captureHotKey, let gifHotKey, captureHotKey == gifHotKey {
            throw ScreenshotLabModuleError.invalidSettings(
                "captureHotKey and gifHotKey must differ"
            )
        }
        if let captureHotKey, changes["gifHotKey"] == nil,
           captureHotKey == settings.gifHotKey {
            throw ScreenshotLabModuleError.invalidSettings(
                "captureHotKey and gifHotKey must differ"
            )
        }
        if let gifHotKey, changes["captureHotKey"] == nil,
           gifHotKey == settings.captureHotKey {
            throw ScreenshotLabModuleError.invalidSettings(
                "captureHotKey and gifHotKey must differ"
            )
        }

        if let captureHotKey { settings.captureHotKey = captureHotKey }
        if let gifHotKey { settings.gifHotKey = gifHotKey }
        if let copyImageAsFile { settings.copyImageAsFile = copyImageAsFile }
        if let quickSaveDirectory { settings.quickSaveDirectory = quickSaveDirectory }
        if let screenshotScale { settings.screenshotScale = screenshotScale }
        if let screenshotHistoryLimit {
            settings.screenshotHistoryLimit = screenshotHistoryLimit
        }
        if let gifMaximumWidth { settings.gifMaximumWidth = gifMaximumWidth }
        if let gifFramesPerSecond {
            settings.gifFramesPerSecond = gifFramesPerSecond
        }
        if hasOCRPanelOrigin { settings.ocrPanelOrigin = ocrPanelOrigin }
        appDelegate.refreshSettingsAfterExternalUpdate()
    }

    func hotKey(_ value: Any, key: String) throws -> HotKeyChoice {
        guard let object = value as? [String: Any],
              let keyCode = try optionalInt(object["keyCode"], key: "\(key).keyCode"),
              let modifiers = try optionalInt(
                object["modifiers"],
                key: "\(key).modifiers"
              ),
              (0...127).contains(keyCode),
              modifiers >= 0,
              UInt64(modifiers) <= UInt64(UInt32.max) else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must contain valid keyCode and modifiers"
            )
        }
        return HotKeyChoice(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers)
        )
    }

    func bool(_ value: Any, key: String) throws -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be a boolean"
            )
        }
        return number.boolValue
    }

    func int(_ value: Any, key: String) throws -> Int {
        guard let result = try optionalInt(value, key: key) else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be an integer"
            )
        }
        return result
    }

    func optionalInt(_ value: Any?, key: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be an integer"
            )
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max) else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be an integer"
            )
        }
        return Int(doubleValue)
    }

    func double(_ value: Any, key: String) throws -> Double {
        guard let result = try optionalDouble(value, key: key) else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be a number"
            )
        }
        return result
    }

    func optionalDouble(_ value: Any?, key: String) throws -> Double? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be a number"
            )
        }
        let result = number.doubleValue
        guard result.isFinite else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must be finite"
            )
        }
        return result
    }

    func point(_ value: Any, key: String) throws -> CGPoint {
        guard let object = value as? [String: Any],
              let x = try optionalDouble(object["x"], key: "\(key).x"),
              let y = try optionalDouble(object["y"], key: "\(key).y") else {
            throw ScreenshotLabModuleError.invalidSettings(
                "\(key) must contain numeric x and y"
            )
        }
        return CGPoint(x: x, y: y)
    }
}
