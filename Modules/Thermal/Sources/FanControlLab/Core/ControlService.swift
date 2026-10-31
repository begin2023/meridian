import Foundation

/// 风扇预设：系统自动与全速降温。
enum FanPreset: Equatable {
    case automatic
    case fullBlast
    /// 按设置里的全局曲线（默认 60–90°C）对所有风扇应用"基于温度"
    case sensorCurve
}

/// 控制文件协议（app → root 守护进程，见 docs/RELEASING.md）：
/// app 每拍计算期望转速写 desired.json；daemon 每秒读取并执行 SMC 写入。
/// expiresAt 过期后 daemon 停写，风扇回到系统自控。
struct ControlFile: Codable {
    var expiresAt: Double
    var targets: [String: Double?]
    /// 原始模式键值（F{n}Md），daemon 用 root keyinfo 确定尺寸后写入。
    var modes: [String: Int]?
}

/// 控制服务：按每个风扇的模式计算期望转速，落盘 desired.json 交给守护进程执行。
final class ControlService {
    private let client: SMCClient?
    private var latest: MonitorUpdate?

    init(client: SMCClient?) {
        self.client = client
    }

    /// 守护进程已安装时控制链路可用。
    var writesSupported: Bool {
        DaemonInstaller().status == .enabled
    }

    var controlFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FanControlLab/desired.json")
    }

    func apply(_ update: MonitorUpdate) {
        latest = update
        writeControlFile()
    }

    func refresh() {
        writeControlFile()
    }

    /// 停止控制：立即过期 + 所有已知风扇 F0Md 归零，风扇即刻回到系统自控。
    func stopControl() {
        var modes: [String: Int] = [:]
        if let update = latest {
            for fan in update.fans {
                modes["\(fan.index)"] = 0
            }
        }
        let file = ControlFile(expiresAt: 0, targets: [:], modes: modes)
        let directory = controlFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: controlFileURL, options: .atomic)
        }
    }

    // MARK: - 预设

    func applyPreset(_ preset: FanPreset) {
        guard let update = latest else { return }
        let settings = AppSettings.shared
        for fan in update.fans {
            switch preset {
            case .automatic:
                settings.setFanMode(.automatic, for: fan.index)
            case .fullBlast:
                settings.setFanMode(.constant(rpm: Int(settings.effectiveMaximumRPM(fan.maximumRPM))), for: fan.index)
            case .sensorCurve:
                settings.setFanMode(
                    .sensor(sensorID: "cpu_core_average",
                            increaseAt: settings.defaultIncreaseAt,
                            maxAt: settings.defaultMaxAt),
                    for: fan.index
                )
            }
        }
        refresh()
    }

    // MARK: - 控制文件

    private func writeControlFile() {
        guard let update = latest else { return }
        let settings = AppSettings.shared
        var targets: [String: Double?] = [:]
        var modes: [String: Int] = [:]
        for fan in update.fans {
            let mode = settings.fanMode(for: fan.index)
            if mode.isAutomatic {
                // 实测：F0Md=0 归还系统自控，必须在切自动时显式写
                modes["\(fan.index)"] = 0
                continue
            }
            let sensorValue: Double?
            if case .sensor(let sensorID, _, _) = mode {
                sensorValue = update.sensors.first { $0.id == sensorID }?.temperatureCelsius
            } else {
                sensorValue = nil
            }
            guard let target = FanSpeedCalculator.targetRPM(mode: mode, sensorValue: sensorValue, fan: fan) else {
                continue
            }
            // 实测：必须先 F0Md=1 接管手动模式，固件才会尊重 F0Tg；只写 F0Tg 会被覆盖
            modes["\(fan.index)"] = 1
            targets["\(fan.index)"] = target
        }
        let file = ControlFile(expiresAt: Date().timeIntervalSince1970 + 5,
                               targets: targets, modes: modes)
        let directory = controlFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: controlFileURL, options: .atomic)
        }
    }
}
