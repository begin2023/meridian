import Foundation

/// 供宿主进程内直接使用的类型化接口。
///
/// 读取走用户态 SMC；写入只经 root 守护进程的 desired.json 文件协议（见 ControlService）。
/// 宿主崩溃时控制文件约 10 秒后过期，守护进程把风扇交还系统自控。
public enum ThermalFanMode: Equatable, Sendable {
    case automatic
    case constant(rpm: Int)
    case sensor(sensorID: String, increaseAt: Double, maxAt: Double)

    init(_ mode: FanControlMode) {
        switch mode {
        case .automatic: self = .automatic
        case .constant(let rpm): self = .constant(rpm: rpm)
        case .sensor(let id, let low, let high): self = .sensor(sensorID: id, increaseAt: low, maxAt: high)
        }
    }

    var internalMode: FanControlMode {
        switch self {
        case .automatic: return .automatic
        case .constant(let rpm): return .constant(rpm: rpm)
        case .sensor(let id, let low, let high): return .sensor(sensorID: id, increaseAt: low, maxAt: high)
        }
    }
}

public struct ThermalFan: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let minimumRPM: Double
    public let currentRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let mode: ThermalFanMode
    /// 曲线/固定转速的封顶值（最大转速 × 上限比例）。
    public let effectiveMaximumRPM: Double
}

public struct ThermalSensor: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case cpu, gpu, other }
    public let id: String
    public let name: String
    public let celsius: Double
    public let kind: Kind
    /// 组平均伪传感器（如 CPU 核心平均）。
    public let isGroupAverage: Bool

    public init(id: String, name: String, celsius: Double, kind: Kind, isGroupAverage: Bool) {
        self.id = id
        self.name = name
        self.celsius = celsius
        self.kind = kind
        self.isGroupAverage = isGroupAverage
    }
}

public struct ThermalReading: Equatable, Sendable {
    public let fans: [ThermalFan]
    public let sensors: [ThermalSensor]
    public let timestamp: Date

    public var cpuAverage: Double? { average(.cpu) }
    public var gpuAverage: Double? { average(.gpu) }

