import Foundation
import FanControlProtocol
let bounds = [0: 1200.0...6000.0]
func reject(_ command: FanCommand, bounds: [Int: ClosedRange<Double>] = bounds) {
    do { _ = try command.validated(now: 100, bounds: bounds); fatalError("Expected invalid command") } catch {}
}
let low = try FanCommand(expiresAt: 105, targets: ["0": 0], modes: ["0": 1]).validated(now: 100, bounds: bounds)
precondition(low[0]?.rpm == 1200)
let high = try FanCommand(expiresAt: 105, targets: ["0": 90_000], modes: ["0": 1]).validated(now: 100, bounds: bounds)
precondition(high[0]?.rpm == 6000)
reject(FanCommand(expiresAt: 111, targets: [:], modes: [:]))
reject(FanCommand(expiresAt: 99, targets: [:], modes: [:]))
reject(FanCommand(expiresAt: 105, targets: ["0": .nan], modes: ["0": 1]))
reject(FanCommand(expiresAt: 105, targets: ["0": 3000], modes: ["0": 255]))
reject(FanCommand(expiresAt: 105, targets: ["00": 3000], modes: ["00": 1]))
reject(FanCommand(expiresAt: 105, targets: ["1": 3000], modes: ["1": 1]))
reject(FanCommand(expiresAt: 105, targets: [:], modes: ["0": 1]))
reject(FanCommand(expiresAt: 0, targets: ["0": 3000], modes: ["0": 1]))
let stop = try FanCommand(expiresAt: 0, targets: [:], modes: [:]).validated(now: 100, bounds: bounds)
precondition(stop.isEmpty)

// SMC 把转速存在不同类型的键里（flt / fpe2 / ui16 / ui8）；按实际键类型编解码。
func roundTrip(_ rpm: Double, type: String, size: Int, tolerance: Double = 1) {
    guard let encoded = FanRPMCodec.encode(rpm, type: type, size: size),
          let decoded = FanRPMCodec.decode(encoded, type: type) else { fatalError("codec \(type)") }
    precondition(abs(decoded - rpm) <= tolerance, "\(type) round-trip \(decoded) != \(rpm)")
}
roundTrip(1234.5, type: "flt ", size: 4)
roundTrip(1234.5, type: "fpe2", size: 2)
roundTrip(1234, type: "ui16", size: 2)
precondition(FanRPMCodec.encode(1234.5, type: "fpe2", size: 4) == nil)
precondition(FanRPMCodec.encode(.nan, type: "ui16", size: 2) == nil)
precondition(FanRPMCodec.encode(70_000, type: "ui16", size: 2) == nil)
precondition(FanRPMCodec.encode(200, type: "ui8", size: 1) == [200])
precondition(FanRPMCodec.encode(300, type: "ui8", size: 1) == nil)
precondition(FanRPMCodec.decode([0x00, 0x04, 0xD2], type: "fpe2") == nil)
precondition(FanRPMCodec.decode([0x04, 0xD2], type: "fpe2") == 308.5)
precondition(FanRPMCodec.decode([0x04, 0xD2], type: "ui16") == 1234)
precondition(FanRPMCodec.decode([0x00, 0x40, 0x9A, 0x44], type: "flt ") == 1234)  // 0x449A4000 小端
precondition(FanRPMCodec.decode([0x00, 0x00, 0x00, 0x00], type: "flt ") == 0)
precondition(FanRPMCodec.decode([0x00, 0x00, 0xC0, 0x7F], type: "flt ") == nil)  // NaN
precondition(FanRPMCodec.decode([1, 2, 3, 4], type: "unknown") == nil)
print("FanControlProtocolSmoke ok")
