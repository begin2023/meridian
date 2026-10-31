import AppKit
import CoreFoundation

/// Public lifecycle and JSON-command facade for the screen agent.
///
/// Embedded mode intentionally exposes only snapshots, settings, preferences
/// routing, and a read-only menu. DDC, mode, HDR, gamma, virtual-screen,
/// upsample, and override mutations remain available only to the standalone
/// app until a versioned, independently verified write protocol is adopted.
@MainActor
public final class DisplayLabModule {
    private let delegate: AppDelegate

    public var onShowPreferences: (() -> Void)? {
        didSet {
            delegate.onShowPreferences = onShowPreferences
        }
    }

    public init(embedded: Bool = true) {
        delegate = AppDelegate(embedded: embedded)
    }

    public func start() {
        delegate.start(handleTestArguments: !delegate.isEmbedded)
    }

    public func stop() {
        delegate.stop()
    }

    public func showPreferences() {
        delegate.showPreferences()
    }

    public func summary() -> [String: Any] {
        var result = delegate.summary()
        result["hardwareWritesEnabled"] = !delegate.isEmbedded
        return result
    }

    /// Pure, JSON-compatible module settings. Shell storage remains the
    /// authority; these values are the process's last-known-good snapshot.
    public func settingsSnapshot() -> [String: Any] {
        let settings = AppSettings.shared
        return [
            "smoothingEnabled": settings.smoothingEnabled,
            "smoothingDurationMilliseconds": settings.smoothingDurationMilliseconds,
            "combinedDimmingPoint": settings.combinedDimmingPoint,
            "ddcWriteCount": settings.ddcWriteCount,
            "ddcWriteDelayMilliseconds": settings.ddcWriteDelayMilliseconds,
            "ddcRetryCount": settings.ddcRetryCount,
            "showLowResolutionModes": settings.showLowResolutionModes,
            "takeOverBrightnessKeys": settings.takeOverBrightnessKeys,
            "showVirtualScreens": settings.showVirtualScreens,
            "launchAtLogin": settings.launchAtLogin,
        ]
    }

    public func updateSettings(_ changes: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        var actions: [() -> Void] = []
        let supportedKeys: Set<String> = [
            "smoothingEnabled", "smoothingDurationMilliseconds",
            "combinedDimmingPoint", "ddcWriteCount",
            "ddcWriteDelayMilliseconds", "ddcRetryCount",
            "showLowResolutionModes", "takeOverBrightnessKeys",
            "showVirtualScreens",
        ]
        if let unknown = changes.keys.first(where: { !supportedKeys.contains($0) }) {
            return [
                "ok": false,
                "error": "unknown_setting",
                "message": "Unknown setting: \(unknown)",
            ]
        }

        func boolValue(_ raw: Any?) -> Bool? {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID(),
                  let value = raw as? Bool else {
                return nil
            }
            return value
        }

        func numberValue(_ raw: Any?) -> Double? {
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID() {
                return value.doubleValue
            }
            return nil
        }

        let boolSetters: [(String, (Bool) -> Void)] = [
            ("smoothingEnabled", { settings.smoothingEnabled = $0 }),
            ("showLowResolutionModes", { settings.showLowResolutionModes = $0 }),
            ("takeOverBrightnessKeys", { settings.takeOverBrightnessKeys = $0 }),
            ("showVirtualScreens", { settings.showVirtualScreens = $0 }),
        ]
        for (key, setter) in boolSetters {
            guard let raw = changes[key] else { continue }
            guard let value = boolValue(raw) else {
                return invalidSetting(key, expected: "Bool")
            }
            actions.append { setter(value) }
        }

        let numberSetters: [(String, ClosedRange<Double>, (Double) -> Void)] = [
            ("smoothingDurationMilliseconds", 80.0...2000.0, {
                settings.smoothingDurationMilliseconds = $0
            }),
            ("combinedDimmingPoint", 0.0...0.6, {
                settings.combinedDimmingPoint = $0
            }),
        ]
        for (key, range, setter) in numberSetters {
            guard let raw = changes[key] else { continue }
            guard let value = numberValue(raw), value.isFinite, range.contains(value) else {
                return invalidSetting(key, expected: "finite number in \(range)")
            }
            actions.append { setter(value) }
        }

        let intSetters: [(String, ClosedRange<Int>, (Int) -> Void)] = [
            ("ddcWriteCount", 1...6, { settings.ddcWriteCount = $0 }),
            ("ddcWriteDelayMilliseconds", 2...100, { settings.ddcWriteDelayMilliseconds = $0 }),
            ("ddcRetryCount", 0...10, { settings.ddcRetryCount = $0 }),
        ]
        for (key, range, setter) in intSetters {
            guard let raw = changes[key] else { continue }
            guard let value = numberValue(raw),
                  value.isFinite,
                  value.rounded() == value,
                  value >= Double(range.lowerBound),
                  value <= Double(range.upperBound) else {
                return invalidSetting(key, expected: "integer in \(range)")
            }
            actions.append { setter(Int(value)) }
        }

        actions.forEach { $0() }
        if !actions.isEmpty {
            delegate.settingsDidChange()
        }
        return ["ok": true]
    }

