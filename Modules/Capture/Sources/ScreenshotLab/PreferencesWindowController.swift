import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    enum HotKeyKind {
        case capture
        case gif
    }

    /// Re-registers both hotkeys from the current settings. Returns false when
    /// any of them is taken by another app.
    var onHotKeysChanged: (() -> Bool)?
    var onError: ((Error) -> Void)?
    var onOpenHistory: (() -> Void)?

    private let settings = AppSettings.shared
    private let captureRecorder = HotKeyRecorderButton()
    private let gifRecorder = HotKeyRecorderButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let screenshotScalePopup = NSPopUpButton()
    private let gifWidthPopup = NSPopUpButton()
    private let gifFPSPopup = NSPopUpButton()
    private let copyFileCheckbox = NSButton(
        checkboxWithTitle: "复制图片时同时写入 PNG 文件",
        target: nil,
        action: nil
    )
    private let launchCheckbox = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private var appDisplayName = ScreenshotLabIdentity.displayName
    private var allowsLaunchAtLogin = true

    convenience init(
        appDisplayName: String = ScreenshotLabIdentity.displayName,
        allowsLaunchAtLogin: Bool = true
    ) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        self.appDisplayName = appDisplayName
        self.allowsLaunchAtLogin = allowsLaunchAtLogin
        window.delegate = self
        buildInterface()
        refreshValues()
    }

    func show() {
        refreshValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
#if DEBUG
        if CommandLine.arguments.contains("--preferences") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.window?.contentView?.writeDebugPNG(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-preferences.png")
                )
            }
        }
