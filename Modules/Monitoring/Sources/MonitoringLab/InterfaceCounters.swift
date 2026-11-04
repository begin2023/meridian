import Darwin
import Foundation

/// 读取各网络接口的累计收发字节。
///
/// `NET_RT_IFLIST2` 的 `if_msghdr2.ifm_data` 在 macOS 27 上只带回 32 位计数，
/// 累计到 4 GiB 就回绕；读出来像“累计被重置”。改走 ifmib
/// （`net.link.generic.ifdata.<index>.general`）拿完整的 64 位值，
/// 结果与系统 `netstat -ibn` 一致。
public enum InterfaceCounters {
    public static func read() -> [String: (received: UInt64, sent: UInt64)] {
        var result: [String: (received: UInt64, sent: UInt64)] = [:]
        for index in interfaceIndexes() {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            // 回环是本机 IPC，不是网络流量。
            guard !name.isEmpty, !name.hasPrefix("lo") else { continue }
            result[name] = (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
        }
        return result
    }

    /// 只有物理网卡（en*）承载真实链路流量。开 VPN 时 utun* 只是镜像同一份数据，
    /// 求和会双倍计数；utun 的地址也是隧道内的虚拟地址，不适合当作本机 IP。
    public static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// 逐个枚举索引。索引不连续（隧道和虚拟接口会占用较大的值），
    /// 不能用接口数量当上界，否则会漏掉后建的 utun* 等接口。
    private static func interfaceIndexes() -> [Int32] {
        guard let list = if_nameindex() else { return Array(1...32) }
        defer { if_freenameindex(list) }
        var indexes: [Int32] = []
        var cursor = list
        while cursor.pointee.if_index != 0 {
            indexes.append(Int32(bitPattern: cursor.pointee.if_index))
            cursor = cursor.advanced(by: 1)
        }
        return indexes.isEmpty ? Array(1...32) : indexes
    }
}

/// 把接口计数器换算成“不回退”的累计量。
///
/// 计数器复位、接口消失后重建（Wi-Fi 重连、VPN 拉起、驱动重载）都会让原始读数变小。
/// 这里把上一轮读数并入基线，界面上的累计值只增不减；接口暂时消失也不清零。
public struct InterfaceVolumeTracker {
    public init() {}

    private var finished: [String: (received: UInt64, sent: UInt64)] = [:]
    private var last: [String: (received: UInt64, sent: UInt64)] = [:]

    /// 用本轮读数刷新累计量，返回每个接口当前的总收/发字节。
    public mutating func update(
        _ counters: [String: (received: UInt64, sent: UInt64)]
    ) -> [String: (received: UInt64, sent: UInt64)] {
        retireMissing(in: counters)
        for (name, current) in counters {
            if let previous = last[name], current.received < previous.received || current.sent < previous.sent {
                carryOver(name, previous)
            }
            last[name] = current
        }
        var volumes = finished
        for (name, current) in counters {
            let base = finished[name] ?? (received: 0, sent: 0)
            volumes[name] = (base.received &+ current.received, base.sent &+ current.sent)
        }
        return volumes
    }

    private mutating func retireMissing(in counters: [String: (received: UInt64, sent: UInt64)]) {
        for (name, previous) in last where counters[name] == nil {
            carryOver(name, previous)
            last.removeValue(forKey: name)
        }
    }

    private mutating func carryOver(_ name: String, _ previous: (received: UInt64, sent: UInt64)) {
        let base = finished[name] ?? (received: 0, sent: 0)
        finished[name] = (base.received &+ previous.received, base.sent &+ previous.sent)
    }
}

/// 一次网络采样：物理网卡的合计速率与累计字节，以及主接口。
struct NetworkTrafficSample {
    var downBytesPerSecond: Double = 0
    var upBytesPerSecond: Double = 0
    var totalDownBytes: UInt64 = 0
    var totalUpBytes: UInt64 = 0
    var primaryInterface: String?
    var activeInterfaces: [String] = []
}

/// 网络速率的差分状态。非线程安全：同一实例只在一个串行队列上调用。
struct NetworkTrafficSampler {
    private var previous: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private var tracker = InterfaceVolumeTracker()

    mutating func sample(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> NetworkTrafficSample {
        let counters = InterfaceCounters.read().filter { InterfaceCounters.isPhysical($0.key) }
        let volumes = tracker.update(counters)

        var result = NetworkTrafficSample()
        var deltas: [String: (received: UInt64, sent: UInt64)] = [:]
        if previousTime > 0, now > previousTime {
            let elapsed = Double(now - previousTime) / 1_000_000_000
            for (name, current) in counters {
                guard let before = previous[name] else { continue }
                let received = current.received >= before.received ? current.received - before.received : 0
                let sent = current.sent >= before.sent ? current.sent - before.sent : 0
                deltas[name] = (received, sent)
                if received + sent > 0 { result.activeInterfaces.append(name) }
                result.downBytesPerSecond += Double(received) / elapsed
                result.upBytesPerSecond += Double(sent) / elapsed
            }
        }
        previous = counters
        previousTime = now

        // 累计量覆盖所有物理网卡：Wi-Fi 换成有线、或某块网卡暂时消失，
        // 已经跑过的流量都不该从界面上消失。
        for (_, volume) in volumes {
            result.totalDownBytes &+= volume.received
            result.totalUpBytes &+= volume.sent
        }

        result.primaryInterface = result.activeInterfaces.max {
            (deltas[$0]?.received ?? 0) + (deltas[$0]?.sent ?? 0)
                < (deltas[$1]?.received ?? 0) + (deltas[$1]?.sent ?? 0)
        } ?? volumes.max {
            $0.value.received + $0.value.sent < $1.value.received + $1.value.sent
        }?.key
        return result
    }
}
