import AppKit
import UniformTypeIdentifiers

/// 偏好设置窗口：左侧分栏（滚动 / 例外 / 通用），右侧内容区。
/// 与工具包其他模块保持一致的设置界面。
final class PreferencesWindowController: NSWindowController {
    enum Section: Int, CaseIterable {
        case scrolling = 0
        case exceptions = 1
        case general = 2

        var title: String {
            switch self {
            case .scrolling: return "滚动"
            case .exceptions: return "应用例外"
            case .general: return "通用"
            }
        }

        var symbol: String {
            switch self {
            case .scrolling: return "computermouse"
            case .exceptions: return "square.grid.2x2"
            case .general: return "gearshape"
            }
        }
    }

    private let settings = AppSettings.shared
    private var sectionViews: [NSView] = []
    private var sectionButtons: [HoverButton] = []
    private var sectionLabels: [NSTextField] = []

    // 滚动页控件
    private let reverseCheckbox = NSButton(checkboxWithTitle: "反向滚轮（仅鼠标，触控板不受影响）", target: nil, action: nil)
    private let reverseVerticalCheckbox = NSButton(checkboxWithTitle: "垂直方向", target: nil, action: nil)
    private let reverseHorizontalCheckbox = NSButton(checkboxWithTitle: "水平方向", target: nil, action: nil)
    private let smoothCheckbox = NSButton(checkboxWithTitle: "平滑滚动", target: nil, action: nil)
    private let smoothVerticalCheckbox = NSButton(checkboxWithTitle: "垂直方向", target: nil, action: nil)
    private let smoothHorizontalCheckbox = NSButton(checkboxWithTitle: "水平方向", target: nil, action: nil)
    private let simTrackpadCheckbox = NSButton(checkboxWithTitle: "模拟触控板事件语义（实验性）", target: nil, action: nil)
    private let stepSlider = NSSlider(value: 33.6, minValue: 5, maxValue: 200, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 2.7, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let durationSlider = NSSlider(value: 4.35, minValue: 0, maxValue: 5, target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    // 例外页控件
    private let exceptionListTableView = NSTableView()
    private let allowlistCheckbox = NSButton(
        checkboxWithTitle: "白名单模式（仅列表中的应用启用 ScrollLab）",
        target: nil,
        action: nil
    )
    private var exceptionScrollView: NSScrollView!

    // 通用页控件
    private let launchCheckbox = NSButton(checkboxWithTitle: "登录后自动启动 ScrollLab", target: nil, action: nil)
    private let hideIconCheckbox = NSButton(checkboxWithTitle: "隐藏菜单栏图标", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")

    private var currentSection: Section = .scrolling

    convenience init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrollLab 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildInterface()
        refreshValues()
    }

    func show() {
        refreshValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面构建

    private func buildInterface() {
        guard let window else { return }
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = AppTheme.graphite.cgColor
        window.contentView = background

        let sidebarWidth: CGFloat = 168

        // 侧栏背景
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar)
        let sidebarLayer = sidebar.wantsLayer
        _ = sidebarLayer
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor

        // 侧栏标题
        let title = NSTextField(labelWithString: "ScrollLab")
        title.font = AppTheme.font(ofSize: 16, weight: .semibold)
        title.textColor = AppTheme.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(title)

        // 分区按钮
        for section in Section.allCases {
            let button = HoverButton(frame: .zero)
            button.identifier = NSUserInterfaceItemIdentifier("Section\(section.rawValue)")
            button.imagePosition = .imageLeading
            button.image = AppTheme.symbol(section.symbol, size: 14)
            button.title = section.title
            button.font = AppTheme.font(ofSize: 13, weight: .medium)
            button.alignment = .left
            button.contentTintColor = AppTheme.secondaryText
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(selectSection(_:))
            sidebar.addSubview(button)
            sectionButtons.append(button)

            let view = buildSectionView(section)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            background.addSubview(view)
            sectionViews.append(view)
        }

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
        ])

        for (index, button) in sectionButtons.enumerated() {
            let topAnchor: NSLayoutConstraint
            if index == 0 {
                topAnchor = button.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20)
            } else {
                topAnchor = button.topAnchor.constraint(
                    equalTo: sectionButtons[index - 1].bottomAnchor, constant: 6
                )
            }
            NSLayoutConstraint.activate([
                topAnchor,
                button.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
                button.heightAnchor.constraint(equalToConstant: 34),
            ])
        }

