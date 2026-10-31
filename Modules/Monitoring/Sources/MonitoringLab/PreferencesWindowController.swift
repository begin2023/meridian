import AppKit

// 偏好设置:模块开关、Widget 样式、采样间隔与开机自启,改动即时保存并生效。
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let onChange: () -> Void
    private let settings = AppSettings.shared

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MonitoringLab 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onChange()
    }

    // MARK: - 内容

    private func buildContent() {
        guard let window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(generalCard())
        stack.addArrangedSubview(moduleCard(id: "cpu", symbol: "cpu", name: "CPU"))
        stack.addArrangedSubview(moduleCard(id: "ram", symbol: "memorychip", name: "内存"))
        stack.addArrangedSubview(moduleCard(id: "net", symbol: "arrow.up.arrow.down", name: "网络"))
        stack.addArrangedSubview(moduleCard(id: "disk", symbol: "internaldrive", name: "磁盘"))

        let hint = NSTextField(labelWithString: "Widget 样式:文本显示数值;条形显示比例;图表显示最近走势。")
        hint.font = AppTheme.font(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let container = NSView()
        container.addSubview(stack)
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
        ])

        window.contentView = container
        // 先给出宽度和临时高度完成一次布局,再按实际内容高度定窗口尺寸,
        // 否则底部提示行会被裁掉。
        container.frame = NSRect(x: 0, y: 0, width: 520, height: 800)
        container.layoutSubtreeIfNeeded()
        let height = ceil(container.fittingSize.height)
        window.setContentSize(NSSize(width: 520, height: height))
        container.frame = NSRect(x: 0, y: 0, width: 520, height: height)
    }

    // MARK: 卡片

    private func card(title: String, symbol: String? = nil) -> (NSView, NSStackView) {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        var titleLeading: NSLayoutConstraint
        if let symbol {
            let iconView = NSImageView(image: AppTheme.symbol(symbol, size: 14, weight: .medium) ?? NSImage())
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            card.addSubview(iconView)
            card.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                iconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ])
            titleLeading = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6)
        } else {
            card.addSubview(titleLabel)
            titleLeading = titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16)
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleLeading,

            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14),
        ])
        return (card, stack)
    }

    private func row(_ title: String, accessory: NSView, identifier: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = AppTheme.font(ofSize: 12)
        label.textColor = .labelColor

        if let identifier {
            accessory.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(label)
        rowView.addSubview(accessory)
        NSLayoutConstraint.activate([
            rowView.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            accessory.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        ])
        return rowView
    }

    private func generalCard() -> NSView {
        let (card, stack) = card(title: "通用")

        let launchSwitch = NSSwitch()
        launchSwitch.state = settings.launchAtLoginEnabled ? .on : .off
        launchSwitch.target = self
        launchSwitch.action = #selector(launchAtLoginChanged)
        launchSwitch.identifier = NSUserInterfaceItemIdentifier("launchAtLoginSwitch")
        let launchRow = row("开机自启", accessory: launchSwitch, identifier: "launchAtLoginRow")

        let intervalPopup = NSPopUpButton()
        for seconds in [1, 2, 3, 5, 10] {
            intervalPopup.addItem(withTitle: "\(seconds) 秒")
            intervalPopup.lastItem?.representedObject = seconds
        }
        intervalPopup.selectItem(at: [1, 2, 3, 5, 10].firstIndex(of: settings.updateInterval) ?? 0)
        intervalPopup.target = self
        intervalPopup.action = #selector(updateIntervalChanged)
        intervalPopup.identifier = NSUserInterfaceItemIdentifier("updateIntervalPopup")
        let intervalRow = row("采样间隔", accessory: intervalPopup, identifier: "updateIntervalRow")

        let geoSwitch = NSSwitch()
        geoSwitch.state = settings.networkGeoLookupEnabled ? .on : .off
        geoSwitch.target = self
        geoSwitch.action = #selector(geoLookupChanged)
        geoSwitch.identifier = NSUserInterfaceItemIdentifier("geoLookupSwitch")
        let geoRow = row("在线查询 IP 归属地", accessory: geoSwitch, identifier: "geoLookupRow")

        stack.addArrangedSubview(launchRow)
        stack.addArrangedSubview(intervalRow)
        stack.addArrangedSubview(geoRow)
        for rowView in [launchRow, intervalRow, geoRow] {
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    private func moduleCard(id: String, symbol: String, name: String) -> NSView {
        let (card, stack) = card(title: name, symbol: symbol)
        card.identifier = NSUserInterfaceItemIdentifier("\(id)ModuleCard")

        let enableSwitch = NSSwitch()
        enableSwitch.state = settings.moduleEnabled(id) ? .on : .off
        enableSwitch.target = self
        enableSwitch.action = #selector(moduleEnabledChanged)
        enableSwitch.identifier = NSUserInterfaceItemIdentifier("\(id)EnableSwitch")

        let stylePopup = NSPopUpButton()
        WidgetStyle.all.forEach { style in
            stylePopup.addItem(withTitle: style.title)
            stylePopup.lastItem?.representedObject = style.rawValue
        }
        stylePopup.selectItem(at: stylePopup.itemTitles.firstIndex(of: settings.widgetStyle(for: id).title) ?? 0)
        stylePopup.target = self
        stylePopup.action = #selector(widgetStyleChanged)
        stylePopup.identifier = NSUserInterfaceItemIdentifier("\(id)StylePopup")

        let enableRow = row("在菜单栏显示", accessory: enableSwitch, identifier: "\(id)EnableRow")
        let styleRow = row("Widget 样式", accessory: stylePopup, identifier: "\(id)StyleRow")
        stack.addArrangedSubview(enableRow)
        stack.addArrangedSubview(styleRow)
        for rowView in [enableRow, styleRow] {
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    // MARK: 动作

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        if !settings.setLaunchAtLogin(sender.state == .on) {
            sender.state = settings.launchAtLoginEnabled ? .on : .off
        }
    }

    @objc private func updateIntervalChanged(_ sender: NSPopUpButton) {
        guard let seconds = sender.selectedItem?.representedObject as? Int else { return }
        settings.updateInterval = seconds
        onChange()
    }

    @objc private func geoLookupChanged(_ sender: NSSwitch) {
        settings.networkGeoLookupEnabled = sender.state == .on
        onChange()
    }

    @objc private func moduleEnabledChanged(_ sender: NSSwitch) {
        guard let identifier = sender.identifier?.rawValue,
              let suffixRange = identifier.range(of: "EnableSwitch") else { return }
        let id = String(identifier[..<suffixRange.lowerBound])
        settings.setModuleEnabled(id, sender.state == .on)
        onChange()
    }

    @objc private func widgetStyleChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let suffixRange = identifier.range(of: "StylePopup"),
              let rawValue = sender.selectedItem?.representedObject as? Int else { return }
        let id = String(identifier[..<suffixRange.lowerBound])
        settings.setWidgetStyle(WidgetStyle(rawValue: rawValue) ?? .text, for: id)
        onChange()
    }
}

// 卡片背景:语义色跟随系统外观。
final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
