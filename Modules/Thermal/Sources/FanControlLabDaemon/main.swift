import Foundation
import IOKit

// FanControlLabDaemon：root LaunchDaemon，轮询控制文件并执行 SMC 写入。
//
// 设计说明：本机 ad-hoc 签名下 XPC 连接 system daemon 不通
// （NSXPCConnection/底层 XPC 均 4097），故控制链路改为文件协议：
//   app（用户态）每拍计算期望转速 → 写 ~/Library/Application Support/FanControlLab/desired.json
//   本 daemon（root）每秒读取 → 写 SMC F{n}Tg
// desired.json 带 expiresAt，过期即停写，风扇回到系统自控。

let structSize = 80
let offKey = 0x00
let offDataSize = 0x1c
let offDataType = 0x20
let offCommand = 0x2a
let offData = 0x30

final class RootSMC {
    var connection: io_connect_t = 0

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

    func readFloat(_ key: String) -> Double? {
        guard let data = readBytes(key, size: 4) else { return nil }
        var bits: UInt32 = 0
        for (index, byte) in data.enumerated() {
            bits |= UInt32(byte) << (8 * index)
        }
        let float = Float(bitPattern: bits)
        return float.isFinite ? Double(float) : nil
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
        let size = keyInfo(key)?.size ?? 1
        var data = [UInt8](repeating: 0, count: size)
        data[0] = byte
        guard readBytes(key, size: size) != nil else { return false }
        guard let output = call(command: 6, key: key, dataSize: UInt32(size), value: data) else {
            return false
        }
        output.deallocate()
        return true
    }

    /// 写入前读回校验尺寸（防止类型错写）。
    func writeFloat(_ key: String, value: Double) -> Bool {
        guard readBytes(key, size: 4) != nil else { return false }
        var bits = Float(value).bitPattern.littleEndian
        let data = withUnsafeBytes(of: &bits) { Array($0) }
        guard let output = call(command: 6, key: key, dataSize: 4, value: data) else {
            return false
        }
        output.deallocate()
        return true
    }
}

struct ControlFile: Codable {
    var expiresAt: Double
    var targets: [String: Double?]
    var modes: [String: Int]?

    var isFresh: Bool {
        Date().timeIntervalSince1970 < expiresAt + 5
    }
}

// 控制文件路径由安装脚本按用户家目录生成，作为 argv[1] 传入
let controlPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FanControlLab/desired.json").path
let controlFileURL = URL(fileURLWithPath: controlPath)
NSLog("DAEMON: starting (pid \(getpid())) controlFile=\(controlPath)")
let smc = RootSMC()
var smcReady = false
var lastFileMtime = Date.distantPast
var lastHadControl = false
var lastActiveFans: Set<Int> = []
var lastLoadedControl: ControlFile?
// 平滑加减速：每 tick（1 秒）目标转速最多变化 500 RPM，起步从实际转速出发
var appliedTargets: [Int: Double] = [:]
let maxRPMStepPerTick: Double = 500

func tick() {
    // SMC 断线重连
    if !smcReady {
        smcReady = smc.open()
        if !smcReady {
            return
        }
        NSLog("DAEMON: SMC connected")
    }

    // 有新写入才重新加载；新鲜度检查每拍都做（app 死后文件不再变化也必须能触发归还）
    let url = controlFileURL
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let mtime = attributes[.modificationDate] as? Date,
       mtime > lastFileMtime,
       let data = try? Data(contentsOf: url),
       let control = try? JSONDecoder().decode(ControlFile.self, from: data) {
        lastFileMtime = mtime
        lastLoadedControl = control
    }
    guard let control = lastLoadedControl else {
        return
    }
    guard control.isFresh else {
        // 控制文件过期：app 已退出/崩溃，把风扇交还系统自控
        if lastHadControl {
            for fanIndex in lastActiveFans {
                _ = smc.writeRaw("F\(fanIndex)Md", byte: 0)
            }
            NSLog("DAEMON: control expired, returned fans \(lastActiveFans.sorted()) to system")
            lastHadControl = false
            lastActiveFans.removeAll()
            appliedTargets.removeAll()
        }
        return
    }
    lastHadControl = true
    lastActiveFans.formUnion(control.targets.keys.compactMap(Int.init))
    lastActiveFans.formUnion((control.modes ?? [:]).keys.compactMap(Int.init))

    // 模式键每拍读回实际值，不一致就重写。不能只信本进程的缓存：睡眠唤醒、固件
    // 看门狗或另一个守护进程都可能把 F{n}Md 悄悄归零；此时只写 F{n}Tg 会被固件忽略，
    // 风扇看似“已勾选温控却不受控”，直到手动切一次模式才恢复。读回可自愈这一点。
    for (fanIndexString, value) in control.modes ?? [:] {
        guard let fanIndex = Int(fanIndexString), fanIndex >= 0, fanIndex <= 9 else { continue }
        let key = "F\(fanIndex)Md"
        let desired = UInt8(clamping: value)
        guard smc.readBytes(key, size: 1)?.first != desired else { continue }
        let ok = smc.writeRaw(key, byte: desired)
        NSLog("DAEMON: mode \(key)=\(value) -> \(ok ? "OK" : "FAILED")")
    }

    // 目标转速平滑逼近（每 tick 最多 500 RPM），起步从实际转速出发
    for (fanIndexString, target) in control.targets {
        guard let fanIndex = Int(fanIndexString), fanIndex >= 0, fanIndex <= 9 else { continue }
        guard let rpm = target else { continue }
        let clamped = min(max(rpm, 0), 65535)
        let current = appliedTargets[fanIndex]
            ?? smc.readFloat("F\(fanIndex)Ac")
            ?? clamped
        let delta = clamped - current
        let step = min(max(delta, -maxRPMStepPerTick), maxRPMStepPerTick)
        let next = ((current + step) / 10).rounded() * 10
        let key = "F\(fanIndex)Tg"
        let ok = smc.writeFloat(key, value: next)
        if !ok {
            NSLog("DAEMON: write \(key)=\(next) failed")
        } else {
            appliedTargets[fanIndex] = next
            if abs(next - current) >= 40 {
                NSLog("DAEMON: ramp \(key) \(Int(current)) -> \(Int(next)) (target \(Int(clamped)))")
            }
        }
    }
}

// 主循环：每秒检查一次控制文件
while true {
    tick()
    Thread.sleep(forTimeInterval: 1.0)
}
