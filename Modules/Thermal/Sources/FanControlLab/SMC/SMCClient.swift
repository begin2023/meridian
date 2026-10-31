import Foundation
import IOKit

enum SMCBackend: Equatable {
    /// macOS 26+ AppleSMCKeysEndpoint：selector 2 统一分发。
    case modern
    /// 经典 AppleSMC 用户客户端：selector 0/5/6/9（Intel/老系统机型）。
    case classic
}

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kr: Int32)
    #if FAN_CONTROL_LEGACY_WRITE
    case unsupportedWrite(backend: SMCBackend)
    #endif

    var description: String {
        switch self {
        case .serviceNotFound:
            return "未找到可用的 AppleSMC 服务"
        case .openFailed(let kr):
            return "AppleSMC 打开失败 (kr=\(kr))"
        #if FAN_CONTROL_LEGACY_WRITE
        case .unsupportedWrite(let backend):
            return "当前 SMC 后端 (\(backend)) 暂不支持写入"
        #endif
        }
    }
}

/// SMC 键值：原始字节 + 声明的类型四字符码。
struct SMCValue {
    let data: [UInt8]
    let type: String
}

/// SMC 客户端：自动探测新版/经典协议后端，提供按类型解码的语义化读取。
///
/// 新版协议（本机实测）：用户态可读但需预知尺寸；keyinfo/写为 root 专属（走特权助手）。
/// 经典协议（未在本机验证）：用户态支持 keyinfo、读取和写入，
/// 风扇转速多为 `fpe2`（大端 u16>>2），温度为 `sp78`（大端 Int16/256）。
final class SMCClient {
    private(set) var backend: SMCBackend = .modern
    private var connection: io_connect_t = 0

    // MARK: - 新版协议常量

    private static let modernKeyOperation: UInt32 = 2
    private static let modernCommandKeyInfo: UInt8 = 0
    private static let modernCommandRead: UInt8 = 5
    #if FAN_CONTROL_LEGACY_WRITE
    private static let modernCommandWrite: UInt8 = 6
    #endif
    private static let modernOffKey = 0x00
    private static let modernOffDataSize = 0x1c
    private static let modernOffDataType = 0x20
    private static let modernOffCommand = 0x2a
    private static let modernOffData = 0x30

    // MARK: - 经典协议常量

    private static let classicOpen: UInt32 = 0
    private static let classicRead: UInt32 = 5
    #if FAN_CONTROL_LEGACY_WRITE
    private static let classicWrite: UInt32 = 6
    #endif
    private static let classicKeyInfo: UInt32 = 9
    private static let classicOffKey = 0x00
    private static let classicOffDataSize = 0x1a
    private static let classicOffDataType = 0x1c
    private static let classicOffResult = 0x26
    private static let classicOffData = 0x30

    private static let structSize = 80

    // MARK: - 打开与关闭