        for view in sectionViews {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
                view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20),
                view.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
                view.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
            ])
        }

        selectSectionValue(.scrolling)
    }

    private func buildSectionView(_ section: Section) -> NSView {
        let container = NSView()
        switch section {
        case .scrolling:
            buildScrollingSection(in: container)
        case .exceptions:
            buildExceptionsSection(in: container)
        case .general:
            buildGeneralSection(in: container)
        }
        return container
    }

    // MARK: 滚动页

    private func buildScrollingSection(in container: NSView) {
        styleCheckbox(reverseCheckbox)
        styleCheckbox(reverseVerticalCheckbox)
        styleCheckbox(reverseHorizontalCheckbox)
        styleCheckbox(smoothCheckbox)
        styleCheckbox(smoothVerticalCheckbox)
        styleCheckbox(smoothHorizontalCheckbox)
        styleCheckbox(simTrackpadCheckbox)

        reverseCheckbox.target = self
        reverseCheckbox.action = #selector(reverseChanged)
        reverseVerticalCheckbox.target = self
        reverseVerticalCheckbox.action = #selector(reverseVerticalChanged)
        reverseHorizontalCheckbox.target = self
        reverseHorizontalCheckbox.action = #selector(reverseHorizontalChanged)
        smoothCheckbox.target = self
        smoothCheckbox.action = #selector(smoothChanged)
        smoothVerticalCheckbox.target = self
        smoothVerticalCheckbox.action = #selector(smoothVerticalChanged)
        smoothHorizontalCheckbox.target = self
        smoothHorizontalCheckbox.action = #selector(smoothHorizontalChanged)
        simTrackpadCheckbox.target = self
        simTrackpadCheckbox.action = #selector(simTrackpadChanged)

        let reverseGroup = groupView(
            title: "反向滚轮",
            hint: "滚轮向下页面向上——方向整体翻转，仅对鼠标滚轮生效",
            content: [
                reverseCheckbox,
                indentView(reverseVerticalCheckbox),
                indentView(reverseHorizontalCheckbox),
            ]
        )
        let smoothGroup = groupView(
            title: "平滑滚动",
            hint: "把滚轮的离散步距插值为连续滚动，动画在显示器刷新率上渲染",
            content: [
                smoothCheckbox,
                indentView(smoothVerticalCheckbox),
                indentView(smoothHorizontalCheckbox),
                indentView(simTrackpadCheckbox),
            ]
        )

        let sliders = slidersView()
        let stack = NSStackView(views: [reverseGroup, smoothGroup, sliders])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
    }

    private func slidersView() -> NSView {
        func sliderRow(_ slider: NSSlider, _ label: NSTextField, title: String) -> NSView {
            slider.target = self
            slider.isContinuous = true
            let titleField = NSTextField(labelWithString: title)
            titleField.font = AppTheme.font(ofSize: 13, weight: .medium)
            titleField.textColor = AppTheme.primaryText
            label.font = AppTheme.font(ofSize: 12)
            label.textColor = AppTheme.secondaryText
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            slider.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(titleField)
            row.addSubview(slider)
            row.addSubview(label)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 26),
                titleField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                titleField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                titleField.widthAnchor.constraint(equalToConstant: 64),
                slider.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 12),
                slider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                slider.widthAnchor.constraint(equalToConstant: 260),
                label.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            return row
        }

        stepSlider.target = self
        speedSlider.target = self
        durationSlider.target = self
        stepSlider.action = #selector(stepSliderChanged)
        speedSlider.action = #selector(speedSliderChanged)
        durationSlider.action = #selector(durationSliderChanged)

        let stepRow = sliderRow(stepSlider, stepLabel, title: "步长")
        let speedRow = sliderRow(speedSlider, speedLabel, title: "速度")
        let durationRow = sliderRow(durationSlider, durationLabel, title: "时长")
        let hint = NSTextField(labelWithString: "步长：单格滚轮的基础距离　速度：缓冲倍率　时长：动画衰减快慢")
        hint.font = AppTheme.font(ofSize: 11)
        hint.textColor = AppTheme.secondaryText

        let stack = NSStackView(views: [stepRow, speedRow, durationRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    // MARK: 例外页

    private func buildExceptionsSection(in container: NSView) {
        styleCheckbox(allowlistCheckbox)
        allowlistCheckbox.target = self
        allowlistCheckbox.action = #selector(allowlistChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.title = "应用"
        exceptionListTableView.addTableColumn(column)
        exceptionListTableView.headerView = nil
        exceptionListTableView.rowHeight = 40
        exceptionListTableView.dataSource = self
        exceptionListTableView.delegate = self
        exceptionListTableView.style = .plain
        exceptionListTableView.usesAlternatingRowBackgroundColors = false
        exceptionListTableView.backgroundColor = NSColor.clear
        exceptionListTableView.selectionHighlightStyle = .regular
        exceptionListTableView.target = self
        exceptionListTableView.doubleAction = #selector(editSelectedException)

        let scroll = NSScrollView()
        scroll.documentView = exceptionListTableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        _ = scroll

        let addButton = NSButton(title: "添加应用…", target: self, action: #selector(addException))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeSelectedException))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .regular

        let hint = NSTextField(labelWithString: "例外应用可以单独覆盖反向、平滑和三个滑杆参数。双击条目编辑覆盖项。")
        hint.font = AppTheme.font(ofSize: 11)
        hint.textColor = AppTheme.secondaryText

        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [allowlistCheckbox, scroll, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 330),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: 通用页

    private func buildGeneralSection(in container: NSView) {
        styleCheckbox(launchCheckbox)
        styleCheckbox(hideIconCheckbox)
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchAtLoginChanged)
        hideIconCheckbox.target = self
        hideIconCheckbox.action = #selector(hideIconChanged)

        permissionLabel.font = AppTheme.font(ofSize: 12)
        permissionLabel.textColor = AppTheme.secondaryText
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionLabel.maximumNumberOfLines = 0
        permissionLabel.preferredMaxLayoutWidth = 460

        let stack = NSStackView(views: [launchCheckbox, hideIconCheckbox, permissionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
    }

    // MARK: - 小组件

    private func groupView(title: String, hint: String, content: [NSView]) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = AppTheme.font(ofSize: 14, weight: .semibold)
        titleField.textColor = AppTheme.primaryText
        let hintField = NSTextField(labelWithString: hint)
        hintField.font = AppTheme.font(ofSize: 11)
        hintField.textColor = AppTheme.secondaryText

        let stack = NSStackView(views: [titleField, hintField] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let group = NSView()
        group.translatesAutoresizingMaskIntoConstraints = false
        group.wantsLayer = true
        group.layer?.backgroundColor = AppTheme.panel.cgColor
        group.layer?.cornerRadius = 12
        group.layer?.borderWidth = 1
        group.layer?.borderColor = AppTheme.subtleBorder.cgColor
        group.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: group.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: group.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -14),
        ])
        return group
    }

    private func indentView(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func styleCheckbox(_ checkbox: NSButton) {
        checkbox.font = AppTheme.font(ofSize: 13)
        checkbox.contentTintColor = AppTheme.primaryText
    }

    // MARK: - 状态刷新

    private func selectSectionValue(_ section: Section) {
        currentSection = section
        for (index, view) in sectionViews.enumerated() {
            view.isHidden = Section(rawValue: index) != section
        }
        for (index, button) in sectionButtons.enumerated() {
            let selected = Section(rawValue: index) == section
            button.contentTintColor = selected ? AppTheme.accent : AppTheme.secondaryText
            button.normalBackground = selected ? NSColor.white.withAlphaComponent(0.08) : .clear
        }
    }

    /// 供离屏 UI 回归切换分区（等效点击侧栏按钮）。
    func selectSectionForTest(_ section: Section) {
        selectSectionValue(section)
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let index = sectionButtons.firstIndex(where: { $0 === sender }) else { return }
        guard let section = Section(rawValue: index) else { return }
        selectSectionValue(section)
    }

    func refreshValues() {
        let granted = AXIsProcessTrusted()
        reverseCheckbox.state = granted && settings.reverse ? .on : .off
        reverseVerticalCheckbox.state = granted && settings.reverseVertical ? .on : .off
        reverseHorizontalCheckbox.state = granted && settings.reverseHorizontal ? .on : .off
        reverseCheckbox.isEnabled = granted
        reverseVerticalCheckbox.isEnabled = granted && settings.reverse
        reverseHorizontalCheckbox.isEnabled = granted && settings.reverse
        smoothCheckbox.state = granted && settings.smooth ? .on : .off
        smoothVerticalCheckbox.state = granted && settings.smoothVertical ? .on : .off
        smoothHorizontalCheckbox.state = granted && settings.smoothHorizontal ? .on : .off
        smoothCheckbox.isEnabled = granted
        smoothVerticalCheckbox.isEnabled = granted && settings.smooth
        smoothHorizontalCheckbox.isEnabled = granted && settings.smooth
        simTrackpadCheckbox.state = granted && settings.smoothSimTrackpad ? .on : .off
        simTrackpadCheckbox.isEnabled = granted && settings.smooth
        stepSlider.doubleValue = settings.step
        speedSlider.doubleValue = settings.speed
        durationSlider.doubleValue = settings.duration
        updateSliderLabels()
        allowlistCheckbox.state = settings.allowlist ? .on : .off
        launchCheckbox.state = settings.launchAtLogin ? .on : .off
        hideIconCheckbox.state = settings.hideStatusItem ? .on : .off
        updatePermissionHint()
        exceptionListTableView.reloadData()
    }

    private func updateSliderLabels() {
        stepLabel.stringValue = String(format: "%.1f", settings.step)
        speedLabel.stringValue = String(format: "%.2f×", settings.speed)
        durationLabel.stringValue = String(format: "%.2f", settings.duration)
    }

    private func updatePermissionHint() {
        let granted = AXIsProcessTrusted()
        permissionLabel.stringValue = granted
            ? "辅助功能权限已授予，事件拦截正常工作。"
            : "尚未授予辅助功能权限：请打开 系统设置 > 隐私与安全性 > 辅助功能，允许 ScrollLab 后自动生效。"
        permissionLabel.textColor = granted ? AppTheme.secondaryText : AppTheme.accent
    }

    // MARK: - 动作

    @objc private func reverseChanged() { settings.setReverse(reverseCheckbox.state == .on) }
    @objc private func reverseVerticalChanged() { settings.setReverseVertical(reverseVerticalCheckbox.state == .on) }
    @objc private func reverseHorizontalChanged() { settings.setReverseHorizontal(reverseHorizontalCheckbox.state == .on) }
    @objc private func smoothChanged() { settings.setSmooth(smoothCheckbox.state == .on) }
    @objc private func smoothVerticalChanged() { settings.setSmoothVertical(smoothVerticalCheckbox.state == .on) }
    @objc private func smoothHorizontalChanged() { settings.setSmoothHorizontal(smoothHorizontalCheckbox.state == .on) }
    @objc private func simTrackpadChanged() { settings.setSmoothSimTrackpad(simTrackpadCheckbox.state == .on) }
    @objc private func allowlistChanged() { settings.setAllowlist(allowlistCheckbox.state == .on) }
    @objc private func launchAtLoginChanged() { settings.setLaunchAtLogin(launchCheckbox.state == .on) }
    @objc private func hideIconChanged() {
        settings.setHideStatusItem(hideIconCheckbox.state == .on)
        updatePermissionHint()
    }

    @objc private func stepSliderChanged() { settings.setStep(stepSlider.doubleValue); updateSliderLabels() }
    @objc private func speedSliderChanged() { settings.setSpeed(speedSlider.doubleValue); updateSliderLabels() }
    @objc private func durationSliderChanged() { settings.setDuration(durationSlider.doubleValue); updateSliderLabels() }

    @objc private func addException() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registerException(at: url)
    }

    func registerException(at url: URL) {
        let name = FileManager.default.displayName(atPath: url.path)
        let executable = url.appendingPathComponent("Contents/MacOS/\((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/MacOS").path).first ?? "") ?? name)")
        var exception = AppException(
            name: name,
            bundlePath: url.path,
            executablePath: executable.path
        )
        if let bundle = Bundle(url: url) {
            exception.executablePath = bundle.executableURL?.path ?? executable.path
        }
        var list = settings.exceptions
        guard !list.contains(where: { $0.bundlePath == exception.bundlePath }) else { return }
        list.append(exception)
        settings.setExceptions(list)
        exceptionListTableView.reloadData()
    }

    @objc private func removeSelectedException() {
        let row = exceptionListTableView.selectedRow
        guard row >= 0, row < settings.exceptions.count else { return }
        var list = settings.exceptions
        list.remove(at: row)
        settings.setExceptions(list)
        exceptionListTableView.reloadData()
    }

    @objc private func editSelectedException() {
        let row = exceptionListTableView.selectedRow
        guard row >= 0, row < settings.exceptions.count else { return }
        ExceptionEditorController.show(exceptionIndex: row, window: window)
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        settings.exceptions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let exception = settings.exceptions[row]
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.spacing = 10
        cell.alignment = .centerY

        let iconView = NSImageView()
        iconView.setImage(forAppPath: exception.bundlePath)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let nameField = NSTextField(labelWithString: exception.name)
        nameField.font = AppTheme.font(ofSize: 13, weight: .medium)
        nameField.textColor = AppTheme.primaryText
        let modeField = NSTextField(labelWithString: exception.inherit ? "继承全局" : "自定义")
        modeField.font = AppTheme.font(ofSize: 11)
        modeField.textColor = exception.inherit ? AppTheme.secondaryText : AppTheme.accent

        cell.addArrangedSubview(iconView)
        cell.addArrangedSubview(nameField)
        cell.addArrangedSubview(modeField)
        cell.addArrangedSubview(NSView())

        let wrapper = NSView()
        wrapper.addSubview(cell)
        cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
            cell.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
            cell.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            cell.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
        ])
        return wrapper
    }
}

extension NSImageView {
    func setImage(forAppPath path: String) {
        image = NSWorkspace.shared.icon(forFile: path)
    }
}
