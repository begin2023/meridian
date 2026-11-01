import AppKit
import Combine
import FanControlLabKit

/// 风扇与温度：读取走用户态 SMC，控制由已安装的 root 守护进程执行。
@MainActor
final class ThermalModel: ObservableObject {
    @Published private(set) var reading: ThermalReading?
    @Published private(set) var running = false
    @Published private(set) var daemonInstalled = false
    @Published private(set) var daemonNeedsUpdate = false
    @Published var message: String?

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
        if let error = engine.openError { message = "无法读取 SMC：\(error)" }
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
            case .automatic: return "自动"
            case .curve: return "温控"
            case .fixed: return "固定"
            case .full: return "全速"
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
        guard ensureDaemon() else { return }
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
        do {
            try engine.installDaemon()
            message = "风扇控制服务已安装。"
        } catch {
            message = "安装风扇控制服务失败：\(error.localizedDescription)"
        }
        refreshDaemonState()
    }

    func uninstallDaemon() {
        do {
            try engine.uninstallDaemon()
            message = "风扇控制服务已移除，风扇由系统自动控制。"
        } catch {
            message = "移除失败：\(error.localizedDescription)"
        }
        refreshDaemonState()
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
