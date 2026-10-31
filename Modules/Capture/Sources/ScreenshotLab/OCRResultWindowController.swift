import AppKit

private final class OCRPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Header doubles as the drag handle for the borderless panel.
private final class OCRPanelHeader: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class OCRTextView: NSTextView {
    var onEsc: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEsc?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Compact dark HUD that docks beside the captured region and shows the
/// recognized text. One placement rule: dock right of the capture, top
/// aligned, clamped to the screen — never flips sides. Once the user drags
/// the panel somewhere it reopens there.
final class OCRResultWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let headerView = OCRPanelHeader()
    private let titleLabel = NSTextField(labelWithString: "识别结果")
    private let statusLabel = NSTextField(labelWithString: "正在识别文字…")
    private let spinner = NSProgressIndicator()
    private let copyButton = HoverButton()
    private let closeButton = HoverButton()
    private let textView = OCRTextView()
    private var isProgrammaticMove = false
    private static let panelWidth: CGFloat = 380

    convenience init() {
        let panel = OCRPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.panelWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("ScreenshotLabOCRPanel")
        self.init(window: panel)
        panel.delegate = self
        buildInterface()
    }

    func showLoading(sourceFrame: CGRect? = nil) {
        statusLabel.stringValue = "正在识别文字…"
        statusLabel.textColor = AppTheme.secondaryText
        textView.string = ""
        copyButton.isEnabled = false
        spinner.startAnimation(nil)
        placePanel(sourceFrame: sourceFrame)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock right of the capture, top aligned with it, clamped into the
    /// screen. A panel the user parked manually reopens at that spot.
    private func placePanel(sourceFrame: CGRect?) {
        guard let window else {
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(sourceFrame ?? .zero) }
            ?? ScreenCaptureService.screenAtMouse()
        let visible = screen.visibleFrame
        let height = min(
            max(sourceFrame?.height ?? 320, 180),
            visible.height - 40
        )
        var origin: CGPoint
        if let parked = AppSettings.shared.ocrPanelOrigin {
            origin = parked
        } else if let sourceFrame {
            origin = CGPoint(x: sourceFrame.maxX + 14, y: sourceFrame.maxY - height)
        } else {
            origin = CGPoint(
                x: visible.midX - Self.panelWidth / 2,
                y: visible.midY - height / 2
            )
        }
        // Clamp into the visible frame; the panel never jumps to the other
        // side of the capture.
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - Self.panelWidth - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - height - 8)
        isProgrammaticMove = true
        window.setFrame(
            CGRect(origin: origin, size: CGSize(width: Self.panelWidth, height: height)),
            display: false
        )
        isProgrammaticMove = false
    }

    func show(result: RecognizedText) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "\(result.lineCount) 行 · \(result.characterCount) 个字符"
        statusLabel.textColor = AppTheme.secondaryText
        textView.string = result.content
        copyButton.isEnabled = true
        textView.scrollToBeginningOfDocument(nil)
#if DEBUG
        if CommandLine.arguments.contains("--demo-ocr") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.window?.contentView?.writeDebugPNG(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-ocr-results.png")
                )
            }
        }
#endif
    }

    func show(error: Error) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = NSColor.systemRed.withAlphaComponent(0.9)
        textView.string = ""
        copyButton.isEnabled = false
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else {
            return
        }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = AppTheme.subtleBorder.cgColor
        contentView.layer?.backgroundColor = AppTheme.floatingSurface.cgColor

        titleLabel.font = AppTheme.font(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        statusLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        statusLabel.textColor = AppTheme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        configureIcon(copyButton, symbol: "doc.on.doc", label: "复制全部文字",
            action: #selector(copyAll), enabled: false)
        configureIcon(closeButton, symbol: "xmark", label: "关闭 (Esc)",
            action: #selector(closeWindow), enabled: true)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)
        for view in [titleLabel, spinner, statusLabel, copyButton, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview(view)
        }
        headerView.heightAnchor.constraint(equalToConstant: 46).isActive = true

        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = AppTheme.font(ofSize: 13)
        textView.textColor = AppTheme.primaryText
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onEsc = { [weak self] in self?.closeWindow() }

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26),

            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 26),
            copyButton.heightAnchor.constraint(equalToConstant: 26),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    private func configureIcon(_ button: HoverButton, symbol: String, label: String, action: Selector, enabled: Bool) {
        button.image = AppTheme.symbol(symbol, size: 12, weight: .medium)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.isEnabled = enabled
        button.alphaValue = enabled ? 1 : 0.4
        button.normalBackground = NSColor.white.withAlphaComponent(0.06)
        button.hoverBackground = NSColor.white.withAlphaComponent(0.14)
        button.contentTintColor = AppTheme.primaryText
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let window else {
            return
        }
        AppSettings.shared.ocrPanelOrigin = window.frame.origin
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        statusLabel.stringValue = "已复制全部文字"
        statusLabel.textColor = AppTheme.accent
    }

    @objc private func closeWindow() {
        close()
    }
}
