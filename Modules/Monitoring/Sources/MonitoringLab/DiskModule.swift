import AppKit
import IOKit

// 磁盘模块:挂载卷用量 + 全盘读写吞吐(IOKit 差分,不可用时优雅降级)。
final class DiskModule: BaseModule {
    struct Volume {
        var name: String
        var mountPath: String
        var totalBytes: UInt64
        var freeBytes: UInt64

        var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    struct Snapshot {
        var volumes: [Volume] = []
        var readBytesPerSecond: Double = 0
        var writeBytesPerSecond: Double = 0
    }

    // 采样队列独占的差分状态
    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var previousTimestamp: UInt64 = 0

    // 主线程消费
    private var snapshot = Snapshot()
    private var history: [Double] = []

    private var valueLabel: NSTextField?
    private var graphView: LineGraphView?
    private var throughputRows: [LegendRowView] = []
    private var volumeBars: [(nameLabel: NSTextField, detailLabel: NSTextField, bar: BarMeterView)] = []
    private var volumeStack: NSStackView?
    private var diskProcessListView: DiskProcessListView?

    init() {
        super.init(id: "disk", displayName: "磁盘")
    }

    override func sample() {
        let volumes = Self.mountedVolumes()
        let (readDelta, writeDelta, hasIOStats) = Self.ioStatisticsDelta(
            previousRead: previousRead,
            previousWrite: previousWrite,
            previousTimestamp: previousTimestamp
        )
        previousRead = readDelta.current
        previousWrite = writeDelta.current
        previousTimestamp = readDelta.timestamp

        var readPerSecond: Double = 0
        var writePerSecond: Double = 0
        if hasIOStats, readDelta.elapsed > 0 {
            readPerSecond = Double(readDelta.delta) / readDelta.elapsed
            writePerSecond = Double(writeDelta.delta) / readDelta.elapsed
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = Snapshot(
                volumes: volumes,
                readBytesPerSecond: max(readPerSecond, 0),
                writeBytesPerSecond: max(writePerSecond, 0)
            )
            self.applySnapshot()
        }
    }

    // MARK: 卷信息

    private static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var volumes: [Volume] = []
        for url in urls {
            let path = url.path
            // 跳过系统数据卷(与根卷重复)和隐藏挂载点
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let total = UInt64(values.volumeTotalCapacity ?? 0)
            // important-usage 容量包含可清除空间。
            let importantFree = Int(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            let strictFree = Int(max(values.volumeAvailableCapacity ?? 0, 0))
            let free = UInt64(max(importantFree, strictFree))
            guard total > 0 else { continue }
            let name = values.volumeName ?? (path as NSString).lastPathComponent
            volumes.append(Volume(name: name, mountPath: path, totalBytes: total, freeBytes: free))
        }
        return volumes
    }

    // MARK: 读写吞吐

    private struct IOReading {
        var current: UInt64
        var delta: UInt64
        var elapsed: Double // 秒
        var timestamp: UInt64
    }

    private static func ioStatisticsDelta(previousRead: UInt64, previousWrite: UInt64, previousTimestamp: UInt64)
        -> (read: IOReading, write: IOReading, hasIOStats: Bool) {
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        var found = false

        var iterator: io_iterator_t = 0
        defer {
            if iterator != 0 { IOObjectRelease(iterator) }
        }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            let now = DispatchTime.now().uptimeNanoseconds
            return (
                IOReading(current: previousRead, delta: 0, elapsed: 0, timestamp: now),
                IOReading(current: previousWrite, delta: 0, elapsed: 0, timestamp: now),
                false
            )
        }

        var entry: io_registry_entry_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let statistics = dictionary["Statistics"] as? [String: Any] {
                if let read = statistics["Bytes (Read)"] as? UInt64 { readBytes += read; found = true }
                if let write = statistics["Bytes (Write)"] as? UInt64 { writeBytes += write; found = true }
            }
            entry = IOIteratorNext(iterator)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTimestamp > 0 && now > previousTimestamp
            ? Double(now - previousTimestamp) / 1_000_000_000
            : 0

