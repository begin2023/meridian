import Foundation
import PrivilegedSupport
import FanControlProtocol

/// 风扇预设：系统自动与全速降温。
enum FanPreset: Equatable {
    case automatic
    case fullBlast
    /// 按设置里的全局曲线（默认 60–90°C）对所有风扇应用"基于温度"
    case sensorCurve
}

/// Computes fan settings and publishes short-lived authenticated requests.
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

    private let sender = FanCommandSender()

    func apply(_ update: MonitorUpdate) {
        latest = update
        writeFanCommand()
    }

    func refresh() {
        writeFanCommand()
    }

    /// 停止控制：立即过期 + 所有已知风扇 F0Md 归零，风扇即刻回到系统自控。
    /// 停用/退出后进程可能随即结束，后台队列来不及发送，所以这里同步发送；
    /// 守护进程收到 expiresAt=0 会立刻恢复自动模式，发送失败由 5 秒租约兜底。
    func stopControl() {
        var modes: [String: Int] = [:]
        if let update = latest {
            for fan in update.fans {
                modes["\(fan.index)"] = 0
            }
        }
        let file = FanCommand(expiresAt: 0, targets: [:], modes: modes)
        guard let data = try? JSONEncoder().encode(file) else { return }
        _ = try? HelperSocket.request(data, label: DaemonInstaller.daemonLabel)
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

    private func writeFanCommand() {
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
        let file = FanCommand(expiresAt: Date().timeIntervalSince1970 + 5,
                               targets: targets, modes: modes)
        sender.submit(file)
    }
}

/// Coalesce updates rather than building an unbounded socket work queue.
private final class FanCommandSender {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.meridian.fan.commands", qos: .utility)
    private var pending: FanCommand?
    private var sending = false
    func submit(_ command: FanCommand) {
        lock.lock(); pending = command
        guard !sending else { lock.unlock(); return }
        sending = true; lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { sending = false; lock.unlock(); return }
                pending = nil; lock.unlock()
                if let data = try? JSONEncoder().encode(next) { _ = try? HelperSocket.request(data, label: DaemonInstaller.daemonLabel) }
            }
        }
    }
}
