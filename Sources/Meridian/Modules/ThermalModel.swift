import AppKit
import Combine
import FanControlLabKit
import MeridianLocalization

/// 风扇与温度：读取走用户态 SMC，控制由已安装的 root 守护进程执行。
@MainActor
final class ThermalModel: ObservableObject {
    @Published private(set) var reading: ThermalReading?
    @Published private(set) var running = false
    @Published private(set) var daemonInstalled = false
    @Published private(set) var daemonNeedsUpdate = false
    @Published var message: String?
    @Published private(set) var helperBusy = false

    @Published var refreshInterval = 1.5
    @Published var maxFraction = 0.9
    @Published var defaultIncreaseAt = 60.0
    @Published var defaultMaxAt = 90.0
    @Published var fahrenheit = false

    let engine: ThermalEngine

    init(suite: String) {
        engine = Suites.withSuite(suite) {
            let engine = ThermalEngine()
            _ = engine.refreshInterval
            return engine
        }
        engine.onUpdate = { [weak self] reading in self?.reading = reading }
        loadSettings()
        refreshDaemonState()
    }

    func start() {
        guard !running else { return }
        engine.start()
        running = engine.isRunning
        if let error = engine.openError { message = L("无法读取 SMC：\(error)", "Couldn't read SMC: \(error)") }
        refreshDaemonState()
    }

    /// 停用或退出时把风扇交还系统自动控制。
    func stop() {
        guard running else { return }
        engine.stop()
        running = false
        reading = nil
    }

    var fans: [ThermalFan] { reading?.fans ?? [] }

    var hottestCPU: Double? { reading?.cpuAverage }

    /// 控制中心用的总体模式（多风扇时取第一个风扇的模式作代表）。
    var overallPreset: Preset {
        guard let mode = fans.first?.mode else { return .automatic }
        switch mode {
        case .automatic: return .automatic
        case .sensor: return .curve
        case .constant(let rpm):
            if let fan = fans.first, Double(rpm) >= fan.maximumRPM * 0.99 { return .full }
            return .fixed
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case automatic, curve, fixed, full
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return L("自动", "Auto")
            case .curve: return L("温控", "Curve")
            case .fixed: return L("固定", "Fixed")
            case .full: return L("全速", "Full Speed")
            }
        }
        var symbol: String {
            switch self {
            case .automatic: return "a.circle"
            case .curve: return "thermometer.medium"
            case .fixed: return "slider.horizontal.3"
            case .full: return "wind"
            }
        }
    }

    func apply(_ preset: Preset) {
        guard preset == .automatic || ensureDaemon() else { return }
        switch preset {
        case .automatic: engine.applyPreset(.automatic)
        case .curve: engine.applyPreset(.sensorCurve)
        case .full: engine.applyPreset(.fullBlast)
        case .fixed:
            for fan in fans {
                let current = Int((fan.currentRPM / 100).rounded() * 100)
                let rpm = min(max(current, Int(fan.minimumRPM)), Int(fan.effectiveMaximumRPM))
                engine.setMode(.constant(rpm: rpm), for: fan.index)
            }
        }
        reading = engine.latest
    }

    func setMode(_ mode: ThermalFanMode, for fan: Int) {
        if mode != .automatic, !ensureDaemon() { return }
        engine.setMode(mode, for: fan)
        reading = engine.latest
    }

    func setFixedRPM(_ rpm: Double, for fan: Int) {
        setMode(.constant(rpm: Int((rpm / 50).rounded() * 50)), for: fan)
    }

    // MARK: 守护进程

    /// 写入控制前确认 root 守护进程在位且为当前版本；
    /// 缺失或应用升级后版本过期都引导安装（系统管理员授权框）。
    private func ensureDaemon() -> Bool {
        refreshDaemonState()
        if daemonInstalled && !daemonNeedsUpdate { return true }
        installDaemon()
        return daemonInstalled && !daemonNeedsUpdate
    }

    private func refreshDaemonState() {
        daemonInstalled = engine.daemonInstalled
        daemonNeedsUpdate = engine.daemonNeedsUpdate
    }

    func installDaemon() {
        guard !helperBusy else { return }
        helperBusy = true
        Task {
            defer { helperBusy = false; refreshDaemonState() }
            do { try await engine.installDaemon(); message = L("风扇控制服务已安装，请重新选择控制模式。", "Fan control service installed. Choose a control mode again.") }
            catch { message = L("安装风扇控制服务失败：\(error.localizedDescription)", "Couldn't install the fan control service: \(error.localizedDescription)") }
        }
    }

    func uninstallDaemon() {
        guard !helperBusy else { return }
        helperBusy = true
        Task {
            defer { helperBusy = false; refreshDaemonState() }
            do { try await engine.uninstallDaemon(); message = L("风扇控制服务已移除，风扇由系统自动控制。", "Fan control service removed. Fans are now controlled by the system.") }
            catch { message = L("移除失败：\(error.localizedDescription)", "Couldn't remove: \(error.localizedDescription)") }
        }
    }

    // MARK: 设置

    private func loadSettings() {
        refreshInterval = engine.refreshInterval
        maxFraction = engine.maximumRPMFraction
        defaultIncreaseAt = engine.defaultIncreaseAt
        defaultMaxAt = engine.defaultMaxAt
        fahrenheit = engine.usesFahrenheit
    }

    func saveSettings() {
        if engine.refreshInterval != refreshInterval { engine.refreshInterval = refreshInterval }
        engine.maximumRPMFraction = maxFraction
        engine.defaultIncreaseAt = defaultIncreaseAt
        engine.defaultMaxAt = max(defaultMaxAt, defaultIncreaseAt + 5)
        engine.usesFahrenheit = fahrenheit
    }

    func temperature(_ celsius: Double) -> String { engine.formatted(celsius) }
}
