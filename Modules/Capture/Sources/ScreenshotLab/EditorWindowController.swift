import AppKit

private final class EditorWindow: NSWindow {
    var onCommand: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onAction: ((EditorAction, CGImage) -> Void)?
    var onClose: (() -> Void)?

    let canvas: AnnotationCanvasView
    private let toolbar = EditorToolbarView()
    private let instructionsLabel = NSTextField(labelWithString: AnnotationTool.select.instructions)
    private let dimensionsLabel = NSTextField(labelWithString: "")

    init(image: CGImage) {
        canvas = AnnotationCanvasView(image: image)

        let screen = ScreenCaptureService.screenAtMouse()
        let maxWidth = screen.visibleFrame.width * 0.88
        let maxHeight = screen.visibleFrame.height * 0.86
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(1, min((maxWidth - 56) / imageWidth, (maxHeight - 190) / imageHeight))
        // The editor toolbar keeps its labeled output actions on the top row,
        // so the window stays at least 1100pt wide (clamped to small screens).
        let width = min(
            max(1100, min(maxWidth, imageWidth * scale + 56)),
            max(980, screen.visibleFrame.width - 16)
        )
        let height = max(500, min(maxHeight, imageHeight * scale + 190))

        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑截图"
        window.identifier = NSUserInterfaceItemIdentifier("ScreenshotLabEditor")
        if !ScreenshotLabRuntime.isEmbedded {
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = AppTheme.graphite
        } else {
            window.appearance = nil
            window.backgroundColor = .windowBackgroundColor
        }
        window.minSize = NSSize(width: 980, height: 460)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.onCommand = { [weak self] event in self?.handleCommand(event) ?? false }
        buildInterface()
        wireActions()
        updateStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(canvas)
#if DEBUG
        if CommandLine.arguments.contains("--demo-editor") {
            canvas.seedDemoAnnotations()
            let annotated = canvas.renderFinalImage()
            canvas.undo()
            canvas.redo()
            try? ImageOutput.writePNG(annotated, to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-final.png"))
            let cropCanvas = AnnotationCanvasView(image: DebugFixtures.makeSampleImage())
            let cropSize = cropCanvas.demoCropSize(rect: CGRect(x: 150, y: 150, width: 800, height: 600))
            try? ImageOutput.writePNG(cropCanvas.renderFinalImage(), to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-crop.png"))
            try? "\(Int(cropSize.width))x\(Int(cropSize.height))".write(
                to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-crop.txt"), atomically: true, encoding: .utf8
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.window?.contentView?.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-offscreen.png"))
            }
        }
#endif
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func performAction(_ action: EditorAction) {
        onAction?(action, canvas.renderFinalImage())
    }

    private func handleCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Standard editing shortcuts keep their normal meaning inside a text field.
        let editingText = window?.firstResponder is NSTextView
        switch key {
        case "c" where !editingText && !modifiers.contains(.option):
            performAction(.copy)
        case "s":
            performAction(modifiers.contains(.option) ? .quickSave : .save)
        case "z" where !editingText:
            modifiers.contains(.shift) ? canvas.redo() : canvas.undo()
        default: return false
        }
        return true
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        toolbar.identifier = NSUserInterfaceItemIdentifier("ScreenshotLabEditorToolbar")
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)
        contentView.addSubview(canvas)

        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = AppTheme.floatingSurface.cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footer)
        instructionsLabel.font = AppTheme.font(ofSize: 11)
        instructionsLabel.textColor = AppTheme.secondaryText
        instructionsLabel.lineBreakMode = .byTruncatingTail
        instructionsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensionsLabel.textColor = AppTheme.secondaryText
        for label in [instructionsLabel, dimensionsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
        }

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            // Toolbar height is intrinsic: it collapses to one row for tools
            // without style options.
            canvas.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            instructionsLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            instructionsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            instructionsLabel.trailingAnchor.constraint(lessThanOrEqualTo: dimensionsLabel.leadingAnchor, constant: -16),
            dimensionsLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            dimensionsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func updateStatus() {
        toolbar.setHistory(canUndo: canvas.canUndo, canRedo: canvas.canRedo,
                           hasSelection: canvas.hasSelection, hasAnnotations: canvas.hasAnnotations)
        instructionsLabel.stringValue = canvas.tool.instructions
        dimensionsLabel.stringValue = "\(canvas.image.width) × \(canvas.image.height) px"
        window?.subtitle = "\(canvas.image.width) × \(canvas.image.height) 像素"
    }

    private func wireActions() {
        toolbar.onToolChanged = { [weak self] tool in
            self?.canvas.tool = tool
            self?.window?.makeFirstResponder(self?.canvas)
        }
        canvas.onToolChanged = { [weak self] tool in
            self?.toolbar.setTool(tool)
            self?.updateStatus()
        }
        canvas.onCopy = { [weak self] in self?.performAction(.copy) }
        toolbar.onColorChanged = { [weak self] color in self?.canvas.setColor(color) }
        toolbar.onWidthChanged = { [weak self] width in self?.canvas.setLineWidth(width) }
        toolbar.onFontSizeChanged = { [weak self] size in self?.canvas.textFontSize = size }
        toolbar.onBrushSizeChanged = { [weak self] size in self?.canvas.mosaicBrushSize = size }
        toolbar.onBlockSizeChanged = { [weak self] size in self?.canvas.mosaicBlockSize = size }
        toolbar.onArrowSizeChanged = { [weak self] size in self?.canvas.arrowHeadSize = size }
        toolbar.onBlurStrengthChanged = { [weak self] radius in self?.canvas.blurRadius = radius }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        toolbar.onRedo = { [weak self] in self?.canvas.redo() }
        toolbar.onDelete = { [weak self] in self?.canvas.deleteSelection() }
        toolbar.onAction = { [weak self] action in self?.performAction(action) }
        canvas.onHistoryChanged = { [weak self] in self?.updateStatus() }
        canvas.onSelectionChanged = { [weak self] in self?.updateStatus() }
        // Esc with nothing left to cancel closes the editor window.
        canvas.onRequestExit = { [weak self] in
            self?.window?.performClose(nil)
        }
        NSColorPanel.shared.showsAlpha = true
    }

    func confirmClearAll() {
        guard let window, canvas.hasAnnotations else { return }
        let alert = NSAlert()
        alert.messageText = "清空所有标注？"
        alert.informativeText = "截图原图会保留。清空后可以使用 ⌘Z 撤销。"
        alert.addButton(withTitle: "清空标注")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.canvas.clearAll() }
        }
    }
}