        let readDelta: UInt64 = readBytes >= previousRead ? readBytes - previousRead : 0
        let writeDelta: UInt64 = writeBytes >= previousWrite ? writeBytes - previousWrite : 0
        return (
            IOReading(current: readBytes, delta: readDelta, elapsed: elapsed, timestamp: now),
            IOReading(current: writeBytes, delta: writeDelta, elapsed: elapsed, timestamp: now),
            found
        )
    }

    // MARK: UI

    override func applySnapshot() {
        let rootVolume = snapshot.volumes.first { $0.mountPath == "/" }
        let rootFraction = rootVolume?.usedFraction ?? 0
        appendHistory(&history, snapshot.readBytesPerSecond + snapshot.writeBytesPerSecond)

        renderWidget(WidgetContent(
            iconSymbol: "internaldrive",
            text: Format.percent(rootFraction * 100),
            fraction: rootFraction,
            history: history
        ))

        valueLabel?.stringValue = rootVolume.map { "\(Format.percent($0.usedFraction * 100)) 已用" } ?? "无可用卷"
        graphView?.values = history

        if throughputRows.count == 2 {
            throughputRows[0].value = Format.decimalBytes(snapshot.readBytesPerSecond, perSecond: true)
            throughputRows[1].value = Format.decimalBytes(snapshot.writeBytesPerSecond, perSecond: true)
        }

        // 无 popupVisible 守卫:离屏渲染冒烟也要能填充数据
        diskProcessListView?.update(
            samples: ProcessListProvider.shared.topDiskActivity(limit: 5)
        )

        if volumeBars.count != snapshot.volumes.count {
            rebuildVolumeBars()
        }
        for (index, entry) in volumeBars.enumerated() where index < snapshot.volumes.count {
            let volume = snapshot.volumes[index]
            entry.nameLabel.stringValue = volume.name
            entry.detailLabel.stringValue = "\(Format.decimalBytes(Double(volume.usedBytes))) / \(Format.decimalBytes(Double(volume.totalBytes)))"
            entry.bar.segments = [
                BarMeterView.Segment(fraction: volume.usedFraction, color: AppTheme.accent)
            ]
        }
    }

    private func rebuildVolumeBars() {
        guard let volumeStack else { return }
        volumeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        volumeBars = []

        let limit = min(snapshot.volumes.count, 6)
        for _ in 0..<limit {
            let nameLabel = NSTextField(labelWithString: "—")
            nameLabel.font = AppTheme.font(ofSize: 12)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = AppTheme.secondaryText
            detailLabel.setContentHuggingPriority(.required, for: .horizontal)

            let titleRow = NSStackView(views: [nameLabel, detailLabel])
            titleRow.orientation = .horizontal
            titleRow.spacing = 8
            titleRow.translatesAutoresizingMaskIntoConstraints = false

            let bar = BarMeterView(frame: .zero)
            bar.barHeight = 6
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let column = NSStackView(views: [titleRow, bar])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            column.translatesAutoresizingMaskIntoConstraints = false
            volumeStack.addArrangedSubview(column)

            column.widthAnchor.constraint(equalTo: volumeStack.widthAnchor).isActive = true
            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            bar.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            volumeBars.append((nameLabel, detailLabel, bar))
        }
    }