    /// Embedded mode returns a read-only menu; the standalone app keeps its
    /// existing full control menu.
    public func makeMenu() -> NSMenu {
        delegate.isEmbedded ? makeReadOnlyMenu() : delegate.makeMenu()
    }

    public func showMenu() {
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    public func execute(command: String, payload: [String: Any]) -> [String: Any] {
        switch command {
        case "state.get", "state.getSummary", "summary", "screen.summary":
            return ["ok": true, "data": summary()]
        case "settings.snapshot", "settings.get", "getSettings":
            return ["ok": true, "settings": settingsSnapshot()]
        case "settings.update", "updateSettings":
            return updateSettings(payload)
        case "preferences.show", "showPreferences":
            showPreferences()
            return ["ok": true, "routed": onShowPreferences != nil]
        case "menu.show", "menu.request", "screen.showMenu":
            DispatchQueue.main.async { [weak self] in
                self?.showMenu()
            }
            return ["ok": true, "readOnly": delegate.isEmbedded]
        case "refresh", "screen.refresh":
            delegate.refreshDisplays()
            return ["ok": true, "data": summary()]
        case "module.start", "start":
            start()
            return ["ok": true, "started": true]
        case "module.stop", "stop":
            stop()
            return ["ok": true, "started": false]
        case let command where isHardwareWriteCommand(command):
            return [
                "ok": false,
                "error": "hardware_writes_disabled",
                "message": "Screen mutations are disabled in this agent session. Read-only summary and menu are available.",
            ]
        default:
            return [
                "ok": false,
                "error": "unsupported_command",
                "message": "Unknown screen command: \(command)",
            ]
        }
    }

    private func makeReadOnlyMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "显示器（只读）", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let displays = summary()["displays"] as? [[String: Any]] ?? []
        for display in displays {
            let name = display["name"] as? String ?? "显示器"
            let width = display["pixelWidth"] as? Int ?? 0
            let height = display["pixelHeight"] as? Int ?? 0
            let item = NSMenuItem(
                title: "\(name) — \(width)×\(height)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            if let mode = display["currentMode"] as? [String: Any],
               let label = mode["label"] as? String {
                item.toolTip = "当前模式：\(label)"
            }
            menu.addItem(item)
        }
        if displays.isEmpty {
            let item = NSMenuItem(title: "未检测到显示器", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let policy = NSMenuItem(
            title: "硬件写入已由安全策略禁用",
            action: nil,
            keyEquivalent: ""
        )
        policy.isEnabled = false
        menu.addItem(policy)

        let preferences = NSMenuItem(
            title: "打开统一设置…",
            action: #selector(AppDelegate.showPreferences),
            keyEquivalent: ""
        )
        preferences.target = delegate
        menu.addItem(preferences)
        return menu
    }

    private func isHardwareWriteCommand(_ command: String) -> Bool {
        let prefixes = [
            "brightness.", "mode.", "display.", "hdr.", "virtual.",
            "override.", "upsample.", "gamma.",
        ]
        let aliases: Set<String> = [
            "setBrightness", "switchMode", "restoreNativeMode", "toggleHDR",
            "createVirtualScreen", "disconnectVirtualScreen",
            "installDisplayOverride", "removeDisplayOverride",
            "enableUpsample", "disableUpsample",
        ]
        return aliases.contains(command) || prefixes.contains { command.hasPrefix($0) }
    }

    private func invalidSetting(_ key: String, expected: String) -> [String: Any] {
        [
            "ok": false,
            "error": "invalid_setting",
            "message": "\(key) must be \(expected)",
        ]
    }
}