    private func average(_ kind: ThermalSensor.Kind) -> Double? {
        if let group = sensors.first(where: { $0.isGroupAverage && $0.kind == kind }) { return group.celsius }
        let values = sensors.filter { $0.kind == kind && !$0.isGroupAverage }.map(\.celsius)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public enum ThermalPreset: Sendable {
    case automatic
    case fullBlast
    case sensorCurve
}

@MainActor
public final class ThermalEngine {
    public private(set) var latest: ThermalReading?
    public private(set) var openError: String?
    public var onUpdate: ((ThermalReading) -> Void)?

    private let client = SMCClient()
    private var monitor: MonitorService?
    private var control: ControlService?
    private var latestInternal: MonitorUpdate?
    private var groupIDs: Set<String> = []
    /// 本进程是否写过非自动的控制文件；全部回到自动后只发一次归还命令。
    private var controlling = false

    public init() {}

    public var isRunning: Bool { monitor != nil }

    public func start() {
        guard monitor == nil else { return }
        do {
            if !client.isOpen { try client.open() }
            openError = nil
        } catch {
            openError = String(describing: error)
            return
        }
        let database = SensorDatabase.load()
        groupIDs = Set(database.groupedSensors.map(\.slug))
        let service = MonitorService(client: client, database: database)
        control = ControlService(client: client)
        service.onUpdate = { [weak self] update in
            self?.handle(update)
        }
        monitor = service
        service.start()
    }

    /// 停止监控，并把本进程接管过的风扇交还系统。
    public func stop() {
        returnAllToAutomaticNow()
        monitor?.stop()
        monitor = nil
        client.close()
    }

    public func refreshNow() { monitor?.refreshNow() }

    public var refreshInterval: TimeInterval {
        get { AppSettings.shared.refreshInterval }
        set {
            AppSettings.shared.refreshInterval = min(max(newValue, 1), 5)
            if monitor != nil { monitor?.stop(); monitor = nil; start() }
        }
    }

    public var maximumRPMFraction: Double {
        get { AppSettings.shared.maximumRPMFraction }
        set { AppSettings.shared.maximumRPMFraction = min(max(newValue, 0.5), 1); pushControl() }
    }

    public var defaultIncreaseAt: Double {
        get { AppSettings.shared.defaultIncreaseAt }
        set { AppSettings.shared.defaultIncreaseAt = newValue }
    }

    public var defaultMaxAt: Double {
        get { AppSettings.shared.defaultMaxAt }
        set { AppSettings.shared.defaultMaxAt = newValue }
    }

    public var usesFahrenheit: Bool {
        get { AppSettings.shared.usesFahrenheit }
        set { AppSettings.shared.usesFahrenheit = newValue }
    }

    public func formatted(_ celsius: Double) -> String {
        AppSettings.shared.formattedTemperature(celsius)
    }

    // MARK: 控制

    public var daemonInstalled: Bool { DaemonInstaller().status == .enabled }

    /// 包内守护进程比已安装的新（应用升级后需要重新安装）。
    public var daemonNeedsUpdate: Bool { DaemonInstaller().needsUpdate }

    /// 弹出系统管理员授权框安装/更新守护进程；需随包携带守护进程与 plist 模板。
    public func installDaemon() throws { try DaemonInstaller().install() }

    public func uninstallDaemon() throws {
        returnAllToAutomaticNow()
        try DaemonInstaller().uninstall()
    }

    public func mode(for fanIndex: Int) -> ThermalFanMode {
        ThermalFanMode(AppSettings.shared.fanMode(for: fanIndex))
    }

    public func setMode(_ mode: ThermalFanMode, for fanIndex: Int) {
        AppSettings.shared.setFanMode(mode.internalMode, for: fanIndex)
        pushControl()
        republish()
    }

    public func applyPreset(_ preset: ThermalPreset) {
        guard let update = latestInternal ?? monitor?.latest else { return }
        let settings = AppSettings.shared
        for fan in update.fans {
            switch preset {
            case .automatic:
                settings.setFanMode(.automatic, for: fan.index)
            case .fullBlast:
                settings.setFanMode(.constant(rpm: Int(fan.maximumRPM)), for: fan.index)
            case .sensorCurve:
                settings.setFanMode(.sensor(sensorID: "cpu_core_average",
                                            increaseAt: settings.defaultIncreaseAt,
                                            maxAt: settings.defaultMaxAt), for: fan.index)
            }
        }
        pushControl()
        republish()
    }

    public var isAnyFanManual: Bool { AppSettings.shared.hasCustomFanModes }

    /// 退出时调用：立即写归还命令，守护进程下一拍写 F{n}Md=0。
    public func returnAllToAutomaticNow() {
        guard controlling else { return }
        control?.stopControl()
        controlling = false
    }

    private func handle(_ update: MonitorUpdate) {
        latestInternal = update
        pushControl()
        republish()
    }

    private func pushControl() {
        guard let control, let update = latestInternal else { return }
        if AppSettings.shared.hasCustomFanModes {
            control.apply(update)
            controlling = true
        } else if controlling {
            control.apply(update) // 先登记风扇列表，stopControl 据此写归还模式
            control.stopControl()
            controlling = false
        }
    }

    private func republish() {
        guard let update = latestInternal else { return }
        let settings = AppSettings.shared
        let fans = update.fans.map { fan in
            ThermalFan(index: fan.index, name: fan.name == "风扇 \(fan.index)" ? "风扇 \(fan.index + 1)" : fan.name,
                       minimumRPM: fan.minimumRPM,
                       currentRPM: fan.currentRPM, maximumRPM: fan.maximumRPM,
                       targetRPM: fan.targetRPM, mode: ThermalFanMode(settings.fanMode(for: fan.index)),
                       effectiveMaximumRPM: settings.effectiveMaximumRPM(fan.maximumRPM))
        }
        let sensors = update.sensors.map { sensor -> ThermalSensor in
            let kind: ThermalSensor.Kind
            switch sensor.kind {
            case .cpu: kind = .cpu
            case .gpu: kind = .gpu
            case .other: kind = .other
            }
            return ThermalSensor(id: sensor.id, name: sensor.name, celsius: sensor.temperatureCelsius,
                                 kind: kind, isGroupAverage: groupIDs.contains(sensor.id))
        }
        let reading = ThermalReading(fans: fans, sensors: sensors, timestamp: update.timestamp)
        latest = reading
        onUpdate?(reading)
    }
}