    override func makePopupContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 头部
        let header = NSStackView(views: [])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let titleLabel = NSTextField(labelWithString: "磁盘")
        titleLabel.font = AppTheme.font(ofSize: 15, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        header.addArrangedSubview(titleLabel)
        let settingsButton = HoverButton()
        settingsButton.image = AppTheme.symbol("gearshape", size: 12)
        settingsButton.identifier = NSUserInterfaceItemIdentifier("diskSettingsButton")
        settingsButton.target = AppDelegate.shared
        settingsButton.action = #selector(AppDelegate.openPreferencesAction)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(settingsButton)
        header.translatesAutoresizingMaskIntoConstraints = false

        // 根卷大数字
        let bigValue = NSTextField(labelWithString: "0% 已用")
        bigValue.font = AppTheme.font(ofSize: 30, weight: .semibold)
        bigValue.textColor = AppTheme.primaryText
        bigValue.identifier = NSUserInterfaceItemIdentifier("diskBigValue")

        // 各卷用量
        let volumesTitle = NSTextField(labelWithString: "挂载的卷")
        volumesTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        volumesTitle.textColor = AppTheme.secondaryText
        let volumeStack = NSStackView()
        volumeStack.orientation = .vertical
        volumeStack.spacing = 8
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        self.volumeStack = volumeStack

        // 读写吞吐
        let throughputTitle = NSTextField(labelWithString: "读写吞吐")
        throughputTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        throughputTitle.textColor = AppTheme.secondaryText
        let readRow = LegendRowView(name: "读取", color: AppTheme.accent)
        let writeRow = LegendRowView(name: "写入", color: NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1))
        let legendStack = NSStackView(views: [readRow, writeRow])
        legendStack.orientation = .vertical
        legendStack.spacing = 2
        legendStack.translatesAutoresizingMaskIntoConstraints = false

        // 吞吐曲线
        let graph = LineGraphView(frame: .zero)
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 48).isActive = true

        // 高占用进程(读/写速率)
        let processTitle = NSTextField(labelWithString: "高占用进程")
        processTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        processTitle.textColor = AppTheme.secondaryText
        let diskProcessList = DiskProcessListView(title: "", limit: 5)
        diskProcessList.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header)
        stack.setCustomSpacing(12, after: header)
        stack.addArrangedSubview(bigValue)
        stack.addArrangedSubview(volumesTitle)
        stack.addArrangedSubview(volumeStack)
        stack.addArrangedSubview(throughputTitle)
        stack.addArrangedSubview(legendStack)
        stack.addArrangedSubview(graph)
        stack.addArrangedSubview(processTitle)
        stack.addArrangedSubview(diskProcessList)

        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        volumeStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        readRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        writeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        legendStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        diskProcessList.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let widthAnchor = stack.widthAnchor.constraint(equalToConstant: 340)
        widthAnchor.priority = .defaultHigh
        widthAnchor.isActive = true

        valueLabel = bigValue
        graphView = graph
        throughputRows = [readRow, writeRow]
        diskProcessListView = diskProcessList
        volumeBars = []
        rebuildVolumeBars()
        return stack
    }

    override func readOnlySummary() -> [String: Any] {
        var result = super.readOnlySummary()
        result["volumes"] = snapshot.volumes.map {
            [
                "name": $0.name,
                "mountPath": $0.mountPath,
                "totalBytes": $0.totalBytes,
                "freeBytes": $0.freeBytes,
                "usedBytes": $0.usedBytes,
                "usedFraction": $0.usedFraction,
            ]
        }
        result["readBytesPerSecond"] = snapshot.readBytesPerSecond
        result["writeBytesPerSecond"] = snapshot.writeBytesPerSecond
        result["history"] = history
        return result
    }
}

#if DEBUG
extension DiskModule {
    func debugSnapshot() -> Snapshot { snapshot }

    func loadDebugSnapshot() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        snapshot = Snapshot(
            volumes: [
                Volume(name: "Macintosh HD", mountPath: "/", totalBytes: 494 * gigabyte, freeBytes: 271 * gigabyte),
                Volume(name: "Backup", mountPath: "/Volumes/Backup", totalBytes: 2 * 1024 * gigabyte, freeBytes: 640 * gigabyte),
            ],
            readBytesPerSecond: 4_216_000,
            writeBytesPerSecond: 812_000
        )
        history = DebugFixtures.waveHistory(base: 3_200_000, amplitude: 2_400_000)
    }
}
#endif
