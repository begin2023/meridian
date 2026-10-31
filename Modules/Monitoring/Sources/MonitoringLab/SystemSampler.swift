import Darwin
import Foundation
import IOKit

/// 供宿主进程内直接使用的轻量采样器。
///
/// 与菜单栏应用的模块不同：不持有定时器、不碰 AppKit，由调用方在自己的串行队列上驱动。
/// 常规采样只做几次系统调用；进程排行开销较大，只在调用方明确请求（详情可见）时扫描。
public struct SystemSnapshot: Sendable, Equatable {
    public struct Volume: Sendable, Equatable, Identifiable {
        public var id: String { mountPath }
        public let name: String
        public let mountPath: String
        public let totalBytes: UInt64
        public let freeBytes: UInt64
        public var usedFraction: Double { totalBytes > 0 ? Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes) : 0 }
    }

    public var timestamp = Date()
    public var cpuPercent: Double = 0
    public var corePercents: [Double] = []
    public var memoryTotal: UInt64 = 0
    public var memoryUsed: UInt64 = 0
    public var memoryApp: UInt64 = 0
    public var memoryWired: UInt64 = 0
    public var memoryCompressed: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var netUpPerSecond: Double = 0
    public var netDownPerSecond: Double = 0
    public var netInterfaces: [String] = []
    public var netInterface: String = ""
    public var netTotalUpBytes: UInt64 = 0
    public var netTotalDownBytes: UInt64 = 0
    public var localIP: String = ""
    public var diskReadPerSecond: Double = 0
    public var diskWritePerSecond: Double = 0
    public var volumes: [Volume] = []

    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    public init() {}
}

public struct ProcessActivity: Sendable, Equatable, Identifiable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let path: String?
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadPerSecond: Double
    public let diskWritePerSecond: Double
    public let networkReceivePerSecond: Double
    public let networkSendPerSecond: Double
}

public struct ProcessRanking: Sendable, Equatable {
    public var byCPU: [ProcessActivity] = []
    public var byMemory: [ProcessActivity] = []
    public var byDisk: [ProcessActivity] = []
    public var byNetwork: [ProcessActivity] = []
    public init() {}
}

/// 非线程安全：同一实例只在一个串行队列上调用。
public final class SystemSampler: @unchecked Sendable {
    private var previousBusy: [UInt64] = []
    private var previousIdle: [UInt64] = []
    private var previousNet: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousNetTime: UInt64 = 0
    private var previousDiskRead: UInt64 = 0
    private var previousDiskWrite: UInt64 = 0
    private var previousDiskTime: UInt64 = 0
    private var cachedVolumes: [SystemSnapshot.Volume] = []
    private var volumesTime: UInt64 = 0
    private var cachedIP = ""
    private var cachedIPInterface = ""
    private var ipTime: UInt64 = 0

