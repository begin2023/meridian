import Foundation
import IOKit
import Darwin
import PrivilegedSupport
import FanControlProtocol
import os

let structSize = 80
let offKey = 0x00
let offDataSize = 0x1c
let offDataType = 0x20
let offCommand = 0x2a
let offData = 0x30

final class RootSMC {
    var connection: io_connect_t = 0
    deinit { close() }

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    func open() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var candidate: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &candidate) == KERN_SUCCESS, candidate != 0 else {
                continue
            }
            connection = candidate
            if readBytes("FNum", size: 1) != nil {
                return true
            }
            IOServiceClose(candidate)
            connection = 0
        }
        return false
    }

    private func buffer() -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: structSize, alignment: 8)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: structSize)
        return pointer
    }

    private func keyValue(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    func call(command: UInt8, key: String, dataSize: UInt32, value: [UInt8]? = nil) -> UnsafeMutableRawPointer? {
        guard connection != 0 else { return nil }
        let input = buffer()
        let output = buffer()
        defer { input.deallocate() }
        input.storeBytes(of: keyValue(key), toByteOffset: offKey, as: UInt32.self)
        input.storeBytes(of: dataSize, toByteOffset: offDataSize, as: UInt32.self)
        input.storeBytes(of: command, toByteOffset: offCommand, as: UInt8.self)
        if let value {
            for (index, byte) in value.enumerated() where index < 32 {
                input.storeBytes(of: byte, toByteOffset: offData + index, as: UInt8.self)
            }
        }
        var outputSize = structSize
        guard IOConnectCallStructMethod(
            connection, 2,
            input, structSize,
            output, &outputSize
        ) == KERN_SUCCESS else {
            output.deallocate()
            return nil
        }
        return output
    }

    func readBytes(_ key: String, size: Int) -> [UInt8]? {
        guard size > 0, size <= 32, let output = call(command: 5, key: key, dataSize: UInt32(size)) else {
            return nil
        }
        defer { output.deallocate() }
        return (0..<size).map { output.load(fromByteOffset: offData + $0, as: UInt8.self) }
    }

    /// 新版协议（macOS 26 AppleSMCKeysEndpoint）的 keyinfo（command 0）在用户态与
    /// root 下都返回 BadArgument（本机实测 0xe00002c2），不能作为写入的硬依赖：
    /// 先查真实类型，查不到再按已知布局兜底（转速键 4 字节 float 小端，
    /// FNum/F{n}Md 1 字节）。未知键返回 nil，保持与旧版一致的保守行为。
    func layout(_ key: String) -> (size: Int, type: String)? {
        if let info = keyInfo(key) { return info }
        if key == "FNum" || key.hasSuffix("Md") { return (1, "ui8") }
        switch key.suffix(2) {
        case "Mn", "Mx", "Tg", "Ac", "Sf": return (4, "flt ")
        default: return nil
        }
    }

    func readRPM(_ key: String) -> Double? {
        guard let layout = layout(key), let bytes = readBytes(key, size: layout.size) else { return nil }
        return FanRPMCodec.decode(bytes, type: layout.type)
    }

    func keyInfo(_ key: String) -> (size: Int, type: String)? {
        guard let output = call(command: 0, key: key, dataSize: 0) else { return nil }
        defer { output.deallocate() }
        let size = Int(output.load(fromByteOffset: offDataSize, as: UInt32.self))
        let typeRaw = output.load(fromByteOffset: offDataType, as: UInt32.self)
        guard size > 0, size <= 32, typeRaw != 0 else { return nil }
        let bytes = [UInt8((typeRaw >> 24) & 0xFF), UInt8((typeRaw >> 16) & 0xFF),
                     UInt8((typeRaw >> 8) & 0xFF), UInt8(typeRaw & 0xFF)]
        return (size, String(bytes: bytes, encoding: .ascii) ?? "????")
    }

    /// 原始字节写入（模式键 F{n}Md 等）。
    func writeRaw(_ key: String, byte: UInt8) -> Bool {
        guard let layout = layout(key), layout.size == 1, layout.type.trimmingCharacters(in: .whitespaces) == "ui8" else { return false }
        var data = [UInt8](repeating: 0, count: layout.size)
        data[0] = byte
        guard readBytes(key, size: layout.size) != nil else { return false }
        guard let output = call(command: 6, key: key, dataSize: UInt32(layout.size), value: data) else {
            return false
        }
        output.deallocate()
        return true
    }

    /// 按 SMC 返回的真实类型写入，避免把 fpe2/ui16 风扇目标误当作 float。
    func writeRPM(_ key: String, value: Double) -> Bool {
        guard let layout = layout(key), let data = FanRPMCodec.encode(value, type: layout.type, size: layout.size),
              readBytes(key, size: layout.size) != nil,
              let output = call(command: 6, key: key, dataSize: UInt32(layout.size), value: data) else { return false }
        output.deallocate()
        return true
    }
}

