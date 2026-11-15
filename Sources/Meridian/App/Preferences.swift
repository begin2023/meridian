import AppKit
import Combine
import MeridianLocalization
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
        case .capture: return L("截图与识字", "Screenshot & OCR")
        case .display: return L("显示器", "Displays")
        case .thermal: return L("风扇与温度", "Fans & Temperature")
        case .pointer: return L("鼠标滚动", "Mouse Scrolling")
        case .telemetry: return L("系统监控", "System Monitor")
        }
    }

    var shortTitle: String {
        switch self {
        case .capture: return L("截图", "Screenshot")
        case .display: return L("显示器", "Displays")
        case .thermal: return L("散热", "Cooling")
        case .pointer: return L("滚动", "Scrolling")
        case .telemetry: return L("监控", "Monitor")
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
        case .capture: return L("区域截图、标注、贴图、文字识别、GIF 录制与历史", "Area capture, annotation, pins, text recognition, GIF recording, and history")
        case .display: return L("外接屏亮度、HiDPI 分辨率与刷新率、HDR 和虚拟屏", "External display brightness, HiDPI resolutions and refresh rates, HDR, and virtual displays")
        case .thermal: return L("温度传感器、风扇转速，自动 / 温控曲线 / 固定转速", "Temperature sensors and fan speeds: auto, temperature curve, or fixed speed")
        case .pointer: return L("鼠标滚轮平滑滚动与方向反转，可按应用设置例外", "Smooth scrolling and reverse direction for mouse wheels, with per-app exceptions")
        case .telemetry: return L("CPU、内存、网络、磁盘、GPU 实时数据与进程排行", "Live CPU, memory, network, disk, and GPU stats with top processes")
        }
    }
}

/// 菜单栏上可以单独常驻的数据小组件。
enum MenuWidget: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, network, disk, gpu, temperature, fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return L("内存", "Memory")
        case .network: return L("网速", "Network")
        case .disk: return L("磁盘", "Disk")
        case .gpu: return "GPU"
        case .temperature: return L("CPU 温度", "CPU Temperature")
        case .fan: return L("风扇转速", "Fan Speed")
        }
    }

    var feature: Feature {
        switch self {
        case .cpu, .memory, .network, .disk, .gpu: return .telemetry
        case .temperature, .fan: return .thermal
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
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
        static let publicIP = "v2.publicIPLookup"
        static let confirmURL = "v2.confirmURLActions"
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

    /// 界面语言。SwiftUI 页面随 `languageRevision` 重建；模块自建的 AppKit 窗口下次打开时生效。
    @Published var language: AppLanguage = AppLanguage.current {
        didSet {
            guard language != oldValue else { return }
            AppLanguage.current = language
            languageRevision += 1
        }
    }
    @Published private(set) var languageRevision = 0

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

    /// 是否允许调用第三方服务查询出口公网 IP。查询会把本机出口 IP 交给
    /// ipinfo.io / freeipapi.com，所以默认关闭，只在用户明确开启后才会请求。
    @Published var publicIPLookupEnabled: Bool {
        didSet { defaults.set(publicIPLookupEnabled, forKey: Key.publicIP) }
    }

    /// 外部链接触发的硬件操作（风扇、分辨率、HDR、截图等）是否先确认。
    /// 默认开启；用户在确认框里勾选“以后不再确认”后才会关闭。
    @Published var confirmURLActions: Bool {
        didSet { defaults.set(confirmURLActions, forKey: Key.confirmURL) }
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
        publicIPLookupEnabled = defaults.bool(forKey: Key.publicIP)
        // 未写入过时默认开启（getBool 会返回 false，所以用 object 判断是否已有值）。
        confirmURLActions = (defaults.object(forKey: Key.confirmURL) as? Bool) ?? true
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
