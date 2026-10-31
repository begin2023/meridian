import AppKit
import Darwin

// CPU 模块:总占用 + 每核占用曲线 + 占用最高的进程。
final class CPUModule: BaseModule {
    struct Snapshot {
        var totalPercent: Double = 0
        var corePercents: [Double] = []
        var topProcesses: [ProcessSample] = []
    }

    // 采样队列独占的差分状态
    private var previousBusy: [UInt64] = []
    private var previousIdle: [UInt64] = []

    // 主线程消费
    private var snapshot = Snapshot()
    private var history: [Double] = []

    // 弹窗控件引用(主线程)
    private var valueLabel: NSTextField?
    private var graphView: LineGraphView?
    private var coreBars: [(label: NSTextField, bar: BarMeterView)] = []
    private var processList: ProcessListView?

    init() {
        super.init(id: "cpu", displayName: "CPU")
    }

    override func sample() {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var messageCount: mach_msg_type_number_t = 0

        let hostPort = mach_host_self()
        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &messageCount
        )
        mach_port_deallocate(mach_task_self_, hostPort)
        guard result == KERN_SUCCESS, let info = processorInfo, processorCount > 0 else { return }

        var busy = [UInt64](repeating: 0, count: Int(processorCount))
        var idle = [UInt64](repeating: 0, count: Int(processorCount))
        var corePercents = [Double](repeating: 0, count: Int(processorCount))
        var totalBusy: UInt64 = 0
        var totalIdle: UInt64 = 0