    func open() throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var candidate: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &candidate) == KERN_SUCCESS, candidate != 0 else {
                continue
            }
            connection = candidate

            if tryModernRead("FNum", size: 1) != nil {
                backend = .modern
                return
            }
            if openClassicSession(), tryClassicRead("FNum") != nil {
                backend = .classic
                return
            }
            IOServiceClose(candidate)
            connection = 0
        }
        throw SMCError.serviceNotFound
    }

    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    var isOpen: Bool { connection != 0 }

    // MARK: - 语义化读取（按实际类型解码）

    /// 风扇转速。新版：4 字节 float32 小端；经典：fpe2（大端 u16>>2）或 float。
    func readRPM(_ key: String) -> Double? {
        switch backend {
        case .modern:
            return readFloatLE(key, size: 4)
        case .classic:
            return readNumeric(key) { type, data in
                Self.decodeRPM(type: type, data: data)
            }
        }
    }

    /// 温度（摄氏度）。新版：float32 小端；经典：sp78 / fp79 / flt。
    func readTemperatureCelsius(_ key: String) -> Double? {
        switch backend {
        case .modern:
            return readFloatLE(key, size: 4)
        case .classic:
            return readNumeric(key) { type, data in
                Self.decodeTemperature(type: type, data: data)
            }
        }
    }

    /// 单字节键（FNum、模式字节等）。
    func readUInt8(_ key: String) -> UInt8? {
        switch backend {
        case .modern:
            return tryModernRead(key, size: 1)?[0]
        case .classic:
            return tryClassicRead(key).flatMap { value in
                value.type == "ui8" ? value.data.first : nil
            }
        }
    }

    /// 现代后端专用：按已知尺寸读原始字节（监控层使用）。
    func readBytes(_ key: String, size: Int) -> [UInt8]? {
        tryModernRead(key, size: size)
    }

    // MARK: - keyinfo

    struct KeyInfo {
        var size: Int
        var type: String
    }

    /// 新版后端 root 专属（用户态返回 BadArgument）；经典后端用户态可用。
    func keyInfo(_ key: String) -> KeyInfo? {
        switch backend {
        case .modern:
            return modernKeyInfo(key)
        case .classic:
            return classicKeyInfo(key)
        }
    }

    #if FAN_CONTROL_LEGACY_WRITE
    // MARK: - 写入（仅旧专用手工研究产物）

    @discardableResult
    func writeBytes(_ key: String, data: [UInt8], declaredSize: Int? = nil) -> Bool {
        let size = declaredSize ?? data.count
        switch backend {
        case .modern:
            return modernWrite(key, data: data, declaredSize: size)
        case .classic:
            return classicWrite(key, data: data, declaredSize: size)
        }
    }

    /// 转速写入：float32 小端（现代后端）。
    @discardableResult
    func writeFloat(_ key: String, value: Double) -> Bool {
        writeBytes(key, data: Self.encodeFloat(value), declaredSize: 4)
    }

    static func encodeFloat(_ value: Double) -> [UInt8] {
        var bits = Float(value).bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }
    #endif

    // MARK: - 新版协议实现

    private func modernCall(command: UInt8, key: String, dataSize: UInt32) -> UnsafeMutableRawPointer? {
        guard connection != 0 else { return nil }
        let input = Self.buffer()
        let output = Self.buffer()
        defer { input.deallocate() }
        input.storeBytes(of: Self.keyValue(key), toByteOffset: Self.modernOffKey, as: UInt32.self)
        input.storeBytes(of: dataSize, toByteOffset: Self.modernOffDataSize, as: UInt32.self)
        input.storeBytes(of: command, toByteOffset: Self.modernOffCommand, as: UInt8.self)
        var outputSize = Self.structSize
        guard IOConnectCallStructMethod(
            connection, Self.modernKeyOperation,
            input, Self.structSize,
            output, &outputSize
        ) == KERN_SUCCESS else {
            output.deallocate()
            return nil
        }
        return output
    }

    private func tryModernRead(_ key: String, size: Int) -> [UInt8]? {
        guard size > 0, size <= 32,
              let output = modernCall(command: Self.modernCommandRead, key: key, dataSize: UInt32(size)) else {
            return nil
        }
        defer { output.deallocate() }
        return (0..<size).map { output.load(fromByteOffset: Self.modernOffData + $0, as: UInt8.self) }
    }

    private func modernKeyInfo(_ key: String) -> KeyInfo? {
        guard let output = modernCall(command: Self.modernCommandKeyInfo, key: key, dataSize: 0) else {
            return nil
        }
        defer { output.deallocate() }
        let size = Int(output.load(fromByteOffset: Self.modernOffDataSize, as: UInt32.self))
        let type = output.load(fromByteOffset: Self.modernOffDataType, as: UInt32.self)
        guard size > 0, size <= 32, type != 0 else { return nil }
        return KeyInfo(size: size, type: Self.fourCC(type))
    }

    #if FAN_CONTROL_LEGACY_WRITE
    private func modernWriteCall(
        key: String,
        dataSize: UInt32,
        value: [UInt8]
    ) -> UnsafeMutableRawPointer? {
        guard connection != 0 else { return nil }
        let input = Self.buffer()
        let output = Self.buffer()
        defer { input.deallocate() }
        input.storeBytes(of: Self.keyValue(key), toByteOffset: Self.modernOffKey, as: UInt32.self)
        input.storeBytes(of: dataSize, toByteOffset: Self.modernOffDataSize, as: UInt32.self)
        input.storeBytes(of: Self.modernCommandWrite, toByteOffset: Self.modernOffCommand, as: UInt8.self)
        for (index, byte) in value.enumerated() where index < 32 {
            input.storeBytes(of: byte, toByteOffset: Self.modernOffData + index, as: UInt8.self)
        }
        var outputSize = Self.structSize
        guard IOConnectCallStructMethod(
            connection, Self.modernKeyOperation,
            input, Self.structSize,
            output, &outputSize
        ) == KERN_SUCCESS else {
            output.deallocate()
            return nil
        }
        return output
    }

    private func modernWrite(_ key: String, data: [UInt8], declaredSize: Int) -> Bool {
        // 写入前读回校验尺寸，防止类型错写
        guard declaredSize > 0, declaredSize <= 32, data.count == declaredSize,
              tryModernRead(key, size: declaredSize) != nil else {
            return false
        }
        guard let output = modernWriteCall(
            key: key,
            dataSize: UInt32(declaredSize),
            value: data
        ) else {
            return false
        }
        output.deallocate()
        return true
    }
    #endif

    private func readFloatLE(_ key: String, size: Int) -> Double? {
        guard let data = tryModernRead(key, size: size), data.count == 4 else { return nil }
        var bits: UInt32 = 0
        for (index, byte) in data.enumerated() {
            bits |= UInt32(byte) << (8 * index)
        }
        let float = Float(bitPattern: bits)
        return float.isFinite ? Double(float) : nil
    }

    // MARK: - 经典协议实现

    private func openClassicSession() -> Bool {
        guard connection != 0 else { return false }
        let output = Self.buffer()
        defer { output.deallocate() }
        var outputSize = Self.structSize
        return IOConnectCallStructMethod(
            connection, Self.classicOpen,
            nil, 0,
            output, &outputSize
        ) == KERN_SUCCESS
    }

    private func classicCall(_ selector: UInt32, key: String) -> UnsafeMutableRawPointer? {
        guard connection != 0 else { return nil }
        let input = Self.buffer()
        let output = Self.buffer()
        defer { input.deallocate() }
        input.storeBytes(of: Self.keyValue(key), toByteOffset: Self.classicOffKey, as: UInt32.self)
        var outputSize = Self.structSize
        guard IOConnectCallStructMethod(
            connection, selector,
            input, Self.structSize,
            output, &outputSize
        ) == KERN_SUCCESS, output.load(fromByteOffset: Self.classicOffResult, as: UInt8.self) == 0 else {
            output.deallocate()
            return nil
        }
        return output
    }

    private func tryClassicRead(_ key: String) -> SMCValue? {
        guard let output = classicCall(Self.classicRead, key: key) else { return nil }
        defer { output.deallocate() }
        let size = Int(output.load(fromByteOffset: Self.classicOffDataSize, as: UInt8.self))
        let type = output.load(fromByteOffset: Self.classicOffDataType, as: UInt32.self)
        guard size > 0, size <= 32 else { return nil }
        let data = (0..<size).map { output.load(fromByteOffset: Self.classicOffData + $0, as: UInt8.self) }
        return SMCValue(data: data, type: Self.fourCC(type))
    }

    private func classicKeyInfo(_ key: String) -> KeyInfo? {
        guard let output = classicCall(Self.classicKeyInfo, key: key) else { return nil }
        defer { output.deallocate() }
        let size = Int(output.load(fromByteOffset: Self.classicOffDataSize, as: UInt8.self))
        let type = output.load(fromByteOffset: Self.classicOffDataType, as: UInt32.self)
        guard size > 0, size <= 32, type != 0 else { return nil }
        return KeyInfo(size: size, type: Self.fourCC(type))
    }

    #if FAN_CONTROL_LEGACY_WRITE
    private func classicWriteCall(
        key: String,
        data: [UInt8],
        declaredSize: Int
    ) -> UnsafeMutableRawPointer? {
        guard connection != 0 else { return nil }
        let input = Self.buffer()
        let output = Self.buffer()
        defer { input.deallocate() }
        input.storeBytes(of: Self.keyValue(key), toByteOffset: Self.classicOffKey, as: UInt32.self)
        input.storeBytes(
            of: UInt8(declaredSize),
            toByteOffset: Self.classicOffDataSize,
            as: UInt8.self
        )
        for (index, byte) in data.enumerated() {
            input.storeBytes(of: byte, toByteOffset: Self.classicOffData + index, as: UInt8.self)
        }
        var outputSize = Self.structSize
        guard IOConnectCallStructMethod(
            connection, Self.classicWrite,
            input, Self.structSize,
            output, &outputSize
        ) == KERN_SUCCESS,
            output.load(fromByteOffset: Self.classicOffResult, as: UInt8.self) == 0 else {
            output.deallocate()
            return nil
        }
        return output
    }

    private func classicWrite(_ key: String, data: [UInt8], declaredSize: Int) -> Bool {
        guard data.count == declaredSize, declaredSize <= 32,
              let existing = tryClassicRead(key), existing.data.count == data.count else {
            return false
        }
        guard let output = classicWriteCall(
            key: key,
            data: data,
            declaredSize: declaredSize
        ) else {
            return false
        }
        output.deallocate()
        return true
    }
    #endif

    /// 经典后端：先 keyinfo 拿真实类型，再按类型解码。
    private func readNumeric(
        _ key: String,
        decoder: (String, [UInt8]) -> Double?
    ) -> Double? {
        guard let value = tryClassicRead(key) else { return nil }
        return decoder(value.type, value.data)
    }

    // MARK: - 类型解码

    private static func decodeRPM(type: String, data: [UInt8]) -> Double? {
        switch type {
        case "flt ", "f2sf":
            return decodeFloatLE(data)
        case "fpe2":
            return data.count >= 2 ? Double(bigEndian(data, 2)) / 4.0 : nil
        case "ui16":
            return data.count >= 2 ? Double(bigEndian(data, 2)) : nil
        case "ui8":
            return data.first.map(Double.init)
        default:
            return nil
        }
    }

    private static func decodeTemperature(type: String, data: [UInt8]) -> Double? {
        switch type {
        case "flt ", "f2sf":
            return decodeFloatLE(data)
        case "sp78":
            return data.count >= 2 ? Double(Int16(bitPattern: UInt16(bigEndian(data, 2)))) / 256.0 : nil
        case "fp79":
            return data.count >= 2 ? Double(bigEndian(data, 2)) / 512.0 : nil
        case "sp87":
            return data.count >= 2 ? Double(Int16(bitPattern: UInt16(bigEndian(data, 2)))) / 128.0 : nil
        case "ui8":
            return data.first.map(Double.init)
        default:
            return nil
        }
    }

    private static func decodeFloatLE(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        var bits: UInt32 = 0
        for index in 0..<4 {
            bits |= UInt32(data[index]) << (8 * index)
        }
        let float = Float(bitPattern: bits)
        return float.isFinite ? Double(float) : nil
    }

    private static func bigEndian(_ data: [UInt8], _ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in data.prefix(count) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    // MARK: - 工具

    private static func buffer() -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: structSize, alignment: 8)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: structSize)
        return pointer
    }

    private static func keyValue(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
