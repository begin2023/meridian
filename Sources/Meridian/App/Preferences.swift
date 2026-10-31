import AppKit
import Combine
import ServiceManagement

/// 工具箱里的五项功能。顺序即侧栏与控制中心的展示顺序。
enum Feature: String, CaseIterable, Identifiable, Codable {
    case capture
    case display
    case thermal
    case pointer
    case telemetry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "截图与识字"
        case .display: return "显示器"
        case .thermal: return "风扇与温度"
        case .pointer: return "鼠标滚动"
        case .telemetry: return "系统监控"
        }
    }

    var shortTitle: String {
        switch self {
        case .capture: return "截图"
        case .display: return "显示器"
        case .thermal: return "散热"
        case .pointer: return "滚动"
        case .telemetry: return "监控"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "viewfinder"
        case .display: return "display"
        case .thermal: return "fan"
        case .pointer: return "computermouse"
        case .telemetry: return "waveform.path.ecg"
        }
    }

    var tint: NSColor {
        switch self {
        case .capture: return .systemBlue
        case .display: return .systemIndigo
        case .thermal: return .systemOrange
        case .pointer: return .systemTeal
        case .telemetry: return .systemGreen
        }
    }

    var summary: String {
        switch self {
        case .capture: return "区域截图、标注、贴图、文字识别、GIF 录制与历史"
        case .display: return "外接屏亮度、分辨率与 5K HiDPI、HDR 和虚拟屏"
        case .thermal: return "温度传感器、风扇转速，自动 / 温控曲线 / 固定转速"
        case .pointer: return "鼠标滚轮平滑滚动与方向反转，可按应用设置例外"
        case .telemetry: return "CPU、内存、网络、磁盘实时数据与进程排行"
        }
    }
}

/// 菜单栏上可以单独常驻的数据小组件。
enum MenuWidget: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, network, disk, temperature, fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网速"
        case .disk: return "磁盘"
        case .temperature: return "CPU 温度"
        case .fan: return "风扇转速"
        }
    }

    var feature: Feature {
        switch self {
        case .cpu, .memory, .network, .disk: return .telemetry
        case .temperature, .fan: return .thermal
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 宿主自己的偏好。各功能的业务设置由对应模块保存在各自的域里。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabled = "v2.enabledFeatures"
        static let widgets = "v2.menuWidgets"
        static let appearance = "v2.appearance"
        static let hotKeys = "v2.hotKeys"
        static let telemetryInterval = "v2.telemetryInterval"
        static let onboarded = "v2.onboarded"
    }

    @Published var enabledFeatures: Set<Feature> {
        didSet { defaults.set(enabledFeatures.map(\.rawValue).sorted(), forKey: Key.enabled) }
    }

    @Published var menuWidgets: [MenuWidget] {
        didSet { defaults.set(menuWidgets.map(\.rawValue), forKey: Key.widgets) }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var hotKeys: [HotKeyAction: KeyCombo] {
        didSet {
            let encoded = hotKeys.reduce(into: [String: [String: Int]]()) { result, entry in
                result[entry.key.rawValue] = ["keyCode": Int(entry.value.keyCode), "modifiers": Int(entry.value.modifiers)]
            }
            defaults.set(encoded, forKey: Key.hotKeys)
        }
    }

    /// 监控采样间隔（秒）。弹出面板可见时自动提速到 1 秒。
    @Published var telemetryInterval: Double {
        didSet { defaults.set(telemetryInterval, forKey: Key.telemetryInterval) }
    }

    @Published private(set) var launchAtLogin: Bool = false

    var isFirstLaunch: Bool { !defaults.bool(forKey: Key.onboarded) }
    func markOnboarded() { defaults.set(true, forKey: Key.onboarded) }

    private init() {
        if let stored = defaults.array(forKey: Key.enabled) as? [String] {
            enabledFeatures = Set(stored.compactMap(Feature.init(rawValue:)))
        } else {
            enabledFeatures = Set(Feature.allCases)
        }
        if let stored = defaults.array(forKey: Key.widgets) as? [String] {
            var loadedWidgets = stored.compactMap(MenuWidget.init(rawValue:))
            if !defaults.bool(forKey: "v2.diskWidgetIntroduced") {
                loadedWidgets = MenuWidget.allCases.filter { loadedWidgets.contains($0) || $0 == .disk }
                defaults.set(true, forKey: "v2.diskWidgetIntroduced")
            }
            menuWidgets = loadedWidgets
        } else {
            // 默认就把风扇转速放在菜单栏上：用户反馈“风扇与转速显示不出来”，
            // 之前默认列表里没有风扇小组件。需要精简时可在“通用”里关掉。
            menuWidgets = [.cpu, .memory, .network, .disk, .fan]
            defaults.set(true, forKey: "v2.diskWidgetIntroduced")
        }
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        var keys = HotKeyAction.defaults
        if let stored = defaults.dictionary(forKey: Key.hotKeys) as? [String: [String: Int]] {
            for (name, value) in stored {
                guard let action = HotKeyAction(rawValue: name) else { continue }
                if let code = value["keyCode"], let modifiers = value["modifiers"], code >= 0 {
                    keys[action] = KeyCombo(keyCode: UInt32(code), modifiers: UInt32(modifiers))
                } else {
                    keys.removeValue(forKey: action)
                }
            }
            // 用户清除过的快捷键以 keyCode = -1 保存，避免默认值复活
            for (name, value) in stored where value["keyCode"] == -1 {
                if let action = HotKeyAction(rawValue: name) { keys.removeValue(forKey: action) }
            }
        }
        hotKeys = keys
        let interval = defaults.double(forKey: Key.telemetryInterval)
        telemetryInterval = (1...10).contains(interval) ? interval : 2
        refreshLaunchAtLogin()
    }

    func isEnabled(_ feature: Feature) -> Bool { enabledFeatures.contains(feature) }

    func setEnabled(_ feature: Feature, _ on: Bool) {
        if on { enabledFeatures.insert(feature) } else { enabledFeatures.remove(feature) }
    }

    func setHotKey(_ combo: KeyCombo?, for action: HotKeyAction) {
        var keys = hotKeys
        keys[action] = combo
        hotKeys = keys
        if combo == nil {
            var stored = defaults.dictionary(forKey: Key.hotKeys) as? [String: [String: Int]] ?? [:]
            stored[action.rawValue] = ["keyCode": -1, "modifiers": 0]
            defaults.set(stored, forKey: Key.hotKeys)
        }
    }

    func toggleWidget(_ widget: MenuWidget, _ on: Bool) {
        if on {
            guard !menuWidgets.contains(widget) else { return }
            menuWidgets = MenuWidget.allCases.filter { menuWidgets.contains($0) || $0 == widget }
        } else {
            menuWidgets.removeAll { $0 == widget }
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.appKitAppearance
    }

    // MARK: 登录时启动

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) -> String? {
        defer { refreshLaunchAtLogin() }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
