import AppKit
import ServiceManagement

enum WidgetStyle: Int {
    case text = 0
    case bar = 1
    case graph = 2

    var title: String {
        switch self {
        case .text: return "文本"
        case .bar: return "条形"
        case .graph: return "图表"
        }
    }

    var id: String {
        switch self {
        case .text: return "text"
        case .bar: return "bar"
        case .graph: return "graph"
        }
    }

    static let all: [WidgetStyle] = [.text, .bar, .graph]

    static func from(_ rawValue: Int) -> WidgetStyle {
        WidgetStyle(rawValue: rawValue) ?? .text
    }
}

final class AppSettings {
    static let shared = AppSettings()

    /// Agent/开发宿主可注入隔离域；默认沿用独立应用的 standard 域。
    /// `standalone.standard` 是逻辑名称，不创建同名 suite，避免破坏既有设置。
    static let suiteEnvironmentKey = "MERIDIAN_MODULE_SUITE"
    static let standaloneSuiteName = "standalone.standard"

    let suiteName: String
    private(set) var isEmbedded: Bool
    private let defaults: UserDefaults

    private init() {
        isEmbedded = ProcessInfo.processInfo.environment["MERIDIAN_EMBEDDED"] == "1"
        let requested = ProcessInfo.processInfo.environment[Self.suiteEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        suiteName = requested.flatMap { $0.isEmpty ? nil : $0 } ?? Self.standaloneSuiteName
        if suiteName == Self.standaloneSuiteName {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        }
    }

    private enum Keys {
        static let cpuEnabled = "cpuEnabled"
        static let ramEnabled = "ramEnabled"
        static let netEnabled = "netEnabled"
        static let diskEnabled = "diskEnabled"
        static let cpuWidgetStyle = "cpuWidgetStyle"
        static let ramWidgetStyle = "ramWidgetStyle"
        static let netWidgetStyle = "netWidgetStyle"
        static let diskWidgetStyle = "diskWidgetStyle"
        static let updateInterval = "updateInterval"
        static let launchAtLogin = "launchAtLoginHint"
        static let networkGeoLookupEnabled = "networkGeoLookupEnabled"
    }

    // MARK: - 模块开关

    var cpuEnabled: Bool {
        get { defaults.object(forKey: Keys.cpuEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.cpuEnabled) }
    }

    var ramEnabled: Bool {
        get { defaults.object(forKey: Keys.ramEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.ramEnabled) }
    }

    var netEnabled: Bool {
        get { defaults.object(forKey: Keys.netEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.netEnabled) }
    }

    var diskEnabled: Bool {
        get { defaults.object(forKey: Keys.diskEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.diskEnabled) }
    }

    func moduleEnabled(_ id: String) -> Bool {
        switch id {
        case "cpu": return cpuEnabled
        case "ram": return ramEnabled
        case "net": return netEnabled
        case "disk": return diskEnabled
        default: return false
        }
    }

    func setModuleEnabled(_ id: String, _ enabled: Bool) {
        switch id {
        case "cpu": cpuEnabled = enabled
        case "ram": ramEnabled = enabled
        case "net": netEnabled = enabled
        case "disk": diskEnabled = enabled
        default: break
        }
    }

    // MARK: - Widget 样式

    func widgetStyle(for id: String) -> WidgetStyle {
        let raw = defaults.integer(forKey: widgetStyleKey(id))
        return WidgetStyle.from(raw)
    }

    func setWidgetStyle(_ style: WidgetStyle, for id: String) {
        defaults.set(style.rawValue, forKey: widgetStyleKey(id))
    }

    private func widgetStyleKey(_ id: String) -> String {
        "\(id)WidgetStyle"
    }

    // MARK: - 采样间隔

    /// 全局采样间隔,单位秒,范围 1–10。
    var updateInterval: Int {
        get {
            let value = defaults.object(forKey: Keys.updateInterval) as? Int ?? 1
            return min(max(value, 1), 10)
        }
        set { defaults.set(min(max(newValue, 1), 10), forKey: Keys.updateInterval) }
    }

    /// 在线 IP 归属地查询必须显式开启；embedded 默认关闭。
    var networkGeoLookupEnabled: Bool {
        get {
            guard !isEmbedded else { return false }
            return defaults.object(forKey: Keys.networkGeoLookupEnabled) as? Bool ?? false
        }
        set {
            guard !isEmbedded else { return }
            defaults.set(newValue, forKey: Keys.networkGeoLookupEnabled)
        }
    }

    var networkGeoLookupPermitted: Bool { !isEmbedded }

    /// Embedded mode is a one-way safety latch. A host may mark the module
    /// embedded even when it did not launch through Meridian's environment.
    func markEmbedded() {
        isEmbedded = true
    }

    // MARK: - 开机自启

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        defaults.set(enabled, forKey: Keys.launchAtLogin)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("MonitoringLab: 设置开机自启失败 \(error.localizedDescription)")
            return false
        }
    }
}
