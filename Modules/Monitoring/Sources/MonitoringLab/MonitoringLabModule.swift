import AppKit
import CoreFoundation

/// Stable façade used by the standalone app, Agent hosts and the unified Shell.
///
/// Embedded mode keeps sampling alive but creates no status-bar widgets or
/// local settings window. The host consumes `summary()` and routes settings via
/// `onShowPreferences`.
@MainActor
public final class MonitoringLabModule: NSObject, NSApplicationDelegate {
    public enum ModuleID: String, CaseIterable {
        case cpu
        case ram
        case net
        case disk
    }

    private let appDelegate = AppDelegate()
    private var settingsRevision = 0

    public var onShowPreferences: (() -> Void)? {
        didSet { appDelegate.onShowPreferences = onShowPreferences }
    }
    public init(embedded: Bool = true) {
        super.init()
        if embedded {
            AppSettings.shared.markEmbedded()
        }
        appDelegate.setEmbedded(embedded)
        appDelegate.onShowPreferences = { [weak self] in self?.onShowPreferences?() }
    }

    public func start() {
        appDelegate.start(embedded: appDelegate.isEmbedded)
    }

    public func stop() {
        appDelegate.stop()
    }

    public func showPreferences() {
        appDelegate.requestShowPreferences()
    }

    /// Live, JSON-safe read-only state for Shell/Agent rendering.
    public func summary() -> [String: Any] {
        var result = appDelegate.summary()
        result["schemaVersion"] = 1
        result["settingsRevision"] = settingsRevision
        result["warmup"] = modulesAreWarmingUp()
        return result
    }

    /// Pure key-value last-known-good settings. No widget, network or hardware
    /// side effects are triggered by reading this snapshot.
    public func settingsSnapshot() -> [String: Any] {
        let settings = AppSettings.shared
        var modules: [String: Any] = [:]
        var result: [String: Any] = [:]
        for module in ModuleID.allCases {
            let enabled = settings.moduleEnabled(module.rawValue)
            let style = settings.widgetStyle(for: module.rawValue).id
            modules[module.rawValue] = ["enabled": enabled, "widgetStyle": style]
            result["modules.\(module.rawValue).enabled"] = enabled
            result["modules.\(module.rawValue).widgetStyle"] = style
        }
        result["schemaVersion"] = 1
        result["revision"] = settingsRevision
        result["suite"] = settings.suiteName
        result["updateInterval"] = settings.updateInterval
        result["launchAtLogin"] = settings.launchAtLoginEnabled
        result["network.geoLookupEnabled"] = settings.networkGeoLookupEnabled
        result["modules"] = modules
        return result
    }

    /// Atomically validates and applies the supported monitoring settings.
    /// Login-item ownership and host widget placement remain with the Shell.
    public func updateSettings(_ changes: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        var nextInterval = settings.updateInterval
        var nextGeoLookup = settings.networkGeoLookupEnabled
        var nextModuleState: [String: (enabled: Bool?, style: WidgetStyle?)] = [:]

        for (rawKey, rawValue) in changes {
            switch rawKey {
            case "updateInterval":
                guard let value = integer(rawValue), (1...10).contains(value) else {
                    return failure("updateInterval must be an integer in 1...10")
                }
                nextInterval = value
            case "network.geoLookupEnabled":
                guard let value = boolean(rawValue) else {
                    return failure("network.geoLookupEnabled must be a boolean")
                }
                nextGeoLookup = value
            case "launchAtLogin":
                return failure("launchAtLogin is owned by the unified Shell")
            default:
                let parts = rawKey.split(separator: ".").map(String.init)
                guard parts.count == 3,
                      parts[0] == "modules",
                      let module = ModuleID(rawValue: parts[1]) else {
                    return failure("unknown settings key: \(rawKey)")
                }
                var state = nextModuleState[module.rawValue] ?? (nil, nil)
                switch parts[2] {
                case "enabled":
                    guard let value = boolean(rawValue) else {
                        return failure("\(rawKey) must be a boolean")
                    }
                    state.enabled = value
                case "widgetStyle":
                    guard let text = rawValue as? String,
                          let style = widgetStyle(from: text) else {
                        return failure("\(rawKey) must be one of text, bar, graph")
                    }
                    state.style = style
                default:
                    return failure("unknown settings key: \(rawKey)")
                }
                nextModuleState[module.rawValue] = state
            }
        }

        guard !nextGeoLookup || settings.networkGeoLookupPermitted else {
            return failure("network.geoLookupEnabled is disabled in embedded mode")
        }

        settings.updateInterval = nextInterval
        settings.networkGeoLookupEnabled = nextGeoLookup
        for (id, state) in nextModuleState {
            if let enabled = state.enabled {
                settings.setModuleEnabled(id, enabled)
            }
            if let style = state.style {
                settings.setWidgetStyle(style, for: id)
            }
        }
        settingsRevision += 1
        appDelegate.runtimeSettingsDidChange()
        return ["ok": true]
    }

    /// Narrow command surface. It deliberately has no arbitrary shell,
    /// UserDefaults, SMC or network primitive.
    public func execute(command: String, payload: [String: Any]) -> [String: Any] {
        switch command {
        case "summary", "status", "health":
            return ["ok": true, "result": summary()]
        case "settingsSnapshot", "getSettings":
            return ["ok": true, "result": settingsSnapshot()]
        case "updateSettings":
            guard let changes = payload["changes"] as? [String: Any] else {
                return failure("payload.changes must be an object")
            }
            return updateSettings(changes)
        case "showPreferences":
            showPreferences()
            return ["ok": true, "handled": appDelegate.isEmbedded ? onShowPreferences != nil : true]
        case "refresh":
            appDelegate.runtimeSettingsDidChange()
            return ["ok": true]
        case "showDetail":
            guard let id = payload["module"] as? String else {
                return failure("payload.module is required")
            }
            guard appDelegate.showDetail(moduleID: id) else {
                return failure("detail_unavailable")
            }
            return ["ok": true]
        case "cpu", "ram", "net", "disk":
            guard appDelegate.showDetail(moduleID: command) else {
                return failure("detail_unavailable")
            }
            return ["ok": true]
        case "showAllWindows":
            appDelegate.windowPresenceBringForward()
            return ["ok": true]
        default:
            return failure("unknown command: \(command)")
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    private func modulesAreWarmingUp() -> Bool {
        guard let modules = summaryModules() else { return false }
        return modules.contains { ($0["sampled"] as? Bool) != true }
    }

    private func summaryModules() -> [[String: Any]]? {
        let snapshot = appDelegate.summary()
        guard let modules = snapshot["modules"] as? [String: [String: Any]] else {
            return nil
        }
        return Array(modules.values)
    }

    private func widgetStyle(from text: String) -> WidgetStyle? {
        switch text.lowercased() {
        case "text": return .text
        case "bar": return .bar
        case "graph": return .graph
        default: return nil
        }
    }

    private func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }
}
