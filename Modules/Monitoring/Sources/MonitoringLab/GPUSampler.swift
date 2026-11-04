import Darwin
import Foundation
import IOKit

/// GPU 实时状态。Apple Silicon 是统一内存，`memoryInUse` 只有绝对值，没有“总显存”。
public struct GPUSnapshot: Sendable, Equatable {
    public struct PerformanceState: Sendable, Equatable {
        /// 该档频率；读不到频率表时为 0。
        public let megahertz: Double
        /// 采样窗口内处在该档的时间占比（0...1，含空闲在内的总时间为分母）。
        public let residency: Double
    }

    public var available = false
    public var model = ""
    public var coreCount = 0
    /// 0...100，包含 WindowServer 的桌面合成。
    public var utilization: Double = 0
    public var memoryInUse: UInt64 = 0
    /// 以下来自 IOReport，读不到（或首帧没有差分基线）时为 nil / 空。
    public var powerWatts: Double?
    public var idleFraction: Double?
    public var averageMegahertz: Double?
    public var maxMegahertz: Double?
    /// 各工作档（不含 OFF），顺序与硬件 P1…Pn 一致。
    public var states: [PerformanceState] = []

    public init() {}
}

/// 读取方式全部无需 root：
/// - 利用率 / 已用内存：IOAccelerator 的 `PerformanceStatistics`（缓存 entry 后单键读取约 0.03 ms）；
/// - 功耗、频率档位：libIOReport 的 `Energy Model` 与 `GPU Stats`（私有接口，dlopen，失败则这些项为空）；
/// - 频率表：设备树 `pmgr` 的 `voltage-states9`；
/// - 进程占用：各 GPU user client 的 `AppUsage.accumulatedGPUTime`（只在详情可见时调用）。
/// 非线程安全：同一实例只在一个串行队列上调用。
final class GPUSampler {
    private var accelerator: io_service_t = 0
    private var model = ""
    private var coreCount = 0
    private var frequencies: [Double] = []

    private var report: IOReportSubscription?
    private var reportSetUp = false

    private var previousProcessGPU: [pid_t: UInt64] = [:]
    private var previousProcessTime: UInt64 = 0

    deinit {
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    func sample(now: UInt64) -> GPUSnapshot {
        var snapshot = GPUSnapshot()
        guard let stats = performanceStatistics() else { return snapshot }
        snapshot.available = true
        snapshot.model = model
        snapshot.coreCount = coreCount
        snapshot.utilization = min(max((stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0, 0), 100)
        snapshot.memoryInUse = (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
        if let top = frequencies.max(), top > 0 { snapshot.maxMegahertz = top }

        if !reportSetUp {
            reportSetUp = true
            report = IOReportSubscription()
        }
        if let delta = report?.sample(now: now) {
            if delta.seconds > 0, let energy = delta.gpuJoules {
                snapshot.powerWatts = energy / delta.seconds
            }
            let total = delta.residency.reduce(0, +)
            if total > 0 {
                snapshot.idleFraction = delta.residency[0] / total
                let known = frequencies.count == delta.residency.count
                var active = 0.0
                var weighted = 0.0
                for index in delta.residency.indices.dropFirst() {
                    let mhz = known ? frequencies[index] : 0
                    snapshot.states.append(.init(megahertz: mhz, residency: delta.residency[index] / total))
                    active += delta.residency[index]
                    weighted += delta.residency[index] * mhz
                }
                if known, active > 0 { snapshot.averageMegahertz = weighted / active }
            }
        }
        return snapshot
    }

    /// 每个进程在两次调用之间的 GPU 时间占比（0...100）。首次调用只建立基线。
    func processUsage(now: UInt64) -> [pid_t: Double] {
        guard ensureAccelerator() else { return [:] }
        var current: [pid_t: UInt64] = [:]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
            guard let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]],
                  let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pid = Self.pid(fromCreator: creator) else { continue }
            let nanos = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            current[pid, default: 0] += nanos
        }

        let elapsed = previousProcessTime > 0 && now > previousProcessTime ? Double(now - previousProcessTime) : 0
        var result: [pid_t: Double] = [:]
        if elapsed > 0 {
            for (pid, nanos) in current {
                guard let previous = previousProcessGPU[pid], nanos > previous else { continue }
                result[pid] = min(Double(nanos - previous) / elapsed * 100, 100)
            }
        }
        previousProcessGPU = current
        previousProcessTime = now
        return result
    }

    func resetProcessBaseline() {
        previousProcessGPU.removeAll()
        previousProcessTime = 0
    }

