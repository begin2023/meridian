import Foundation

/// UserDefaults 持久化：每个风扇的控制模式、监控间隔、单位、菜单栏显示。
final class AppSettings {
    static let shared = AppSettings()

    /// Agent/开发宿主可注入隔离域；`standalone.standard` 复用各独立应用的
    /// standard 域以保留既有设置；其他名称创建独立 suite。
    static let suiteEnvironmentKey = "MERIDIAN_MODULE_SUITE"
    static let standaloneSuiteName = "standalone.standard"

    let suiteName: String
    private let defaults: UserDefaults

    private init() {
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
        static let fanModes = "fanModes"
        static let refreshInterval = "refreshInterval"
        static let fahrenheit = "fahrenheit"
        static let menuBarShowsTemperature = "menuBarShowsTemperature"
        static let launchAtLogin = "launchAtLogin"
    }

    /// key = 风扇序号字符串，value = JSON 编码的 FanControlMode。
    private var fanModeStorage: [String: Data] {
        get { (defaults.dictionary(forKey: Keys.fanModes) as? [String: Data]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.fanModes) }
    }

    func fanMode(for fanIndex: Int) -> FanControlMode {
        guard let data = fanModeStorage["\(fanIndex)"] else { return .automatic }
        return (try? JSONDecoder().decode(FanControlMode.self, from: data)) ?? .automatic
    }

    func setFanMode(_ mode: FanControlMode, for fanIndex: Int) {
        var storage = fanModeStorage
        if mode.isAutomatic {
            storage.removeValue(forKey: "\(fanIndex)")
        } else {
            storage["\(fanIndex)"] = try? JSONEncoder().encode(mode)
        }
        fanModeStorage = storage
    }

    func resetAllFanModes() {
        defaults.removeObject(forKey: Keys.fanModes)
    }

    var hasCustomFanModes: Bool {
        !fanModeStorage.isEmpty
    }

    /// 监控轮询间隔（秒）。上下限保护 SMC 与 CPU 负载。
    var refreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.refreshInterval)
            return (1.0...5.0).contains(value) ? value : 1.5
        }
        set { defaults.set(newValue, forKey: Keys.refreshInterval) }
    }

    var usesFahrenheit: Bool {
        get { defaults.bool(forKey: Keys.fahrenheit) }
        set { defaults.set(newValue, forKey: Keys.fahrenheit) }
    }

    var menuBarShowsTemperature: Bool {
        get { defaults.bool(forKey: Keys.menuBarShowsTemperature) }
        set { defaults.set(newValue, forKey: Keys.menuBarShowsTemperature) }
    }

    /// 最近一次监控到的风扇最低/最高转速（温控曲线预览演算用）
    var knownMinimumRPM: Double? {
        get {
            let value = defaults.double(forKey: "knownMinimumRPM")
            return value > 0 ? value : nil
        }
        set { defaults.set(newValue ?? 0, forKey: "knownMinimumRPM") }
    }

    var knownMaximumRPM: Double? {
        get {
            let value = defaults.double(forKey: "knownMaximumRPM")
            return value > 0 ? value : nil
        }
        set { defaults.set(newValue ?? 0, forKey: "knownMaximumRPM") }
    }

    /// 有效最大转速比例（降低满载噪声，默认 90%）
    var maximumRPMFraction: Double {
        get {
            let value = defaults.double(forKey: "maximumRPMFraction")
            return (0.5...1.0).contains(value) ? value : 0.9
        }
        set { defaults.set(newValue, forKey: "maximumRPMFraction") }
    }

    /// 风扇有效最大转速 = F0Mx × 上限比例
    func effectiveMaximumRPM(_ maximumRPM: Double) -> Double {
        maximumRPM * maximumRPMFraction
    }

    /// 温控曲线默认阈值（新设置"基于温度"模式时使用，可在每风扇对话框覆盖）
    var defaultIncreaseAt: Double {
        get {
            let value = defaults.double(forKey: "defaultIncreaseAt")
            return (40.0...90.0).contains(value) ? value : 60.0
        }
        set { defaults.set(newValue, forKey: "defaultIncreaseAt") }
    }

    var defaultMaxAt: Double {
        get {
            let value = defaults.double(forKey: "defaultMaxAt")
            return (60.0...105.0).contains(value) ? value : 90.0
        }
        set { defaults.set(newValue, forKey: "defaultMaxAt") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    func formattedTemperature(_ celsius: Double) -> String {
        if usesFahrenheit {
            return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
        return String(format: "%.0f°C", celsius)
    }
}
