import Foundation

/// DDC/CI packet construction and reply parsing over the I2C transport.
/// Format (MCCS): source address 0x51, sink 0x6E, secondary header
/// 0x80 | (payload length + 1), checksum XORs 0x6E ^ 0x51 ^ every preceding
/// byte. Replies are checksummed with the sink address 0x50 instead.
public enum DDCProtocol {
    public static let chipAddress: UInt32 = 0x37
    public static let sourceAddress: UInt8 = 0x51
    public static let sinkAddress: UInt8 = 0x6E
    public static let replyChecksumSeed: UInt8 = 0x50

    public static let luminanceVCP: UInt8 = 0x10

    /// 6-byte "set VCP value" packet.
    public static func setPacket(vcp: UInt8, value: Int) -> [UInt8] {
        var payload: [UInt8] = [
            0x84, // 0x80 | (3 + 1)
            0x03, // payload length
            vcp,
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        payload.append(checksum(for: payload))
        return payload
    }

    /// 4-byte "get VCP value" packet.
    public static func getPacket(vcp: UInt8) -> [UInt8] {
        var payload: [UInt8] = [
            0x82, // 0x80 | (1 + 1)
            0x01,
            vcp,
        ]
        payload.append(checksum(for: payload))
        return payload
    }

    /// Some panels (and some OS builds) expect the get-request checksum
    /// without the source address folded in; return both variants, standard
    /// first.
    public static func getPacketVariants(vcp: UInt8) -> [[UInt8]] {
        let standard = getPacket(vcp: vcp)
        var alternate = [UInt8](standard.prefix(3))
        var checksum = sinkAddress
        for byte in alternate {
            checksum ^= byte
        }
        alternate.append(checksum)
        return [standard, alternate]
    }

    /// Parses the 11-byte get-VCP reply. The reply starts with the display's
    /// sink address (0x6E), so framing is checked by the reply checksum alone.
    public static func parseGetReply(_ data: [UInt8]) -> (current: Int, max: Int)? {
        guard data.count >= 11 else { return nil }

        var checksum = replyChecksumSeed
        for byte in data.prefix(10) {
            checksum ^= byte
        }
        guard data[10] == checksum else { return nil }

        let maxValue = Int(data[6]) << 8 | Int(data[7])
        let currentValue = Int(data[8]) << 8 | Int(data[9])
        guard maxValue > 0 else { return nil }
        return (current: currentValue, max: maxValue)
    }

    public static func checksum(for packet: [UInt8]) -> UInt8 {
        var checksum = sinkAddress ^ sourceAddress
        for byte in packet {
            checksum ^= byte
        }
        return checksum
    }
}
