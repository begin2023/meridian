import Foundation

public enum FanRPMCodec {
    public static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ", "f2sf":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui8":
            return bytes.count == 1 ? Double(bytes[0]) : nil
        default:
            return nil
        }
    }

    public static func encode(_ rpm: Double, type: String, size: Int) -> [UInt8]? {
        guard rpm.isFinite else { return nil }
        switch type {
        case "flt ", "f2sf":
            guard size == 4, abs(rpm) <= Double(Float.greatestFiniteMagnitude) else { return nil }
            return withUnsafeBytes(of: Float(rpm).bitPattern.littleEndian) { Array($0) }
        case "fpe2":
            guard size == 2, rpm >= 0, rpm <= Double(UInt16.max) / 4 else { return nil }
            let value = UInt16((rpm * 4).rounded())
            return [UInt8(value >> 8), UInt8(value & 0xFF)]
        case "ui16":
            guard size == 2, rpm >= 0, rpm <= Double(UInt16.max) else { return nil }
            let value = UInt16(rpm.rounded())
            return [UInt8(value >> 8), UInt8(value & 0xFF)]
        case "ui8":
            guard size == 1, rpm >= 0, rpm <= Double(UInt8.max) else { return nil }
            return [UInt8(rpm.rounded())]
        default:
            return nil
        }
    }
}

public struct FanCommand: Codable {
    public var expiresAt: Double
    public var targets: [String: Double?]
    public var modes: [String: Int]?
    public init(expiresAt: Double, targets: [String: Double?], modes: [String: Int]?) {
        self.expiresAt = expiresAt; self.targets = targets; self.modes = modes
    }

    public struct Setting {
        public let mode: UInt8
        public let rpm: Double?
    }

    public func validated(now: Double, bounds: [Int: ClosedRange<Double>]) throws -> [Int: Setting] {
        func invalid() -> NSError { NSError(domain: "FanCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的风扇控制请求。"]) }
        let modes = self.modes ?? [:]
        guard expiresAt.isFinite, targets.count <= 10, modes.count <= 10, now.isFinite else { throw invalid() }
        if expiresAt == 0 {
            guard targets.isEmpty, modes.values.allSatisfy({ $0 == 0 }) else { throw invalid() }
        } else { guard expiresAt > now, expiresAt - now <= 10 else { throw invalid() } }
        var result: [Int: Setting] = [:]
        for key in Set(targets.keys).union(modes.keys) {
            guard let index = Int(key), key == String(index), (0..<10).contains(index),
                  let range = bounds[index], range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound > 0, range.upperBound >= range.lowerBound, range.upperBound <= 65_535,
                  let mode = modes[key], mode == 0 || mode == 1 else { throw invalid() }
            if mode == 1 {
                guard let optional = targets[key], let rpm = optional, rpm.isFinite else { throw invalid() }
                result[index] = Setting(mode: 1, rpm: min(max(rpm, range.lowerBound), range.upperBound))
            } else {
                guard targets[key] == nil else { throw invalid() }
                result[index] = Setting(mode: 0, rpm: nil)
            }
        }
        return result
    }
}