    /// `IOUserClientCreator` 形如 "pid 406, WindowServer"。
    static func pid(fromCreator text: String) -> pid_t? {
        guard text.hasPrefix("pid ") else { return nil }
        let digits = text.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    /// `voltage-states9` 每项 8 字节：UInt32 频率（Hz）+ UInt32 电压（mV），小端。
    static func parseFrequencyTable(_ data: Data) -> [Double] {
        guard data.count >= 8, data.count % 8 == 0 else { return [] }
        let raw: [UInt32] = stride(from: 0, to: data.count, by: 8).map { offset in
            data[data.startIndex + offset ..< data.startIndex + offset + 4].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        let divisor: Double = (raw.max() ?? 0) > 10_000_000 ? 1_000_000 : 1_000
        return raw.map { Double($0) / divisor }
    }

    // MARK: IOAccelerator

    private func ensureAccelerator() -> Bool {
        if accelerator != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return false }
        accelerator = service
        if model.isEmpty {
            model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            coreCount = (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue ?? 0
            let pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
            if pmgr != 0 {
                if let data = IORegistryEntryCreateCFProperty(pmgr, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data {
                    frequencies = Self.parseFrequencyTable(data)
                }
                IOObjectRelease(pmgr)
            }
        }
        return true
    }

    private func performanceStatistics() -> [String: Any]? {
        guard ensureAccelerator() else { return nil }
        if let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] {
            return stats
        }
        // 驱动重启后旧 entry 失效，下次重新匹配。
        IOObjectRelease(accelerator)
        accelerator = 0
        return nil
    }
}

// MARK: - IOReport

/// libIOReport 的最小封装：订阅 GPU 能耗与频率档位两类通道，按差分读取。
private final class IOReportSubscription {
    struct Delta {
        var seconds: Double = 0
        var gpuJoules: Double?
        /// 下标 0 为 OFF，其后为 P1…Pn，单位是 IOReport 的 tick。
        var residency: [Double] = []
    }

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary?, CFMutableDictionary?, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Iterate = @convention(c) (CFDictionary?, @convention(block) (CFDictionary?) -> Int32) -> Int32
    private typealias ChannelString = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary?, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary?) -> Int32
    private typealias StateResidency = @convention(c) (CFDictionary?, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let iterate: Iterate
    private let group: ChannelString
    private let subGroup: ChannelString
    private let channelName: ChannelString
    private let unitLabel: ChannelString
    private let integerValue: IntegerValue
    private let stateCount: StateCount
    private let stateResidency: StateResidency

    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyChannels = load("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let merge = load("IOReportMergeChannels", as: MergeChannels.self),
              let subscribe = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = load("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let iterate = load("IOReportIterate", as: Iterate.self),
              let group = load("IOReportChannelGetGroup", as: ChannelString.self),
              let subGroup = load("IOReportChannelGetSubGroup", as: ChannelString.self),
              let channelName = load("IOReportChannelGetChannelName", as: ChannelString.self),
              let unitLabel = load("IOReportChannelGetUnitLabel", as: ChannelString.self),
              let integerValue = load("IOReportSimpleGetIntegerValue", as: IntegerValue.self),
              let stateCount = load("IOReportStateGetCount", as: StateCount.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateResidency.self) else { return nil }

        guard let wanted = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        if let states = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            merge(wanted, states, nil)
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, wanted, &subscribed, 0, nil)?.takeRetainedValue(),
              let channels = subscribed?.takeRetainedValue() else { return nil }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.iterate = iterate
        self.group = group
        self.subGroup = subGroup
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.stateCount = stateCount
        self.stateResidency = stateResidency
        self.subscription = subscription
        self.channels = channels
    }

    /// 与上一次调用之间的差分；首次调用只建立基线并返回 nil。
    func sample(now: UInt64) -> Delta? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let previous, previousTime > 0, now > previousTime,
              let delta = createDelta(previous, current, nil)?.takeRetainedValue() else { return nil }

        var result = Delta()
        result.seconds = Double(now - previousTime) / 1_000_000_000
        var joules: Double?
        var residency: [Double] = []
        _ = iterate(delta) { [self] channel in
            guard let channel else { return 0 }
            let name = string(channelName, channel).trimmingCharacters(in: .whitespaces)
            if string(group, channel) == "Energy Model" {
                guard name == "GPU Energy" else { return 0 }
                let value = integerValue(channel, 0)
                guard value >= 0 else { return 0 }
                joules = (joules ?? 0) + Double(value) * Self.joulesPerUnit(string(unitLabel, channel))
                return 0
            }
            if string(subGroup, channel) == "GPU Performance States", name == "GPUPH" {
                let count = Int(stateCount(channel))
                residency = (0..<max(count, 0)).map { Double(max(stateResidency(channel, Int32($0)), 0)) }
            }
            return 0
        }
        result.gpuJoules = joules
        result.residency = residency
        return result
    }

    private func string(_ getter: ChannelString, _ channel: CFDictionary) -> String {
        getter(channel)?.takeUnretainedValue() as String? ?? ""
    }

    private static func joulesPerUnit(_ unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        default: return 1e-9 // nJ
        }
    }
}
