import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ServiceManagement

struct HotKeyChoice: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// ⌘⇧2
    static let captureDefault = HotKeyChoice(
        keyCode: 19,
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// ⌥⇧G
    static let gifDefault = HotKeyChoice(
        keyCode: 5,
        modifiers: UInt32(optionKey | shiftKey)
    )

    var name: String {
        Self.modifierSymbols(for: modifiers) + Self.keyName(for: UInt16(keyCode))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) {
            value |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            value |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            value |= UInt32(cmdKey)
        }
        return value
    }

    static func modifierSymbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 {
            symbols += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            symbols += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            symbols += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            symbols += "⌘"
        }
        return symbols
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] {
            return special
        }
        if let character = baseCharacter(for: keyCode) {
            let trimmed = character.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.uppercased()
            }
        }
        return "Key\(keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        115: "Home",
        116: "PgUp",
        117: "FwdDel",
        119: "End",
        121: "PgDn",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        106: "F16",
        64: "F17",
        79: "F18",
        80: "F19",
        90: "F20",
    ]

    /// Uses the active keyboard layout so recorded keys show their real glyph.
    private static func baseCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(layoutPointer)
            .takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer
                .bindMemory(to: UCKeyboardLayout.self)
                .baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else {
            return nil
        }
        return String(utf16CodeUnits: characters, count: length)
    }
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let captureHotKey = "captureHotKey"
        static let gifHotKey = "gifHotKey"
        static let copyImageAsFile = "copyImageAsFile"
        static let quickSaveDirectory = "quickSaveDirectory"
        static let recentSavedFile = "recentSavedFile"
        static let screenshotHistoryLimit = "screenshotHistoryLimit"
        static let screenshotScale = "screenshotScale"
        static let gifMaximumWidth = "gifMaximumWidth"
        static let gifFramesPerSecond = "gifFramesPerSecond"
        static let ocrPanelOrigin = "ocrPanelOrigin"
        static let legacyHotKeyIndex = "hotKeyIndex"
        static let revision = "settingsRevision"
    }

    private let defaults: UserDefaults
    let suiteName: String?

    private init() {
        let requestedSuite = ProcessInfo.processInfo.environment[
            "MERIDIAN_MODULE_SUITE"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedSuite,
           !requestedSuite.isEmpty,
           let defaults = UserDefaults(suiteName: requestedSuite) {
            self.defaults = defaults
            suiteName = requestedSuite
        } else {
            self.defaults = .standard
            suiteName = nil
        }
    }

    /// Monotonic revision for the module-owned last-known-good settings.
    /// The Shell's authoritative configuration store remains separate.
    var revision: Int {
        defaults.object(forKey: Keys.revision) as? Int ?? 0
    }

    var captureHotKey: HotKeyChoice {
        get {
            storedHotKey(forKey: Keys.captureHotKey)
                ?? legacyCaptureHotKey
                ?? .captureDefault
        }
        set {
            storeHotKey(newValue, forKey: Keys.captureHotKey)
        }
    }

    var gifHotKey: HotKeyChoice {
        get {
            storedHotKey(forKey: Keys.gifHotKey) ?? .gifDefault
        }
        set {
            storeHotKey(newValue, forKey: Keys.gifHotKey)
        }
    }

    var copyImageAsFile: Bool {
        get {
            if defaults.object(forKey: Keys.copyImageAsFile) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.copyImageAsFile)
        }
        set {
            defaults.set(newValue, forKey: Keys.copyImageAsFile)
            markChanged()
        }
    }

    var quickSaveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.quickSaveDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("ScreenshotLab", isDirectory: true)
        }
        set {
            defaults.set(newValue.path, forKey: Keys.quickSaveDirectory)
            markChanged()
        }
    }

    var recentSavedFile: URL? {
        get {
            defaults.string(forKey: Keys.recentSavedFile).map(URL.init(fileURLWithPath:))
        }
        set {
            defaults.set(newValue?.path, forKey: Keys.recentSavedFile)
            markChanged()
        }
    }

    var screenshotScale: Double {
        get { defaults.object(forKey: Keys.screenshotScale) as? Double ?? 1 }
        set {
            defaults.set(newValue, forKey: Keys.screenshotScale)
            markChanged()
        }
    }

    var screenshotHistoryLimit: Int {
        get {
            let stored = defaults.object(forKey: Keys.screenshotHistoryLimit) as? Int ?? 10
            return max(1, min(100, stored))
        }
        set {
            defaults.set(max(1, min(100, newValue)), forKey: Keys.screenshotHistoryLimit)
            markChanged()
        }
    }

    var gifMaximumWidth: Int {
        get { defaults.object(forKey: Keys.gifMaximumWidth) as? Int ?? 960 }
        set {
            defaults.set(newValue, forKey: Keys.gifMaximumWidth)
            markChanged()
        }
    }

    var gifFramesPerSecond: Int {
        get { defaults.object(forKey: Keys.gifFramesPerSecond) as? Int ?? 10 }
        set {
            defaults.set(newValue, forKey: Keys.gifFramesPerSecond)
            markChanged()
        }
    }

    /// Where the user last parked the OCR result panel; nil docks it beside
    /// the capture. Stored as "x,y" — the SDK does not expose
    /// NSStringFromCGPoint to Swift.
    var ocrPanelOrigin: CGPoint? {
        get {
            guard let text = defaults.string(forKey: Keys.ocrPanelOrigin) else {
                return nil
            }
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else {
                return nil
            }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            if let newValue {
                defaults.set("\(newValue.x),\(newValue.y)", forKey: Keys.ocrPanelOrigin)
            } else {
                defaults.removeObject(forKey: Keys.ocrPanelOrigin)
            }
            markChanged()
        }
    }

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) throws -> Bool {
        guard !ScreenshotLabRuntime.isEmbedded else {
            throw NSError(
                domain: "ScreenshotLab.AppSettings",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CaptureAgent does not own the product login item.",
                ]
            )
        }
        guard #available(macOS 13.0, *) else {
            return false
        }

        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }

        markChanged()
        return SMAppService.mainApp.status == .enabled
    }

    private func markChanged() {
        defaults.set(revision + 1, forKey: Keys.revision)
    }

    private func storedHotKey(forKey key: String) -> HotKeyChoice? {
        guard let stored = defaults.dictionary(forKey: key),
              let keyCode = stored["keyCode"] as? Int,
              let modifiers = stored["modifiers"] as? Int else {
            return nil
        }
        return HotKeyChoice(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers)
        )
    }

    private func storeHotKey(_ choice: HotKeyChoice, forKey key: String) {
        defaults.set(
            [
                "keyCode": Int(choice.keyCode),
                "modifiers": Int(choice.modifiers),
            ],
            forKey: key
        )
        markChanged()
    }

    /// The previous release stored an index into a fixed preset list.
    private var legacyCaptureHotKey: HotKeyChoice? {
        guard defaults.object(forKey: Keys.captureHotKey) == nil,
              let index = defaults.object(forKey: Keys.legacyHotKeyIndex) as? Int else {
            return nil
        }
        let presets: [HotKeyChoice] = [
            HotKeyChoice(keyCode: 19, modifiers: UInt32(cmdKey | shiftKey)),
            HotKeyChoice(keyCode: 18, modifiers: UInt32(cmdKey | shiftKey)),
            HotKeyChoice(keyCode: 0, modifiers: UInt32(optionKey | shiftKey)),
            HotKeyChoice(keyCode: 0, modifiers: UInt32(controlKey | shiftKey)),
        ]
        guard presets.indices.contains(index) else {
            return nil
        }
        return presets[index]
    }
}