        for core in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * core
            let user = UInt64(info[offset + Int(CPU_STATE_USER)])
            let system = UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[offset + Int(CPU_STATE_NICE)])
            let idleTicks = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let coreBusy = user + system + nice

            busy[core] = coreBusy
            idle[core] = idleTicks

            if previousBusy.count == Int(processorCount), previousIdle.count == Int(processorCount) {
                let deltaBusy = coreBusy > previousBusy[core] ? coreBusy - previousBusy[core] : 0
                let deltaIdle = idleTicks > previousIdle[core] ? idleTicks - previousIdle[core] : 0
                let deltaTotal = deltaBusy + deltaIdle
                if deltaTotal > 0 {
                    corePercents[core] = Double(deltaBusy) / Double(deltaTotal) * 100
                }
                totalBusy += deltaBusy
                totalIdle += deltaIdle
            }
        }

        let size = vm_size_t(messageCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)

        previousBusy = busy
        previousIdle = idle

        let totalPercent = (totalBusy + totalIdle) > 0
            ? Double(totalBusy) / Double(totalBusy + totalIdle) * 100
            : 0
        let topProcesses = ProcessListProvider.shared.topProcesses(sort: .cpu, limit: 5)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = Snapshot(
                totalPercent: min(max(totalPercent, 0), 100),
                corePercents: corePercents,
                topProcesses: topProcesses
            )
            self.applySnapshot()
        }
    }

    override func applySnapshot() {
        appendHistory(&history, snapshot.totalPercent)

        renderWidget(WidgetContent(
            iconSymbol: "cpu",
            text: Format.percent(snapshot.totalPercent),
            fraction: snapshot.totalPercent / 100,
            history: history,
            graphMax: 100
        ))

        valueLabel?.stringValue = Format.percent(snapshot.totalPercent, decimals: 1)
        graphView?.values = history

        if coreBars.count != snapshot.corePercents.count, let container = coresContainer {
            rebuildCoreBars(in: container)
        }
        for (index, entry) in coreBars.enumerated() where index < snapshot.corePercents.count {
            entry.bar.segments = [
                BarMeterView.Segment(fraction: snapshot.corePercents[index] / 100, color: AppTheme.accent)
            ]
        }

        processList?.update(samples: snapshot.topProcesses) { sample in
            Format.percent(sample.cpuPercent, decimals: 1)
        }
    }

    override func makePopupContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 头部:模块名 + 芯片型号 + 设置按钮
        let header = NSStackView(views: [])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let titleLabel = NSTextField(labelWithString: "CPU")
        titleLabel.font = AppTheme.font(ofSize: 15, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        let subtitle = NSTextField(labelWithString: sysctlString("machdep.cpu.brand_string") ?? "Mac")
        subtitle.font = AppTheme.font(ofSize: 11)
        subtitle.textColor = AppTheme.secondaryText
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(subtitle)
        let settingsButton = HoverButton()
        settingsButton.image = AppTheme.symbol("gearshape", size: 12)
        settingsButton.identifier = NSUserInterfaceItemIdentifier("cpuSettingsButton")
        settingsButton.target = AppDelegate.shared
        settingsButton.action = #selector(AppDelegate.openPreferencesAction)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(settingsButton)
        header.translatesAutoresizingMaskIntoConstraints = false

        // 大数字 + 曲线
        let bigValue = NSTextField(labelWithString: "0%")
        bigValue.font = AppTheme.font(ofSize: 30, weight: .semibold)
        bigValue.textColor = AppTheme.primaryText
        bigValue.identifier = NSUserInterfaceItemIdentifier("cpuBigValue")
        let graph = LineGraphView(frame: .zero)
        graph.fixedMaxValue = 100
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 64).isActive = true

        // 每核条形(两列)
        let coresTitle = NSTextField(labelWithString: "每核占用")
        coresTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        coresTitle.textColor = AppTheme.secondaryText
        let coresContainer = NSStackView()
        coresContainer.orientation = .vertical
        coresContainer.spacing = 4
        coresContainer.translatesAutoresizingMaskIntoConstraints = false

        // Top 进程
        let processList = ProcessListView(title: "占用最高的进程", limit: 5)

        stack.addArrangedSubview(header)
        stack.setCustomSpacing(12, after: header)
        stack.addArrangedSubview(bigValue)
        stack.addArrangedSubview(graph)
        stack.addArrangedSubview(coresTitle)
        stack.addArrangedSubview(coresContainer)
        stack.addArrangedSubview(processList)

        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        coresContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        processList.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let widthAnchor = stack.widthAnchor.constraint(equalToConstant: 340)
        widthAnchor.priority = .defaultHigh
        widthAnchor.isActive = true

        valueLabel = bigValue
        graphView = graph
        self.processList = processList
        coreBars = []
        self.coresContainer = coresContainer
        rebuildCoreBars(in: coresContainer)
        return stack
    }

    private var coresContainer: NSStackView?

    private func rebuildCoreBars(in container: NSStackView) {
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        coreBars = []
        guard !snapshot.corePercents.isEmpty else { return }

        var row: NSStackView?
        for (index, _) in snapshot.corePercents.enumerated() {
            let label = NSTextField(labelWithString: String(format: "%2d", index + 1))
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = AppTheme.secondaryText
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 16).isActive = true

            let bar = BarMeterView(frame: .zero)
            bar.barHeight = 5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true

            let cell = NSStackView(views: [label, bar])
            cell.orientation = .horizontal
            cell.spacing = 5
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.distribution = .fill

            if row == nil {
                row = NSStackView(views: [cell])
                row?.orientation = .horizontal
                row?.spacing = 12
                row?.translatesAutoresizingMaskIntoConstraints = false
                row?.distribution = .fillEqually
                container.addArrangedSubview(row!)
                row?.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            } else {
                row?.addArrangedSubview(cell)
                row = nil
            }
            coreBars.append((label, bar))
        }
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    override func readOnlySummary() -> [String: Any] {
        var result = super.readOnlySummary()
        result["totalPercent"] = snapshot.totalPercent
        result["corePercents"] = snapshot.corePercents
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
extension CPUModule {
    func debugSnapshot() -> Snapshot { snapshot }

    func loadDebugSnapshot() {
        snapshot = Snapshot(
            totalPercent: 34.6,
            corePercents: (0..<10).map { 12 + 32 * abs(sin(Double($0) * 1.7)) },
            topProcesses: DebugFixtures.processes()
        )
        history = DebugFixtures.waveHistory()
    }
}
#endif
