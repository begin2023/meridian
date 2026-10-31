import DisplayPrivate
import Foundation

/// One DDC/CI device behind an IOAVService. All I2C traffic serializes on a
/// dedicated queue with bounded retries and pacing: repeated
/// command sends a few milliseconds apart, retries on failure, and tolerant
/// read handling because many panels fail reads sporadically.
public final class DDCDevice {
    public struct VCPValue: Codable, Equatable {
        public let current: Int
        public let max: Int

        /// Current value normalized to 0...1 against the device's own range.
        public var fraction: Double {
            max > 0 ? Double(current) / Double(max) : 0
        }
    }

    public enum DDCError: LocalizedError {
        case writeFailed(attempts: Int, status: Int32)
        case readFailed(attempts: Int)
        case invalidReply

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let attempts, let status):
                return "DDC 写入失败（尝试 \(attempts) 次，IOKit \(status)）。"
            case .readFailed(let attempts):
                return "DDC 读取失败（尝试 \(attempts) 次）。"
            case .invalidReply:
                return "DDC 应答校验失败。"
            }
        }
    }

    public let displayID: CGDirectDisplayID
    private let service: OpaquePointer
    private let queue: DispatchQueue
    private let writeCount: Int
    private let writeDelayMicroseconds: useconds_t
    private let retryCount: Int
    private var cachedMax: Int?

    public init(
        displayID: CGDirectDisplayID,
        service: OpaquePointer,
        writeCount: Int = 2,
        writeDelayMilliseconds: Int = 10,
        retryCount: Int = 4
    ) {
        self.displayID = displayID
        self.service = service
        self.writeCount = max(1, writeCount)
        self.writeDelayMicroseconds = useconds_t(max(2, writeDelayMilliseconds) * 1000)
        self.retryCount = max(0, retryCount)
        self.queue = DispatchQueue(label: "app.meridian.display.ddc.\(displayID)", qos: .userInitiated)
    }

    /// Serialized VCP read: send the get request over the write channel,
    /// wait for the panel to compose its reply, then read it from offset 0.
    /// Two request-checksum variants exist in the wild (with and without the
    /// source address folded in); both are attempted.
    public func read(vcp: UInt8) throws -> VCPValue {
        try queue.sync {
            let attempts = 4
            var lastError = DDCError.readFailed(attempts: attempts)
            for attempt in 1...attempts {
                if attempt > 1 {
                    usleep(20_000)
                }
                for request in DDCProtocol.getPacketVariants(vcp: vcp) {
                    var requestPacket = request
                    let writeCycles = max(1, writeCount)
                    for cycle in 0..<writeCycles {
                        if cycle > 0 {
                            usleep(writeDelayMicroseconds)
                        }
                        _ = IOAVServiceWriteI2C(
                            service,
                            DDCProtocol.chipAddress,
                            UInt32(DDCProtocol.sourceAddress),
                            &requestPacket,
                            UInt32(requestPacket.count)
                        )
                    }
                    usleep(50_000)

                    var buffer = [UInt8](repeating: 0, count: 12)
                    let status = IOAVServiceReadI2C(
                        service,
                        DDCProtocol.chipAddress,
                        0,
                        &buffer,
                        UInt32(buffer.count)
                    )
                    if getenv("DISPLAYLAB_DEBUG_DDC") != nil {
                        let dump = buffer.map { String(format: "%02x", $0) }.joined()
                        NSLog("DisplayLab ddc: read attempt=%d request=%@ status=0x%x reply=%@",
                              attempt,
                              request.map { String(format: "%02x", $0) }.joined(),
                              status,
                              dump)
                    }
                    guard status == kIOReturnSuccess else {
                        lastError = .readFailed(attempts: attempt)
                        break
                    }
                    if let value = DDCProtocol.parseGetReply(Array(buffer.prefix(11))) {
                        return VCPValue(current: value.current, max: value.max)
                    }
                    lastError = .invalidReply
                }
            }
            throw lastError
        }
    }

    /// Serialized VCP write: repetitions with pacing, then retries with a
    /// short backoff.
    public func write(vcp: UInt8, value: Int) throws {
        try writeRaw(vcp: vcp, value: value, sends: nil)
    }

    private func writeRaw(vcp: UInt8, value: Int, sends: Int?) throws {
        try queue.sync {
            let packet = DDCProtocol.setPacket(vcp: vcp, value: value)
            let repetitions = max(1, sends ?? writeCount)
            let delayMicroseconds = writeDelayMicroseconds
            let retries = retryCount

            var attempt = 0
            while true {
                attempt += 1
                var success = true
                for repetition in 0..<repetitions {
                    if repetition > 0 {
                        usleep(useconds_t(delayMicroseconds))
                    }
                    var mutablePacket = packet
                    let status = IOAVServiceWriteI2C(
                        service,
                        DDCProtocol.chipAddress,
                        UInt32(DDCProtocol.sourceAddress),
                        &mutablePacket,
                        UInt32(mutablePacket.count)
                    )
                    if status != kIOReturnSuccess {
                        success = false
                        break
                    }
                }
                if success {
                    return
                }
                if attempt > retries {
                    throw DDCError.writeFailed(attempts: attempt, status: kIOReturnError)
                }
                usleep(5_000)
            }
        }
    }

    public func readLuminance() throws -> VCPValue {
        let value = try read(vcp: DDCProtocol.luminanceVCP)
        queue.sync {
            cachedMax = value.max
        }
        return value
    }

    /// The display's own luminance range, discovered once and cached. A
    /// per-write read was the cause of multi-hundred-millisecond slider lag.
    public func cachedMaxLuminance() -> Int? {
        queue.sync { cachedMax }
    }

    public func primeMaxLuminance() {
        _ = try? readLuminance()
    }

    /// Writes luminance. `sends` controls repetition count: 1 for fast slider
    /// dragging, the settings default (2) for settling on a final value.
    public func writeLuminance(fraction: Double, sends: Int? = nil) throws {
        let maxValue = cachedMaxLuminance() ?? 100
        let clamped = min(1.0, max(0.0, fraction))
        try writeRaw(vcp: DDCProtocol.luminanceVCP, value: Int(round(clamped * Double(maxValue))), sends: sends)
    }
}
