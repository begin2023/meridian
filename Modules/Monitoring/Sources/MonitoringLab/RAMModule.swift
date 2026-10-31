import AppKit
import Darwin

// 内存模块:分类明细 + 占用曲线 + 内存占用最高的进程。
final class RAMModule: BaseModule {
    struct Snapshot {
        var totalBytes: UInt64 = 0
        var usedBytes: UInt64 = 0
        var appBytes: UInt64 = 0
        var wiredBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        var swapUsedBytes: UInt64 = 0
        var swapTotalBytes: UInt64 = 0
        var topProcesses: [ProcessSample] = []
    }

    private var snapshot = Snapshot()
    private var history: [Double] = []

    private var valueLabel: NSTextField?
    private var totalLabel: NSTextField?
    private var graphView: LineGraphView?
    private var barView: BarMeterView?
    private var legendRows: [LegendRowView] = []
    private var processList: ProcessListView?

    init() {
        super.init(id: "ram", displayName: "内存")
    }

    override func sample() {
        var vmStatistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStatistics) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, intPointer, &count)
            }
        }
        mach_port_deallocate(mach_task_self_, hostPort)
        guard result == KERN_SUCCESS else { return }

        // 按系统虚拟内存统计字段计算:
        //   应用内存 = internal − purgeable;联动 = wire;压缩 = compressor 占用
        //   已用 = 应用 + 联动 + 压缩;可用 = total − 已用(含非活跃与文件缓存)
        let pageSize = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(vmStatistics.internal_page_count)
        let purgeablePages = UInt64(vmStatistics.purgeable_count)
        let wiredPages = UInt64(vmStatistics.wire_count)
        let compressedPages = UInt64(vmStatistics.compressor_page_count)

        let appBytes = internalPages > purgeablePages ? (internalPages - purgeablePages) * pageSize : 0
        let wiredBytes = wiredPages * pageSize
        let compressedBytes = compressedPages * pageSize
        let usedBytes = appBytes + wiredBytes + compressedBytes
        let totalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
        let freeBytes = totalBytes > usedBytes ? totalBytes - usedBytes : 0

        let swap = Self.swapUsage()
        let topProcesses = ProcessListProvider.shared.topProcesses(sort: .memory, limit: 5)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = Snapshot(
                totalBytes: totalBytes,
                usedBytes: usedBytes,
                appBytes: appBytes,
                wiredBytes: wiredBytes,
                compressedBytes: compressedBytes,
                freeBytes: freeBytes,
                swapUsedBytes: swap.used,
                swapTotalBytes: swap.total,
                topProcesses: topProcesses
            )
            self.applySnapshot()
        }
    }

    private static func swapUsage() -> (total: UInt64, used: UInt64) {
        var size = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buffer, &size, nil, 0) == 0, size >= 24 else { return (0, 0) }

        // macOS 27 起 vm.swapusage 返回 32 字节二进制结构(实测字段与
        // /usr/sbin/sysctl 输出同刻一致):
        //   { uint64 total; uint64 free; uint64 used; uint32 flags; uint32 保留 }
        // 旧系统返回 "total = X used = Y free = Z" 字符串,按首字节区分。
        if buffer[0] == UInt8(ascii: "t") {
            return parseLegacyString(buffer, size)
        }
        return buffer.withUnsafeBytes { raw in
            let total = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            let used = raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            return (total, min(used, total))
        }
    }

    private static func parseLegacyString(_ buffer: [UInt8], _ size: Int) -> (total: UInt64, used: UInt64) {
        // 形如 "total = 1024.00M used = 0.00M free = 1024.00M"
        let text = buffer.prefix(while: { $0 != 0 })
        let parts = String(decoding: text, as: UTF8.self).split(separator: " ").map(String.init)
        var total: UInt64 = 0
        var used: UInt64 = 0
        if let totalIndex = parts.firstIndex(of: "total"), totalIndex + 2 < parts.count {
            total = parseBytes(parts[totalIndex + 2])
        }
        if let usedIndex = parts.firstIndex(of: "used"), usedIndex + 2 < parts.count {
            used = parseBytes(parts[usedIndex + 2])
        }
        return (total, used)
    }

    private static func parseBytes(_ token: String) -> UInt64 {
        guard let unitIndex = token.firstIndex(where: { $0.isLetter }) else { return 0 }
        let numberPart = token[..<unitIndex]
        let unitPart = token[unitIndex...]
        guard let value = Double(numberPart) else { return 0 }
        switch unitPart {
        case "K": return UInt64(value * 1024)
        case "M": return UInt64(value * 1024 * 1024)
        case "G": return UInt64(value * 1024 * 1024 * 1024)
        case "T": return UInt64(value * 1024 * 1024 * 1024 * 1024)
        default: return UInt64(value)
        }
    }

    override func applySnapshot() {
        let usedFraction = snapshot.totalBytes > 0 ? Double(snapshot.usedBytes) / Double(snapshot.totalBytes) : 0
        appendHistory(&history, usedFraction * 100)

        renderWidget(WidgetContent(
            iconSymbol: "memorychip",
            text: Format.percent(usedFraction * 100),
            fraction: usedFraction,
            history: history,
            graphMax: 100
        ))

        valueLabel?.stringValue = Format.bytes(Double(snapshot.usedBytes))
        totalLabel?.stringValue = "共 \(Format.bytes(Double(snapshot.totalBytes)))"
        graphView?.values = history
        barView?.segments = [
            BarMeterView.Segment(fraction: usedFraction, color: AppTheme.accent)
        ]

        if legendRows.count == 5 {
            legendRows[0].value = Format.bytes(Double(snapshot.appBytes))
            legendRows[1].value = Format.bytes(Double(snapshot.wiredBytes))
            legendRows[2].value = Format.bytes(Double(snapshot.compressedBytes))
            legendRows[3].value = snapshot.swapTotalBytes > 0
                ? "\(Format.bytes(Double(snapshot.swapUsedBytes))) / \(Format.bytes(Double(snapshot.swapTotalBytes)))"
                : "未启用"
            legendRows[4].value = Format.bytes(Double(snapshot.freeBytes))
        }

        processList?.update(samples: snapshot.topProcesses) { sample in
            Format.bytes(Double(sample.memoryBytes))
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
        let titleLabel = NSTextField(labelWithString: "内存")
        titleLabel.font = AppTheme.font(ofSize: 15, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        let totalLabel = NSTextField(labelWithString: "")
        totalLabel.font = AppTheme.font(ofSize: 11)
        totalLabel.textColor = AppTheme.secondaryText
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(totalLabel)
        let settingsButton = HoverButton()
        settingsButton.image = AppTheme.symbol("gearshape", size: 12)
        settingsButton.identifier = NSUserInterfaceItemIdentifier("ramSettingsButton")
        settingsButton.target = AppDelegate.shared
        settingsButton.action = #selector(AppDelegate.openPreferencesAction)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(settingsButton)
        header.translatesAutoresizingMaskIntoConstraints = false

        // 大数字 + 用量条
        let bigValue = NSTextField(labelWithString: "0B")
        bigValue.font = AppTheme.font(ofSize: 30, weight: .semibold)
        bigValue.textColor = AppTheme.primaryText
        bigValue.identifier = NSUserInterfaceItemIdentifier("ramBigValue")
        let bar = BarMeterView(frame: .zero)
        bar.barHeight = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 10).isActive = true

        // 分类明细
        let legendStack = NSStackView()
        legendStack.orientation = .vertical
        legendStack.spacing = 2
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        let legendColors: [NSColor?] = [
            AppTheme.accent,
            NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.72, green: 0.5, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1),
            NSColor(calibratedWhite: 0.55, alpha: 1),
        ]
        let names = ["应用内存", "联动内存", "已压缩", "已用交换", "可用"]
        var rows: [LegendRowView] = []
        for (index, name) in names.enumerated() {
            let row = LegendRowView(name: name, color: legendColors[index])
            legendStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: legendStack.widthAnchor).isActive = true
            rows.append(row)
        }

        // 曲线
        let graph = LineGraphView(frame: .zero)
        graph.fixedMaxValue = 100
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 56).isActive = true

        // Top 进程
        let processList = ProcessListView(title: "内存占用最高的进程", limit: 5)

        stack.addArrangedSubview(header)
        stack.setCustomSpacing(12, after: header)
        stack.addArrangedSubview(bigValue)
        stack.addArrangedSubview(bar)
        stack.addArrangedSubview(legendStack)
        stack.addArrangedSubview(graph)
        stack.addArrangedSubview(processList)

        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        legendStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        processList.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let widthAnchor = stack.widthAnchor.constraint(equalToConstant: 340)
        widthAnchor.priority = .defaultHigh
        widthAnchor.isActive = true

        valueLabel = bigValue
        self.totalLabel = totalLabel
        graphView = graph
        barView = bar
        legendRows = rows
        self.processList = processList
        return stack
    }

    override func readOnlySummary() -> [String: Any] {
        var result = super.readOnlySummary()
        result["totalBytes"] = snapshot.totalBytes
        result["usedBytes"] = snapshot.usedBytes
        result["appBytes"] = snapshot.appBytes
        result["wiredBytes"] = snapshot.wiredBytes
        result["compressedBytes"] = snapshot.compressedBytes
        result["freeBytes"] = snapshot.freeBytes
        result["swapUsedBytes"] = snapshot.swapUsedBytes
        result["swapTotalBytes"] = snapshot.swapTotalBytes
        result["history"] = history
        result["topProcesses"] = snapshot.topProcesses.map {
            [
                "pid": Int($0.pid),
                "name": $0.name,
                "cpuPercent": $0.cpuPercent,
                "memoryBytes": $0.memoryBytes,
            ]
        }
        return result
    }
}

#if DEBUG
extension RAMModule {
    func debugSnapshot() -> Snapshot { snapshot }

    func loadDebugSnapshot() {
        let total: UInt64 = 16 * 1024 * 1024 * 1024
        let app: UInt64 = 4_610_000_000
        let wired: UInt64 = 3_680_000_000
        let compressed: UInt64 = 4_670_000_000
        let used: UInt64 = app + wired + compressed
        snapshot = Snapshot(
            totalBytes: total,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: total - used,
            swapUsedBytes: 1_073_741_824,
            swapTotalBytes: 4 * 1024 * 1024 * 1024,
            topProcesses: DebugFixtures.processes()
        )
        history = DebugFixtures.waveHistory(base: 58, amplitude: 8)
    }
}
#endif