#endif
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        let background = PreferencesBackgroundView()
        window.contentView = background

        captureRecorder.identifier = NSUserInterfaceItemIdentifier(
            "ScreenshotLabCaptureHotKey"
        )
        gifRecorder.identifier = NSUserInterfaceItemIdentifier(
            "ScreenshotLabGifHotKey"
        )
        captureRecorder.onChange = { [weak self] choice in
            self?.commitHotKey(choice, kind: .capture)
        }
        gifRecorder.onChange = { [weak self] choice in
            self?.commitHotKey(choice, kind: .gif)
        }

        copyFileCheckbox.target = self
        copyFileCheckbox.action = #selector(copyFileChanged)
        launchCheckbox.title = "登录后自动启动 \(appDisplayName)"

        configurePopup(screenshotScalePopup, titles: ["原始分辨率", "75%", "50%", "25%"])
        screenshotScalePopup.target = self
        screenshotScalePopup.action = #selector(screenshotScaleChanged)
        configurePopup(gifWidthPopup, titles: ["480 px", "640 px", "960 px", "1280 px"])
        gifWidthPopup.target = self
        gifWidthPopup.action = #selector(gifWidthChanged)
        configurePopup(gifFPSPopup, titles: ["5 fps", "10 fps", "15 fps", "20 fps"])
        gifFPSPopup.target = self
        gifFPSPopup.action = #selector(gifFPSChanged)

        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchAtLoginChanged)

        let header = makeHeader()
        let hotKeyCard = makeCard(rows: [
            makeRow(
                title: "截图",
                subtitle: "区域截图、标注、钉图与 OCR",
                accessory: captureRecorder
            ),
            makeRow(
                title: "录制 GIF",
                subtitle: "选择区域后开始录制",
                accessory: gifRecorder
            ),
        ])
        let hotKeyHint = makeHint("点击按钮后直接按下新的组合键，Esc 取消录制。")
        var outputRows: [NSView] = [
            makeRow(title: "截图分辨率", subtitle: "相对屏幕原始像素", accessory: screenshotScalePopup),
            makeRow(title: "GIF 输出宽度", subtitle: "高度按比例缩放", accessory: gifWidthPopup),
            makeRow(title: "GIF 帧率", subtitle: "录制与播放帧率", accessory: gifFPSPopup),
            makeRow(
                title: "快速保存目录",
                subtitle: "快速保存与 GIF 落盘的位置",
                accessory: makeFolderAccessory()
            ),
            makeToggleRow(
                copyFileCheckbox,
                subtitle: "剪贴板中同时包含图片和 PNG 文件"
            ),
        ]
        if allowsLaunchAtLogin {
            outputRows.append(makeToggleRow(
                launchCheckbox,
                subtitle: "随 macOS 登录自动运行"
            ))
        }
        let outputCard = makeCard(rows: outputRows)
        let ocrCard = makeCard(rows: [makeOCRRow()])
        let historyButton = NSButton(title: "管理截图历史", target: self, action: #selector(openHistory))
        historyButton.bezelStyle = .rounded
        historyButton.font = AppTheme.font(ofSize: 12)
        let historyCard = makeCard(rows: [makeRow(
            title: "截图历史",
            subtitle: "默认最近 10 张，可按时间筛选并调整保留数量（1–100 张）",
            accessory: historyButton
        ), makeHint("图片存于本地磁盘；缩略图和当前预览会增加少量内存占用。")])
        let footer = makeFooter()

        let sectionHotKeys = makeSectionLabel("快捷键")
        let sectionOutput = makeSectionLabel("截图与输出")
        let sectionOCR = makeSectionLabel("文字识别")
        let sectionHistory = makeSectionLabel("截图历史")

        let stack = NSStackView(views: [
            header,
            sectionHotKeys,
            hotKeyCard,
            hotKeyHint,
            sectionOutput,
            outputCard,
            sectionHistory,
            historyCard,
            sectionOCR,
            ocrCard,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(22, after: header)
        stack.setCustomSpacing(6, after: sectionHotKeys)
        stack.setCustomSpacing(6, after: sectionOutput)
        stack.setCustomSpacing(6, after: sectionOCR)
        stack.setCustomSpacing(6, after: hotKeyCard)
        stack.setCustomSpacing(20, after: ocrCard)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        for view in [hotKeyCard, outputCard, historyCard, ocrCard] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -20),
        ])

        background.layoutSubtreeIfNeeded()
        let contentHeight = stack.fittingSize.height + 50
        window.setContentSize(
            NSSize(width: 780, height: max(520, contentHeight))
        )
        window.center()
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 14
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: appDisplayName)
        title.font = AppTheme.font(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: "截图 · 标注 · 钉图 · 文字识别")
        subtitle.font = AppTheme.font(ofSize: 13, weight: .medium)
        subtitle.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.font(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeHint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.font(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeCard(rows: [NSView]) -> NSView {
        let card = PreferenceCardView()
        let content = NSStackView()
        content.orientation = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            content.addArrangedSubview(inset(row))
            if index < rows.count - 1 {
                content.addArrangedSubview(separator())
            }
        }

        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return card
    }

    private func inset(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
        ])
        return container
    }

    private func separator() -> NSView {
        let container = NSView()
        let line = PreferenceSeparatorView()
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func makeRow(
        title: String,
        subtitle: String?,
        accessory: NSView
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 13, weight: .semibold)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.addArrangedSubview(titleLabel)

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = AppTheme.font(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(subtitleLabel)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, spacer, accessory])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func makeToggleRow(_ checkbox: NSButton, subtitle: String) -> NSView {
        checkbox.font = AppTheme.font(ofSize: 13, weight: .medium)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = AppTheme.font(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [checkbox, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func makeFolderAccessory() -> NSView {
        folderLabel.font = AppTheme.font(ofSize: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        folderLabel.widthAnchor
            .constraint(lessThanOrEqualToConstant: 320)
            .isActive = true

        let chooseButton = NSButton(
            title: "选择…",
            target: self,
            action: #selector(chooseFolder)
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small

        let stack = NSStackView(views: [folderLabel, chooseButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func makeOCRRow() -> NSView {
        let icon = NSImageView()
        icon.image = AppTheme.symbol("text.viewfinder", size: 20, weight: .medium)
        icon.contentTintColor = AppTheme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        let title = NSTextField(labelWithString: "自动检测语言")
        title.font = AppTheme.font(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "使用 macOS Vision 自动识别简体中文、繁体中文、英文等语言，无需手动选择。"
        )
        subtitle.font = AppTheme.font(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels, spacer])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func makeFooter() -> NSView {
        let icon = NSImageView()
        icon.image = AppTheme.symbol(
            "checkmark.circle.fill",
            size: 12,
            weight: .medium
        )
        icon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(labelWithString: "所有设置都会即时保存")
        label.font = AppTheme.font(ofSize: 11)
        label.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func refreshValues() {
        captureRecorder.apply(settings.captureHotKey)
        gifRecorder.apply(settings.gifHotKey)
        copyFileCheckbox.state = settings.copyImageAsFile ? .on : .off
        folderLabel.stringValue = settings.quickSaveDirectory.path
        folderLabel.toolTip = settings.quickSaveDirectory.path
        launchCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        let scales: [Double] = [1, 0.75, 0.5, 0.25]
        screenshotScalePopup.selectItem(at: scales.firstIndex(of: settings.screenshotScale) ?? 0)
        let widths = [480, 640, 960, 1280]
        gifWidthPopup.selectItem(at: widths.firstIndex(of: settings.gifMaximumWidth) ?? 2)
        let frameRates = [5, 10, 15, 20]
        gifFPSPopup.selectItem(at: frameRates.firstIndex(of: settings.gifFramesPerSecond) ?? 1)
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String]) {
        popup.addItems(withTitles: titles)
        popup.controlSize = .small
        popup.widthAnchor.constraint(equalToConstant: 132).isActive = true
    }

    private func refreshHotKeyButtons() {
        captureRecorder.apply(settings.captureHotKey)
        gifRecorder.apply(settings.gifHotKey)
    }

    private func commitHotKey(_ choice: HotKeyChoice, kind: HotKeyKind) {
        let other = kind == .capture ? settings.gifHotKey : settings.captureHotKey
        guard choice != other else {
            refreshHotKeyButtons()
            onError?(
                NSError(
                    domain: "ScreenshotLab.HotKey",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "两个快捷键不能相同，请换一个。",
                    ]
                )
            )
            return
        }

        let previous = kind == .capture
            ? settings.captureHotKey
            : settings.gifHotKey
        if kind == .capture {
            settings.captureHotKey = choice
        } else {
            settings.gifHotKey = choice
        }

        if onHotKeysChanged?() == false {
            if kind == .capture {
                settings.captureHotKey = previous
            } else {
                settings.gifHotKey = previous
            }
            _ = onHotKeysChanged?()
            refreshHotKeyButtons()
        }
    }

    @objc private func copyFileChanged() {
        settings.copyImageAsFile = copyFileCheckbox.state == .on
    }

    @objc private func openHistory() { onOpenHistory?() }

    @objc private func screenshotScaleChanged() {
        let values: [Double] = [1, 0.75, 0.5, 0.25]
        settings.screenshotScale = values[max(0, screenshotScalePopup.indexOfSelectedItem)]
    }

    @objc private func gifWidthChanged() {
        let values = [480, 640, 960, 1280]
        settings.gifMaximumWidth = values[max(0, gifWidthPopup.indexOfSelectedItem)]
    }

    @objc private func gifFPSChanged() {
        let values = [5, 10, 15, 20]
        settings.gifFramesPerSecond = values[max(0, gifFPSPopup.indexOfSelectedItem)]
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.quickSaveDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            self.settings.quickSaveDirectory = url
            self.folderLabel.stringValue = url.path
            self.folderLabel.toolTip = url.path
        }
    }

    @objc private func launchAtLoginChanged() {
        let shouldEnable = launchCheckbox.state == .on
        do {
            let actual = try settings.setLaunchAtLogin(shouldEnable)
            launchCheckbox.state = actual ? .on : .off
        } catch {
            launchCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
            onError?(error)
        }
    }
}

private final class PreferencesBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

private final class PreferenceCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 12,
            yRadius: 12
        )
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class PreferenceSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
