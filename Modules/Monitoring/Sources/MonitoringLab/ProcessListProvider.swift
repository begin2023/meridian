import Darwin
import Foundation

struct ProcessSample {
    let pid: pid_t
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    /// 可执行文件路径,用于取应用图标;SIP 保护进程拿不到时为 nil。
    let iconPath: String?
}

struct DiskProcessSample {
    let pid: pid_t
    let name: String
    let iconPath: String?
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

// 顶层进程采样:proc_listallpids + PROC_PIDTASKINFO/rusage 差分。
// 内部加锁,允许被 CPU/RAM/Disk 三个模块的采样队列并发调用;
// 250ms 内的请求共享同一次全量扫描。
final class ProcessListProvider {
    enum Sort {
        case cpu
        case memory
    }

    static let shared = ProcessListProvider()

    private struct ScanResult {
        var processSamples: [ProcessSample] = []
        var diskSamples: [DiskProcessSample] = []
    }

    private let lock = NSLock()
    private var previousTotalTime: [Int32: UInt64] = [:]
    private var previousDiskIO: [Int32: (read: UInt64, write: UInt64)] = [:]
    private var lastTimestamp: UInt64 = 0
    private var lastScan = ScanResult()
    private var lastScanNanos: UInt64 = 0

    // proc_taskinfo 的 pti_total_user/system 是 mach absolute time 刻度
    // (Apple Silicon 24MHz),必须经 timebase 换算成纳秒,否则百分比会小几十倍。
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func nanos(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    func topProcesses(sort: Sort, limit: Int) -> [ProcessSample] {
        lock.lock()
        defer { lock.unlock() }
        scanIfNeeded()
        let samples = lastScan.processSamples
        let ordered: [ProcessSample]
        switch sort {
        case .cpu:
            ordered = samples.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            ordered = samples.sorted { $0.memoryBytes > $1.memoryBytes }
        }
        return Array(ordered.prefix(limit))
    }

    /// 磁盘活动最高的进程(读+写速率),供磁盘弹窗使用。
    func topDiskActivity(limit: Int) -> [DiskProcessSample] {
        lock.lock()
        defer { lock.unlock() }
        scanIfNeeded()
        let ordered = lastScan.diskSamples.sorted {
            $0.readBytesPerSecond + $0.writeBytesPerSecond
                > $1.readBytesPerSecond + $1.writeBytesPerSecond
        }
        return Array(ordered.prefix(limit))
    }

    /// 全量扫描一次;250ms 内的调用直接复用结果。
    private func scanIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastScanNanos > 0, now - lastScanNanos < 250_000_000 { return }
        lastScanNanos = now

        let elapsed = lastTimestamp > 0 && now > lastTimestamp ? now - lastTimestamp : 0
        lastTimestamp = now

        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(size))
        // 第二个参数是缓冲区字节数,不是 PID 个数;传个数只会枚举到 1/4 的进程。
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }

        var currentTotalTime: [Int32: UInt64] = [:]
        currentTotalTime.reserveCapacity(Int(count))
        var currentDiskIO: [Int32: (read: UInt64, write: UInt64)] = [:]
        currentDiskIO.reserveCapacity(Int(count))
        var processSamples: [ProcessSample] = []
        var diskSamples: [DiskProcessSample] = []
        processSamples.reserveCapacity(Int(count))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskinfo()
            let result = withUnsafeMutableBytes(of: &info) { buffer -> Int32 in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, buffer.baseAddress, Int32(MemoryLayout<proc_taskinfo>.size))
            }
            guard result == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }

            let totalTime = info.pti_total_user + info.pti_total_system
            currentTotalTime[pid] = totalTime

            let cpuPercent: Double
            if elapsed > 0, let previous = previousTotalTime[pid], totalTime >= previous {
                cpuPercent = nanos(fromTicks: totalTime - previous) / Double(elapsed) * 100
            } else {
                cpuPercent = 0
            }

            let identity = Self.processIdentity(pid: pid)
            let usage = Self.usage(pid: pid)

            processSamples.append(ProcessSample(
                pid: pid,
                name: identity.name,
                cpuPercent: min(max(cpuPercent, 0), 999),
                memoryBytes: usage?.footprint ?? info.pti_resident_size,
                iconPath: identity.path
            ))

            if let usage {
                currentDiskIO[pid] = (usage.diskRead, usage.diskWrite)
                let readRate: Double
                let writeRate: Double
                if elapsed > 0, let previous = previousDiskIO[pid] {
                    readRate = usage.diskRead >= previous.read
                        ? Double(usage.diskRead - previous.read) / Double(elapsed) * 1_000_000_000 : 0
                    writeRate = usage.diskWrite >= previous.write
                        ? Double(usage.diskWrite - previous.write) / Double(elapsed) * 1_000_000_000 : 0
                } else {
                    readRate = 0
                    writeRate = 0
                }
                if readRate > 1 || writeRate > 1 {
                    diskSamples.append(DiskProcessSample(
                        pid: pid,
                        name: identity.name,
                        iconPath: identity.path,
                        readBytesPerSecond: readRate,
                        writeBytesPerSecond: writeRate
                    ))
                }
            }
        }
        previousTotalTime = currentTotalTime
        previousDiskIO = currentDiskIO
        lastScan = ScanResult(processSamples: processSamples, diskSamples: diskSamples)
    }

    /// 一次 rusage 调用同时取内存足迹与磁盘读写累计字节。
    /// Uses the system physical-footprint accounting; root processes may be inaccessible.
    private static func usage(pid: pid_t) -> (footprint: UInt64, diskRead: UInt64, diskWrite: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        guard info.ri_phys_footprint > 0 || info.ri_diskio_bytesread > 0 || info.ri_diskio_byteswritten > 0 else {
            return nil
        }
        return (info.ri_phys_footprint, info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    private static func processIdentity(pid: pid_t) -> (name: String, path: String?) {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 {
            let path = String(cString: pathBuffer)
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return (name, path) }
        }
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
            return (String(cString: nameBuffer), nil)
        }
        return ("pid \(pid)", nil)
    }
}
