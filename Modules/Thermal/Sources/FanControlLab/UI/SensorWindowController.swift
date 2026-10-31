import AppKit

/// Read-only fan and temperature workspace.
///
/// This is the module's only dedicated work window. Preferences remain owned by
/// the shell in embedded mode; this controller contains no editable settings or
/// hardware controls.
@MainActor
final class SensorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var latestUpdate: MonitorUpdate?
    private var startupError: String?

    private let rpmValue = NSTextField(labelWithString: "—")
    private let temperatureValue = NSTextField(labelWithString: "—")
    private let syncLabel = NSTextField(labelWithString: "等待 SMC 采样…")
    private let detailLabel = NSTextField(labelWithString: "系统自动控制")
    private let fanTable = NSTableView()
    private let sensorTable = NSTableView()

    var isVisible: Bool {
        window?.isVisible == true
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "传感器详情"
        window.subtitle = "风扇与温度 · 只读监控"
        window.minSize = NSSize(width: 660, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setFrameAutosaveName("FanControlLab.SensorWindow")
        super.init(window: window)
        window.contentView = buildContent()
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(update: MonitorUpdate?, startupError: String?) {
        latestUpdate = update
        self.startupError = startupError
        render()
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        effect.state = .active

        let icon = NSImageView()
        icon.image = AppTheme.symbol("fan", size: 30, weight: .medium)
            ?? AppTheme.symbol("thermometer.medium", size: 30, weight: .medium)
        icon.contentTintColor = AppTheme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "传感器详情")
        title.font = AppTheme.font(ofSize: 26, weight: .semibold)
        title.textColor = AppTheme.primaryText
        let subtitle = NSTextField(labelWithString: "实际转速与温度候选 · 系统保持自动控制")
        subtitle.font = AppTheme.font(ofSize: 12)
        subtitle.textColor = AppTheme.secondaryText
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let readOnly = NSTextField(labelWithString: "只读")
        readOnly.font = AppTheme.font(ofSize: 11, weight: .semibold)
        readOnly.textColor = AppTheme.accent
        readOnly.alignment = .center
        readOnly.wantsLayer = true
        readOnly.layer?.borderColor = AppTheme.accent.withAlphaComponent(0.45).cgColor
        readOnly.layer?.borderWidth = 1
        readOnly.layer?.cornerRadius = 10
        readOnly.translatesAutoresizingMaskIntoConstraints = false
        readOnly.widthAnchor.constraint(equalToConstant: 56).isActive = true
        readOnly.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let header = NSStackView(views: [icon, titleStack, NSView(), readOnly])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let rpmCard = makeMetricCard(
            title: "当前转速",
            value: rpmValue,
            footnote: "首个风扇 · 系统报告"
        )
        let tempCard = makeMetricCard(
            title: "CPU 温度",
            value: temperatureValue,
            footnote: "候选传感器平均"
        )
        let metricRow = NSStackView(views: [rpmCard, tempCard])
        metricRow.orientation = .horizontal
        metricRow.distribution = .fillEqually
        metricRow.spacing = 12

        configureFanTable()
        configureSensorTable()

        let fanHeader = sectionHeader("风扇", trailing: detailLabel)
        let fanScroll = tableScrollView(fanTable, minimumHeight: 112)
        let sensorHeader = sectionHeader("温度传感器", trailing: syncLabel)
        let sensorScroll = tableScrollView(sensorTable, minimumHeight: 142)

        let footer = NSTextField(
            wrappingLabelWithString: "此窗口只读。风扇继续由系统自动控制；不包含写入、策略武装或特权助手安装入口。"
        )
        footer.font = AppTheme.font(ofSize: 11)
        footer.textColor = AppTheme.secondaryText
        footer.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            header,
            metricRow,
            fanHeader,
            fanScroll,
            sensorHeader,
            sensorScroll,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        for view in [header, metricRow, fanHeader, fanScroll, sensorHeader, sensorScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
            metricRow.heightAnchor.constraint(equalToConstant: 96),
        ])
        return effect
    }

    private func makeMetricCard(
        title: String,
        value: NSTextField,
        footnote: String
    ) -> NSView {
        let card = SensorCardView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        titleLabel.textColor = AppTheme.secondaryText
        value.font = AppTheme.font(ofSize: 32, weight: .semibold)
        value.textColor = AppTheme.primaryText
        value.lineBreakMode = .byTruncatingTail
        let footnoteLabel = NSTextField(labelWithString: footnote)
        footnoteLabel.font = AppTheme.font(ofSize: 10.5)
        footnoteLabel.textColor = AppTheme.secondaryText

        let stack = NSStackView(views: [titleLabel, value, footnoteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func sectionHeader(_ title: String, trailing: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        trailing.font = AppTheme.font(ofSize: 11)
        trailing.textColor = AppTheme.secondaryText
        trailing.alignment = .right

        let row = NSStackView(views: [titleLabel, NSView(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func tableScrollView(_ table: NSTableView, minimumHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        return scroll
    }

    private func configureFanTable() {
        fanTable.identifier = NSUserInterfaceItemIdentifier("fans")
        addColumn("fanName", title: "风扇", width: 250, to: fanTable)
        addColumn("fanRotation", title: "实际 / 目标", width: 190, to: fanTable)
        addColumn("fanRange", title: "系统范围", width: 190, to: fanTable)
        configureBase(fanTable)
    }

    private func configureSensorTable() {
        sensorTable.identifier = NSUserInterfaceItemIdentifier("sensors")
        addColumn("sensorName", title: "传感器", width: 350, to: sensorTable)
        addColumn("sensorKind", title: "类型", width: 120, to: sensorTable)
        addColumn("sensorTemperature", title: "温度", width: 120, to: sensorTable)
        configureBase(sensorTable)
    }

    private func addColumn(
        _ id: String,
        title: String,
        width: CGFloat,
        to table: NSTableView
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min(width, 90)
        table.addTableColumn(column)
    }

    private func configureBase(_ table: NSTableView) {
        table.delegate = self
        table.dataSource = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 12, height: 1)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = AppTheme.subtleBorder
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) {
            table.style = .plain
        }
    }

    // MARK: - Rendering

    private func render() {
        let settings = AppSettings.shared
        let fans = latestUpdate?.fans ?? []
        let sensors = sortedSensors(latestUpdate?.sensors ?? [])
        let cpu = MonitorUpdate.groupAverage(of: sensors, kind: .cpu)

        rpmValue.stringValue = fans.first.map { String(format: "%.0f RPM", $0.currentRPM) } ?? "—"
        temperatureValue.stringValue = cpu.map(settings.formattedTemperature) ?? "—"
        detailLabel.stringValue = fans.isEmpty
            ? "未检测到风扇"
            : "\(fans.count) 个风扇 · 系统自动控制"

        if let startupError {
            syncLabel.stringValue = "SMC 不可用"
            syncLabel.toolTip = startupError
        } else if latestUpdate == nil {
            syncLabel.stringValue = "等待首次采样…"
            syncLabel.toolTip = nil
        } else {
            syncLabel.stringValue = "只读 · \(sensors.count) 个温度点"
            syncLabel.toolTip = nil
        }

        fanTable.reloadData()
        sensorTable.reloadData()
    }

    private func sortedSensors(_ sensors: [SensorSnapshot]) -> [SensorSnapshot] {
        Array(
            sensors
                .filter { $0.temperatureCelsius.isFinite && $0.temperatureCelsius > 0 }
                .sorted { $0.temperatureCelsius > $1.temperatureCelsius }
                .prefix(64)
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === fanTable {
            return latestUpdate?.fans.count ?? 0
        }
        return sortedSensors(latestUpdate?.sensors ?? []).count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === fanTable {
            let fans = latestUpdate?.fans ?? []
            guard fans.indices.contains(row) else { return nil }
            let fan = fans[row]
            switch tableColumn.identifier.rawValue {
            case "fanName":
                return cell(fan.name, secondary: "风扇 \(fan.index + 1)")
            case "fanRotation":
                return cell(
                    String(format: "%.0f RPM / %.0f", fan.currentRPM, fan.targetRPM),
                    monospaced: true
                )
            case "fanRange":
                return cell(
                    String(format: "%.0f–%.0f RPM", fan.minimumRPM, fan.maximumRPM),
                    monospaced: true
                )
            default:
                return nil
            }
        }

        let sensors = sortedSensors(latestUpdate?.sensors ?? [])
        guard sensors.indices.contains(row) else { return nil }
        let sensor = sensors[row]
        switch tableColumn.identifier.rawValue {
        case "sensorName":
            return cell(sensor.name, secondary: sensor.id)
        case "sensorKind":
            return cell(kindTitle(sensor.kind))
        case "sensorTemperature":
            return cell(AppSettings.shared.formattedTemperature(sensor.temperatureCelsius), monospaced: true)
        default:
            return nil
        }
    }

    private func kindTitle(_ kind: SensorKind) -> String {
        switch kind {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .other: return "其他"
        }
    }

    private func cell(
        _ primary: String,
        secondary: String? = nil,
        monospaced: Bool = false
    ) -> NSTableCellView {
        let view = NSTableCellView()
        let label = NSTextField(labelWithString: primary)
        label.font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : AppTheme.font(ofSize: 12, weight: .medium)
        label.textColor = AppTheme.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        if let secondary {
            let detail = NSTextField(labelWithString: secondary)
            detail.font = monospaced
                ? NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
                : AppTheme.font(ofSize: 9.5)
            detail.textColor = AppTheme.secondaryText
            detail.lineBreakMode = .byTruncatingMiddle
            detail.translatesAutoresizingMaskIntoConstraints = false
            let stack = NSStackView(views: [label, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        } else {
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        return view
    }
}

private final class SensorCardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        AppTheme.panel.setFill()
        path.fill()
        AppTheme.subtleBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