    private var previousProcessTime: [pid_t: UInt64] = [:]
    private var previousProcessIO: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private var previousProcessScan: UInt64 = 0
    private var previousProcessNetwork: [pid_t: (received: UInt64, sent: UInt64)] = [:]
    private var previousProcessNetworkTime: UInt64 = 0
    private var identityCache: [pid_t: (name: String, path: String?)] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        let now = DispatchTime.now().uptimeNanoseconds
        sampleCPU(into: &snapshot)
        sampleMemory(into: &snapshot)
        sampleNetwork(into: &snapshot, now: now)
        sampleDisk(into: &snapshot, now: now)
        return snapshot
    }

    // MARK: CPU

    private func sampleCPU(into snapshot: inout SystemSnapshot) {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var messageCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &messageCount)
        mach_port_deallocate(mach_task_self_, host)
        guard result == KERN_SUCCESS, let info = processorInfo, processorCount > 0 else { return }
        defer {
            let size = vm_size_t(messageCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let count = Int(processorCount)
        var busy = [UInt64](repeating: 0, count: count)
        var idle = [UInt64](repeating: 0, count: count)
        var cores = [Double](repeating: 0, count: count)
        var totalBusy: UInt64 = 0
        var totalIdle: UInt64 = 0
        let hasPrevious = previousBusy.count == count
        for core in 0..<count {
            let offset = Int(CPU_STATE_MAX) * core
            let coreBusy = UInt64(info[offset + Int(CPU_STATE_USER)])
                + UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
                + UInt64(info[offset + Int(CPU_STATE_NICE)])
            let coreIdle = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            busy[core] = coreBusy
            idle[core] = coreIdle
            guard hasPrevious else { continue }
            let deltaBusy = coreBusy > previousBusy[core] ? coreBusy - previousBusy[core] : 0
            let deltaIdle = coreIdle > previousIdle[core] ? coreIdle - previousIdle[core] : 0
            if deltaBusy + deltaIdle > 0 {
                cores[core] = Double(deltaBusy) / Double(deltaBusy + deltaIdle) * 100
            }
            totalBusy += deltaBusy
            totalIdle += deltaIdle
        }
        previousBusy = busy
        previousIdle = idle
        snapshot.corePercents = cores
        snapshot.cpuPercent = totalBusy + totalIdle > 0
            ? min(100, Double(totalBusy) / Double(totalBusy + totalIdle) * 100) : 0
    }

    // MARK: 内存（与活动监视器同口径）

    private func sampleMemory(into snapshot: inout SystemSnapshot) {
        var vmStatistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStatistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        mach_port_deallocate(mach_task_self_, host)
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(vmStatistics.internal_page_count)
        let purgeable = UInt64(vmStatistics.purgeable_count)
        snapshot.memoryApp = internalPages > purgeable ? (internalPages - purgeable) * page : 0
        snapshot.memoryWired = UInt64(vmStatistics.wire_count) * page
        snapshot.memoryCompressed = UInt64(vmStatistics.compressor_page_count) * page
        snapshot.memoryUsed = snapshot.memoryApp + snapshot.memoryWired + snapshot.memoryCompressed
        snapshot.memoryTotal = ProcessInfo.processInfo.physicalMemory
        let swap = Self.swapUsage()
        snapshot.swapTotal = swap.total
        snapshot.swapUsed = swap.used
    }

    private static func swapUsage() -> (total: UInt64, used: UInt64) {
        var size = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size >= 24 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buffer, &size, nil, 0) == 0, size >= 24 else { return (0, 0) }
        // 新系统返回 xsw_usage 二进制结构 { total, avail, used, ... }。
        guard buffer[0] != UInt8(ascii: "t") else { return (0, 0) }
        return buffer.withUnsafeBytes { raw in
            let total = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            let used = raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            return (total, min(used, total))
        }
    }

    // MARK: 网络

    /// 汇总物理接口（en*），避免代理隧道（utun）把同一份流量重复计数。
    private func sampleNetwork(into snapshot: inout SystemSnapshot, now: UInt64) {
        let counters = NetModule.interfaceCounters()
        let physical = counters.filter { $0.key.hasPrefix("en") }
        var up: Double = 0
        var down: Double = 0
        var active: [String] = []
        var deltas: [String: (received: UInt64, sent: UInt64)] = [:]
        if previousNetTime > 0, now > previousNetTime {
            let elapsed = Double(now - previousNetTime) / 1_000_000_000
            for (name, current) in physical {
                guard let previous = previousNet[name] else { continue }
                let received = current.received >= previous.received ? current.received - previous.received : 0
                let sent = current.sent >= previous.sent ? current.sent - previous.sent : 0
                deltas[name] = (received, sent)
                if received + sent > 0 { active.append(name) }
                down += Double(received) / elapsed
                up += Double(sent) / elapsed
            }
        }
        let primaryName = active.max {
            let lhs = (deltas[$0]?.received ?? 0) + (deltas[$0]?.sent ?? 0)
            let rhs = (deltas[$1]?.received ?? 0) + (deltas[$1]?.sent ?? 0)
            return lhs < rhs
        } ?? physical.max {
            $0.value.received + $0.value.sent < $1.value.received + $1.value.sent
        }?.key
        let primary = primaryName.flatMap { physical[$0] }
        previousNet = physical
        previousNetTime = now
        snapshot.netUpPerSecond = up
        snapshot.netDownPerSecond = down
        snapshot.netInterface = primaryName ?? ""
        snapshot.netTotalDownBytes = primary?.received ?? 0
        snapshot.netTotalUpBytes = primary?.sent ?? 0
        snapshot.netInterfaces = active.isEmpty ? primaryName.map { [$0] } ?? [] : active
        if primaryName != cachedIPInterface || now - ipTime > 10_000_000_000 || cachedIP.isEmpty {
            ipTime = now
            cachedIPInterface = primaryName ?? ""
            cachedIP = primaryName.flatMap { NetModule.primaryIPAddress(of: $0) } ?? ""
        }
        snapshot.localIP = cachedIP
    }

    // MARK: 磁盘

    private func sampleDisk(into snapshot: inout SystemSnapshot, now: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let value = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    read += value["Bytes (Read)"] as? UInt64 ?? 0
                    write += value["Bytes (Write)"] as? UInt64 ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        if previousDiskTime > 0, now > previousDiskTime {
            let elapsed = Double(now - previousDiskTime) / 1_000_000_000
            snapshot.diskReadPerSecond = read >= previousDiskRead ? Double(read - previousDiskRead) / elapsed : 0
            snapshot.diskWritePerSecond = write >= previousDiskWrite ? Double(write - previousDiskWrite) / elapsed : 0
        }
        previousDiskRead = read
        previousDiskWrite = write
        previousDiskTime = now

        if cachedVolumes.isEmpty || now - volumesTime > 15_000_000_000 {
            volumesTime = now
            cachedVolumes = Self.mountedVolumes()
        }
        snapshot.volumes = cachedVolumes
    }

    private static func mountedVolumes() -> [SystemSnapshot.Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            let path = url.path
            guard path == "/" || path.hasPrefix("/Volumes/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let free = max(Int(values.volumeAvailableCapacityForImportantUsage ?? 0), values.volumeAvailableCapacity ?? 0)
            return SystemSnapshot.Volume(name: values.volumeName ?? (path as NSString).lastPathComponent,
                                         mountPath: path, totalBytes: UInt64(total), freeBytes: UInt64(max(free, 0)))
        }
    }

    // MARK: 进程排行（仅详情可见时调用）

    public func rankProcesses(limit: Int = 6, includeNetwork: Bool = false) -> ProcessRanking {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousProcessScan > 0 && now > previousProcessScan ? Double(now - previousProcessScan) : 0
        previousProcessScan = now

        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return ProcessRanking() }
        var pids = [pid_t](repeating: 0, count: Int(size) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return ProcessRanking() }

        var times: [pid_t: UInt64] = [:]
        var ios: [pid_t: (read: UInt64, write: UInt64)] = [:]
        var rows: [ProcessActivity] = []
        rows.reserveCapacity(Int(count))
        var seen = Set<pid_t>()
        for pid in pids.prefix(Int(count)) where pid > 0 {
            seen.insert(pid)
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            times[pid] = cpuTime
            ios[pid] = (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
            var cpu: Double = 0
            var readRate: Double = 0
            var writeRate: Double = 0
            if elapsed > 0 {
                if let previous = previousProcessTime[pid], cpuTime >= previous {
                    let nanos = Double(cpuTime - previous) * Double(timebase.numer) / Double(timebase.denom)
                    cpu = min(nanos / elapsed * 100, 999)
                }
                if let previous = previousProcessIO[pid] {
                    if usage.ri_diskio_bytesread >= previous.read {
                        readRate = Double(usage.ri_diskio_bytesread - previous.read) / elapsed * 1_000_000_000
                    }
                    if usage.ri_diskio_byteswritten >= previous.write {
                        writeRate = Double(usage.ri_diskio_byteswritten - previous.write) / elapsed * 1_000_000_000
                    }
                }
            }
            let identity = identity(of: pid)
            rows.append(ProcessActivity(pid: pid, name: identity.name, path: identity.path, cpuPercent: cpu,
                                        memoryBytes: usage.ri_phys_footprint,
                                        diskReadPerSecond: readRate, diskWritePerSecond: writeRate,
                                        networkReceivePerSecond: 0, networkSendPerSecond: 0))
        }
        previousProcessTime = times
        previousProcessIO = ios
        identityCache = identityCache.filter { seen.contains($0.key) }

        if includeNetwork {
            if previousProcessNetworkTime == 0 {
                // Establish a baseline and immediately take a second one-shot
                // sample so the first visible network ranking is not empty.
                _ = sampleProcessNetwork()
                if previousProcessNetworkTime > 0 {
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            let network = sampleProcessNetwork()
            var rowIndexes: [pid_t: Int] = [:]
            rowIndexes.reserveCapacity(rows.count)
            for (index, row) in rows.enumerated() {
                rowIndexes[row.pid] = index
            }
            for (pid, rate) in network where rate.received + rate.sent > 1 {
                if let index = rowIndexes[pid] {
                    let row = rows[index]
                    rows[index] = ProcessActivity(
                        pid: row.pid,
                        name: row.name,
                        path: row.path,
                        cpuPercent: row.cpuPercent,
                        memoryBytes: row.memoryBytes,
                        diskReadPerSecond: row.diskReadPerSecond,
                        diskWritePerSecond: row.diskWritePerSecond,
                        networkReceivePerSecond: rate.received,
                        networkSendPerSecond: rate.sent
                    )
                } else {
                    let identity = identity(of: pid)
                    rows.append(ProcessActivity(
                        pid: pid,
                        name: identity.name,
                        path: identity.path,
                        cpuPercent: 0,
                        memoryBytes: 0,
                        diskReadPerSecond: 0,
                        diskWritePerSecond: 0,
                        networkReceivePerSecond: rate.received,
                        networkSendPerSecond: rate.sent
                    ))
                }
            }
        }

        var ranking = ProcessRanking()
        ranking.byCPU = Array(rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
        ranking.byMemory = Array(rows.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
        ranking.byDisk = Array(rows.filter { $0.diskReadPerSecond + $0.diskWritePerSecond > 1 }
            .sorted { $0.diskReadPerSecond + $0.diskWritePerSecond > $1.diskReadPerSecond + $1.diskWritePerSecond }
            .prefix(limit))
        ranking.byNetwork = Array(rows.filter { $0.networkReceivePerSecond + $0.networkSendPerSecond > 1 }
            .sorted { $0.networkReceivePerSecond + $0.networkSendPerSecond > $1.networkReceivePerSecond + $1.networkSendPerSecond }
            .prefix(limit))
        return ranking
    }

    private func sampleProcessNetwork() -> [pid_t: (received: Double, sent: Double)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // A one-shot sample normally exits in a few milliseconds. Keep a
            // hard ceiling, but use any complete rows already written to stdout.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(750)) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(1_000)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return [:] }
            let current = Self.parseNettopCounters(text)
            guard !current.isEmpty else { return [:] }
            let sampledAt = DispatchTime.now().uptimeNanoseconds
            let elapsed = previousProcessNetworkTime > 0 && sampledAt > previousProcessNetworkTime
                ? Double(sampledAt - previousProcessNetworkTime) / 1_000_000_000
                : 0
            var rates: [pid_t: (received: Double, sent: Double)] = [:]
            if previousProcessNetworkTime > 0 && elapsed > 0 {
                for (pid, value) in current {
                    guard let previous = previousProcessNetwork[pid] else { continue }
                    rates[pid] = (Double(value.received >= previous.received ? value.received - previous.received : 0) / elapsed,
                                  Double(value.sent >= previous.sent ? value.sent - previous.sent : 0) / elapsed)
                }
            }
            previousProcessNetwork = current
            previousProcessNetworkTime = sampledAt
            return rates
        } catch {
            return [:]
        }
    }

    /// Locate columns from nettop's header instead of relying on their current
    /// positions. This survives process names containing punctuation and newer
    /// nettop versions adding columns.
    static func parseNettopCounters(_ text: String) -> [pid_t: (received: UInt64, sent: UInt64)] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first else { return [:] }
        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false)
        guard let inputColumn = header.firstIndex(of: "bytes_in"),
              let outputColumn = header.firstIndex(of: "bytes_out") else { return [:] }
        // Recent nettop versions leave the process column's header blank (the
        // second column), while others label it "process".
        let processIndex = header.firstIndex(of: "process").map {
            header.distance(from: header.startIndex, to: $0)
        } ?? 1
        let inputIndex = header.distance(from: header.startIndex, to: inputColumn)
        let outputIndex = header.distance(from: header.startIndex, to: outputColumn)
        let required = max(processIndex, inputIndex, outputIndex)
        var current: [pid_t: (received: UInt64, sent: UInt64)] = [:]
        current.reserveCapacity(max(0, lines.count - 1))
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > required else { continue }
            let processName = fields[processIndex]
            guard let dot = processName.lastIndex(of: "."),
                  let pid = pid_t(processName[processName.index(after: dot)...]),
                  let received = UInt64(fields[inputIndex]),
                  let sent = UInt64(fields[outputIndex]) else { continue }
            current[pid] = (received, sent)
        }
        return current
    }

    /// 重置差分基线（详情关闭一段时间后再打开时避免第一帧失真）。
    public func resetProcessBaseline() {
        previousProcessScan = 0
        previousProcessTime.removeAll()
        previousProcessIO.removeAll()
        previousProcessNetwork.removeAll()
        previousProcessNetworkTime = 0
    }

    public func resetNetworkBaseline() {
        previousProcessNetwork.removeAll()
        previousProcessNetworkTime = 0
    }

    private func identity(of pid: pid_t) -> (name: String, path: String?) {
        if let cached = identityCache[pid] { return cached }
        var resolved: (name: String, path: String?) = ("pid \(pid)", nil)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 {
            let path = String(cString: pathBuffer)
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { resolved = (name, path) }
        } else {
            var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
            if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                resolved = (String(cString: nameBuffer), nil)
            }
        }
        identityCache[pid] = resolved
        return resolved
    }
}