let label = "app.meridian.thermal.daemon"
let logger = Logger(subsystem: label, category: "control")
let smc = RootSMC()
var active: Set<Int> = []
var targets: [Int: Double] = [:]
var settings: [Int: FanCommand.Setting] = [:]
var leaseDeadline: TimeInterval = 0
var stopping = false

func restore(_ fans: Set<Int>) {
    for index in fans {
        if smc.writeRaw("F\(index)Md", byte: 0) { active.remove(index); targets.removeValue(forKey: index) }
    }
}

func bounds() -> [Int: ClosedRange<Double>] {
    guard let count = smc.readBytes("FNum", size: 1)?.first, count <= 10 else { return [:] }
    var result: [Int: ClosedRange<Double>] = [:]
    for index in 0..<Int(count) {
        guard let low = smc.readRPM("F\(index)Mn"), let high = smc.readRPM("F\(index)Mx"),
              low > 0, high >= low, high <= 65_535 else { continue }
        result[index] = low...high
    }
    return result
}

func tick() {
    guard ProcessInfo.processInfo.systemUptime < leaseDeadline else { restore(active); settings = [:]; return }
    let limits = bounds()
    let wanted = Set(settings.filter { $0.value.mode == 1 }.keys)
    restore(active.subtracting(wanted))
    for (index, setting) in settings {
        guard setting.mode == 1, let rpm = setting.rpm, let range = limits[index] else { continue }
        active.insert(index)
        let current = targets[index] ?? smc.readRPM("F\(index)Ac") ?? rpm
        let next = min(max(current + min(max(rpm - current, -500), 500), range.lowerBound), range.upperBound)
        // 先接管手动模式再写目标转速：固件只尊重已处于 F{n}Md=1 时的 F{n}Tg 写入
        // （旧版守护进程的实测顺序，反过来首拍会被覆盖）。
        guard smc.writeRaw("F\(index)Md", byte: 1), smc.writeRPM("F\(index)Tg", value: next) else { restore([index]); continue }
        targets[index] = next
    }
    restore(active.subtracting(Set(limits.keys)))
}

do {
    let config = try HelperConfiguration.load(label: label)
    guard config.applicationExists else { exit(0) }
    let server = try HelperSocket.Server(label: label, requirement: config.requirement, allowedUID: config.uid, allowedGID: config.gid)
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let terminationQueue = DispatchQueue(label: label + ".signal")
    let lock = NSLock()
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: terminationQueue)
        source.setEventHandler { lock.lock(); stopping = true; lock.unlock() }; source.resume(); return source
    }
    defer { signals.forEach { $0.cancel() }; restore(active) }
    var lastTick: TimeInterval = 0
    var lastAppCheck: TimeInterval = 0
    var connected = false
    while true {
        lock.lock(); let stop = stopping; lock.unlock(); if stop { break }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAppCheck > 5 { lastAppCheck = now; if !config.applicationExists { break } }
        if !connected {
            connected = smc.open()
        } else if smc.readBytes("FNum", size: 1) == nil {
            // SMC 连接失效时释放旧连接，下一轮重新打开。
            smc.close(); connected = false; leaseDeadline = 0; settings = [:]
        }
        if let request = server.acceptRequest() {
            do {
                guard connected else { throw HelperFailure.rejected("SMC 不可用。") }
                let command = try JSONDecoder().decode(FanCommand.self, from: request.data)
                let wallNow = Date().timeIntervalSince1970
                let validated = try command.validated(now: wallNow, bounds: bounds())
                settings = validated
                leaseDeadline = ProcessInfo.processInfo.systemUptime + max(0, command.expiresAt - wallNow)
                if command.expiresAt == 0 { restore(active) }
                else { restore(active.subtracting(Set(validated.filter { $0.value.mode == 1 }.keys))) }
                try HelperSocket.send(Data("OK".utf8), to: request.fd)
            } catch {
                leaseDeadline = 0; settings = [:]; restore(active)
                try? HelperSocket.send(Data("REJECTED".utf8), to: request.fd)
            }
            close(request.fd)
        }
        if now - lastTick >= 1 { lastTick = now; tick() }
    }
} catch { logger.error("Fan helper failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
