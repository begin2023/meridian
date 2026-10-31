import Foundation

/// 风扇控制模式：自动、固定转速与基于温度。
enum FanControlMode: Equatable, Codable {
    case automatic
    case constant(rpm: Int)
    /// 低于 increaseAt 保持最低转速，超过后线性提速，达到 maxAt 拉满。
    case sensor(sensorID: String, increaseAt: Double, maxAt: Double)

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}

struct FanSnapshot: Equatable {
    var index: Int
    var name: String
    var minimumRPM: Double
    var currentRPM: Double
    var maximumRPM: Double
    var targetRPM: Double
    /// F{i}Md 原始模式字节（语义待实验确认，仅展示）。
    var modeByte: UInt8

    var controlMode: FanControlMode {
        get { AppSettings.shared.fanMode(for: index) }
    }
}

enum SensorKind: Equatable {
    case cpu
    case gpu
    case other
}

struct SensorSnapshot: Equatable {
    /// 组平均传感器使用稳定的组名标识。
    var id: String
    var name: String
    var temperatureCelsius: Double
    var kind: SensorKind
}

struct MonitorUpdate: Equatable {
    var fans: [FanSnapshot]
    var sensors: [SensorSnapshot]
    var timestamp: Date

    /// 菜单栏/窗口共用的“CPU 核心平均”等组平均在此计算。
    static func groupAverage(of sensors: [SensorSnapshot], kind: SensorKind) -> Double? {
        let matching = sensors.filter { $0.kind == kind && $0.temperatureCelsius > 0 }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.temperatureCelsius).reduce(0, +) / Double(matching.count)
    }
}

/// 根据温度曲线计算目标转速。
/// 所有目标都封顶在“有效最大转速”（F0Mx × maximumRPMFraction，默认 90%）以控制满载噪声。
enum FanSpeedCalculator {
    static func targetRPM(mode: FanControlMode, sensorValue: Double?, fan: FanSnapshot) -> Double? {
        let effectiveMax = AppSettings.shared.effectiveMaximumRPM(fan.maximumRPM)
        switch mode {
        case .automatic:
            return nil
        case .constant(let rpm):
            return Double(clamp(rpm, Int(fan.minimumRPM), Int(effectiveMax)))
        case .sensor(_, let increaseAt, let maxAt):
            guard let sensorValue, sensorValue > 0 else { return fan.minimumRPM }
            guard maxAt > increaseAt else { return effectiveMax }
            if sensorValue <= increaseAt {
                return fan.minimumRPM
            }
            if sensorValue >= maxAt {
                return effectiveMax
            }
            let fraction = (sensorValue - increaseAt) / (maxAt - increaseAt)
            let rpm = fan.minimumRPM + fraction * (effectiveMax - fan.minimumRPM)
            return (rpm * 10).rounded() / 10
        }
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        Swift.min(Swift.max(value, low), high)
    }
}
