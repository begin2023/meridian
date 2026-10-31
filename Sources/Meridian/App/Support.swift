import AppKit
import ApplicationServices
import IOKit.hid

/// 各功能模块通过 MERIDIAN_MODULE_SUITE 环境变量选择自己的 UserDefaults 域，
/// 在模块单例首次创建时读取。这里在创建期间临时设置，保证五个模块的键互不覆盖。
enum Suites {
    static let capture = "app.meridian.control.capture"
    static let pointer = "app.meridian.control.pointer"
    static let display = "app.meridian.control.display"
    static let thermal = "app.meridian.control.thermal"

    static func withSuite<T>(_ suite: String, _ body: () -> T) -> T {
        setenv("MERIDIAN_MODULE_SUITE", suite, 1)
        defer { unsetenv("MERIDIAN_MODULE_SUITE") }
        return body()
    }
}

enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: return "截图、识字与 GIF 录制需要读取屏幕内容"
        case .accessibility: return "平滑滚动与方向反转需要拦截滚轮事件"
        case .inputMonitoring: return "可选：用 F1/F2 调节外接显示器亮度"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    var settingsTitle: String {
        switch self {
        case .accessibility: return "设备控制设置"
        default: return "系统设置"
        }
    }

    var granted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum Permissions {
    /// 只发起系统授权请求，不主动打开「系统设置」。
    ///
    /// 先打开「系统设置」会把系统的授权提示挤掉；提示被挤掉时 macOS 不会把
    /// Meridian 登记到权限列表里，用户就只能手动点“+”添加。因此这里先让应用
    /// 成为前台应用，再请求权限，由系统提示引导用户去设置。
    static func request(_ permission: Permission) {
        NSApp.activate(ignoringOtherApps: true)
        switch permission {
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    static func open(_ permission: Permission) {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// 在访达中选中 Meridian.app，方便在权限列表里拖入或通过“+”添加。
    static func revealApp() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.executableURL ?? url])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 权限变更后部分权限（尤其是屏幕录制）需要重启应用才生效。
    static func relaunch() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var number = max(value, 0)
        var index = 0
        while number >= 1000, index < units.count - 1 {
            number /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(number)) B" }
        return number >= 100 ? String(format: "%.0f %@", number, units[index])
            : String(format: "%.1f %@", number, units[index])
    }

    static func rate(_ value: Double) -> String { bytes(value) + "/s" }

    /// 菜单栏小组件用的紧凑速率，如 “1.2M”。
    static func compactRate(_ value: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var number = max(value, 0)
        var index = 0
        while number >= 1000, index < units.count - 1 {
            number /= 1000
            index += 1
        }
        return number >= 10 || index == 0 ? String(format: "%.0f%@", number, units[index])
            : String(format: "%.1f%@", number, units[index])
    }

    static func memory(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    static func rpm(_ value: Double) -> String { "\(Int(value.rounded())) RPM" }
}

/// 定时检查三项权限，只在状态真正变化时发布，界面不必整页定时重建。
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var granted: [Permission: Bool] = [:]
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isGranted(_ permission: Permission) -> Bool { granted[permission] ?? false }

    func refresh() {
        var next: [Permission: Bool] = [:]
        for permission in Permission.allCases { next[permission] = permission.granted }
        if next != granted { granted = next }
    }
}
