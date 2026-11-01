import AppKit
import DisplayCore
import ServiceManagement

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    var windowPresence: WindowPresenceController?

    private var contentStack: NSStackView!
    private var smoothingSlider: NSSlider?
    private var smoothingValueLabel: NSTextField?
    private var switchoverSlider: NSSlider?
    private var switchoverValueLabel: NSTextField?
    private var writeCountLabel: NSTextField?
    private var writeDelayLabel: NSTextField?
    private var loginToggle: NSButton?
    private var brightnessKeysToggle: NSButton?
    private var virtualScreensToggle: NSButton?
    private var brightnessKeyPermissionButton: NSButton?
    private var helperStatusLabel: NSTextField?

    private let settings = AppSettings.shared
    private let overrideService = OverrideService()

    convenience init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildInterface()
        refreshValues()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        windowPresence?.register(window)
        refreshValues()
    }

    func windowWillClose(_ notification: Notification) {
        windowPresence?.unregister(window!)
    }

    // MARK: - Interface

    private func buildInterface() {
        let background = PreferencesBackgroundView(frame: .zero)
        background.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        window?.contentView = background

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeSectionLabel("亮度"))
        let smoothingToggleControl = makeToggle(action: #selector(smoothingToggled(_:)))
        smoothingToggle = smoothingToggleControl
        let loginToggleControl = makeToggle(action: #selector(loginToggled(_:)))
        loginToggle = loginToggleControl
        let brightnessKeysToggleControl = makeToggle(action: #selector(brightnessKeysToggled(_:)))
        brightnessKeysToggle = brightnessKeysToggleControl
        let virtualScreensToggleControl = makeToggle(action: #selector(virtualScreensToggled(_:)))
        virtualScreensToggle = virtualScreensToggleControl
        stack.addArrangedSubview(makeCard(rows: [
            makeRow(
                title: "平滑过渡",
                subtitle: "滑块与快捷键调节时逐级过渡，而不是直接跳变",
                accessory: smoothingToggleControl
            ),
            makeRow(
                title: "F1 / F2 调节亮度",
                subtitle: "接管媒体亮度键控制外接显示器；需要输入监控权限",
                accessory: makeBrightnessKeysRow(base: brightnessKeysToggleControl)
            ),
            makeRow(
                title: "过渡时长",
                subtitle: "平滑过渡的总时长（毫秒）",
                accessory: makeSmoothingDurationControl()
            ),
            makeRow(
                title: "组合亮度切换点",
                subtitle: "低于该亮度时叠加 gamma 调暗（%）",
                accessory: makeSwitchoverControl()
            ),
        ]))
        stack.addArrangedSubview(makeSectionLabel("DDC / CI"))
        stack.addArrangedSubview(makeCard(rows: [
            makeRow(
                title: "命令重复次数",
                subtitle: "每次亮度写入发送的重复命令数（1–6）",
                accessory: makeStepperRow(
                    range: 1...6,
                    read: { [weak self] in self?.settings.ddcWriteCount ?? 2 },
                    write: { [weak self] in self?.settings.ddcWriteCount = $0 },
                    label: { self.writeCountLabel = $0 }
                )
            ),
            makeRow(
                title: "命令间隔",
                subtitle: "重复命令之间的间隔（毫秒，2–100）",
                accessory: makeStepperRow(
                    range: 2...100,
                    read: { [weak self] in self?.settings.ddcWriteDelayMilliseconds ?? 10 },
                    write: { [weak self] in self?.settings.ddcWriteDelayMilliseconds = $0 },
                    label: { self.writeDelayLabel = $0 }
                )
            ),
        ]))
        stack.addArrangedSubview(makeSectionLabel("通用"))
        stack.addArrangedSubview(makeCard(rows: [
            makeRow(
                title: "登录时启动",
                subtitle: "开机后自动运行 DisplayLab",
                accessory: loginToggleControl
            ),
            makeRow(
                title: "显示虚拟屏幕菜单",
                subtitle: "在菜单里展示虚拟屏幕的创建与断开入口",
                accessory: virtualScreensToggleControl
            ),
        ]))
        stack.addArrangedSubview(makeSectionLabel("特权助手"))
        stack.addArrangedSubview(makeCard(rows: [
            makeRow(
                title: "Helper 状态",
                subtitle: "用于安装 HiDPI 显示器覆盖（root 写入 override plist）",
                accessory: makeHelperStatusControl()
            ),
        ]))

        let hint = NSTextField(wrappingLabelWithString: "亮度通过 DDC/CI（外接）或 DisplayServices（Apple 内置屏）控制；分辨率列表包含 WindowServer 隐藏的 CGS 模式；虚拟屏幕由 CoreGraphics 私有类创建。")
        hint.font = AppTheme.font(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 620
        stack.addArrangedSubview(hint)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -24),
        ])

        contentStack = stack
    }

    private func makeHeader() -> NSView {
        let header = NSTextField(labelWithString: "DisplayLab 偏好设置")
        header.font = AppTheme.font(ofSize: 20, weight: .semibold)
        header.textColor = .labelColor
        return header
    }

    private func makeSectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.font(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeCard(rows: [NSView]) -> NSView {
        let card = PreferenceCardView()
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            card.widthAnchor.constraint(equalToConstant: 640),
        ])
        return card
    }

    private func makeRow(title: String, subtitle: String, accessory: NSView) -> NSView {
        let row = NSStackView(views: [])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = AppTheme.font(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = 380
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(subtitleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(accessory)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        return row
    }

    private func makeToggle(action: Selector) -> NSButton {
        let toggle = NSButton(checkboxWithTitle: "", target: self, action: action)
        toggle.controlSize = .regular
        return toggle
    }

    private func makeSmoothingDurationControl() -> NSView {
        let slider = NSSlider(value: settings.smoothingDurationMilliseconds, minValue: 80, maxValue: 2000, target: self, action: #selector(smoothingDurationChanged(_:)))
        slider.controlSize = .small
        slider.frame = NSRect(x: 0, y: 0, width: 160, height: 20)
        let label = NSTextField(labelWithString: "\(Int(settings.smoothingDurationMilliseconds)) ms")
        label.font = AppTheme.font(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true

        smoothingSlider = slider
        smoothingValueLabel = label

        let stack = NSStackView(views: [slider, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func makeSwitchoverControl() -> NSView {
        let slider = NSSlider(value: settings.combinedDimmingPoint * 100, minValue: 0, maxValue: 60, target: self, action: #selector(switchoverChanged(_:)))
        slider.controlSize = .small
        slider.frame = NSRect(x: 0, y: 0, width: 160, height: 20)
        let label = NSTextField(labelWithString: "\(Int(settings.combinedDimmingPoint * 100))%")
        label.font = AppTheme.font(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true

        switchoverSlider = slider
        switchoverValueLabel = label

        let stack = NSStackView(views: [slider, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func makeStepperRow(
        range: ClosedRange<Int>,
        read: @escaping () -> Int,
        write: @escaping (Int) -> Void,
        label: @escaping (NSTextField?) -> Void
    ) -> NSView {
        let valueLabel = NSTextField(labelWithString: "\(read())")
        valueLabel.font = AppTheme.font(ofSize: 11)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.integerValue = read()
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        stepper.identifier = NSUserInterfaceItemIdentifier("\(range.lowerBound)-\(range.upperBound)")
        stepper.associatedWrite = write
        stepper.associatedRead = read
        stepper.valueLabelReference = valueLabel

        label(valueLabel)
        let stack = NSStackView(views: [valueLabel, stepper])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func makeBrightnessKeysRow(base: NSButton) -> NSView {
        let button = NSButton(title: "授权…", target: self, action: #selector(openInputMonitoringSettings))
        button.controlSize = .small
        button.bezelStyle = .rounded
        brightnessKeyPermissionButton = button

        let stack = NSStackView(views: [base, button])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func makeHelperStatusControl() -> NSView {
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = AppTheme.font(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        helperStatusLabel = statusLabel

        let button = NSButton(title: "安装 / 重新授权", target: self, action: #selector(installHelperClicked))
        button.controlSize = .small
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [statusLabel, button])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    // MARK: - State

    private func refreshValues() {
        guard contentStack != nil else { return }
        smoothingToggle?.state = settings.smoothingEnabled ? .on : .off
        smoothingSlider?.doubleValue = settings.smoothingDurationMilliseconds
        smoothingValueLabel?.stringValue = "\(Int(settings.smoothingDurationMilliseconds)) ms"
        switchoverSlider?.doubleValue = settings.combinedDimmingPoint * 100
        switchoverValueLabel?.stringValue = "\(Int(settings.combinedDimmingPoint * 100))%"
        loginToggle?.state = settings.launchAtLogin ? .on : .off
        brightnessKeysToggle?.state = settings.takeOverBrightnessKeys ? .on : .off
        virtualScreensToggle?.state = settings.showVirtualScreens ? .on : .off
        if let button = brightnessKeyPermissionButton {
            let appDelegate = NSApp.delegate as? AppDelegate
            let granted = appDelegate?.brightnessKeyController.permissionAvailable ?? false
            button.isHidden = granted
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            let granted = appDelegate.brightnessKeyController.permissionAvailable
            brightnessKeysToggle?.toolTip = granted ? "已获得输入监控权限" : "尚未获得输入监控权限"
        }
        writeCountLabel?.stringValue = "\(settings.ddcWriteCount)"
        writeDelayLabel?.stringValue = "\(settings.ddcWriteDelayMilliseconds)"

        helperStatusLabel?.stringValue = overrideService.isInstalled ? "已安装" : "未安装"
    }

    private var smoothingToggle: NSButton?

    // MARK: - Actions

    @objc private func smoothingToggled(_ sender: NSButton) {
        settings.smoothingEnabled = sender.state == .on
    }

    @objc private func smoothingDurationChanged(_ sender: NSSlider) {
        settings.smoothingDurationMilliseconds = sender.doubleValue
        smoothingValueLabel?.stringValue = "\(Int(sender.doubleValue)) ms"
    }

    @objc private func switchoverChanged(_ sender: NSSlider) {
        settings.combinedDimmingPoint = sender.doubleValue / 100
        switchoverValueLabel?.stringValue = "\(Int(sender.doubleValue))%"
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if let read = sender.associatedRead, let write = sender.associatedWrite {
            write(sender.integerValue)
            sender.valueLabelReference?.stringValue = "\(read())"
        }
    }

    @objc private func loginToggled(_ sender: NSButton) {
        settings.launchAtLogin = sender.state == .on
    }

    @objc private func brightnessKeysToggled(_ sender: NSButton) {
        settings.takeOverBrightnessKeys = sender.state == .on
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        if sender.state == .on {
            appDelegate.brightnessKeyController.start()
            if !appDelegate.brightnessKeyController.permissionAvailable {
                showBrightnessKeyGuide()
            }
        } else {
            appDelegate.brightnessKeyController.stop()
        }
        refreshValues()
    }

    /// First-run guidance when the brightness key takeover is enabled without
    /// the Input Monitoring permission.
    private func showBrightnessKeyGuide() {
        let alert = NSAlert()
        alert.messageText = "需要输入监控权限"
        alert.informativeText = "DisplayLab 需要监听 F1/F2 媒体键才能调节外接显示器亮度。\n\n1. 在接下来的系统设置窗口里找到“输入监控”\n2. 打开 DisplayLab 的开关\n3. 回到这里把 F1/F2 开关关一下再打开"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func virtualScreensToggled(_ sender: NSButton) {
        settings.showVirtualScreens = sender.state == .on
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func installHelperClicked() {
        do {
            try overrideService.install()
        } catch {
            let alert = NSAlert()
            alert.messageText = "安装特权助手失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshValues()
    }
}

// MARK: - Stepper payload helpers

private extension NSStepper {
    private static var associatedKeyRead: UInt8 = 0
    private static var associatedKeyWrite: UInt8 = 0
    private static var associatedKeyLabel: UInt8 = 0

    var associatedRead: (() -> Int)? {
        get { objc_getAssociatedObject(self, &Self.associatedKeyRead) as? (() -> Int) }
        set { objc_setAssociatedObject(self, &Self.associatedKeyRead, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var associatedWrite: ((Int) -> Void)? {
        get { objc_getAssociatedObject(self, &Self.associatedKeyWrite) as? ((Int) -> Void) }
        set { objc_setAssociatedObject(self, &Self.associatedKeyWrite, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var valueLabelReference: NSTextField? {
        get { objc_getAssociatedObject(self, &Self.associatedKeyLabel) as? NSTextField }
        set { objc_setAssociatedObject(self, &Self.associatedKeyLabel, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

// MARK: - Card drawing

class PreferencesBackgroundView: NSView {
    override var isFlipped: Bool { true }
}

class PreferenceCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
