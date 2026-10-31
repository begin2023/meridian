import AppKit

final class AnnotationToolButton: HoverButton {
    override var wantsUpdateLayer: Bool { false }
    override var isFlipped: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var selected = false { didSet { needsDisplay = true } }
    var iconFrame: CGRect { CGRect(x: (bounds.width - 20) / 2, y: 23, width: 20, height: 20) }
    var labelFrame: CGRect { CGRect(x: 0, y: 4, width: bounds.width, height: 16) }

    // Intrinsic (not equality-constrained) so the window can shrink below the
    // full top-row width; the placement logic then moves actions down.
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 48) }

    override func draw(_ dirtyRect: NSRect) {
        // NSButton's imageAbove layout depends on each image's intrinsic size
        // and symbol baseline. Fixed slots keep every tool and selection aligned.
        let tint = selected ? AppTheme.accent : AppTheme.primaryText
        if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let tinted = NSImage(size: iconFrame.size, flipped: false) { rect in
                NSImage(cgImage: cgImage, size: rect.size).draw(in: rect)
                tint.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: iconFrame)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (title as NSString).draw(in: labelFrame, withAttributes: [
            .font: AppTheme.font(ofSize: 11),
            .foregroundColor: tint,
            .paragraphStyle: paragraph,
        ])
    }
}

final class AnnotationActionButton: HoverButton {
    var primary = false
    override var wantsUpdateLayer: Bool { false }
    override var isFlipped: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // icon 14 + gap 6 + text + symmetric 10pt padding; intrinsic (not pinned)
    // so a narrow window can compress the row and move actions to row two.
    override var intrinsicContentSize: NSSize {
        let textSize = (title as NSString).size(withAttributes: [
            .font: AppTheme.font(ofSize: 13, weight: .medium),
        ])
        return NSSize(width: ceil(textSize.width) + 40, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = primary ? .black : AppTheme.primaryText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppTheme.font(ofSize: 13, weight: .medium), .foregroundColor: tint,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let left = (bounds.width - textSize.width - 20) / 2
        if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let tinted = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                NSImage(cgImage: cgImage, size: rect.size).draw(in: rect)
                tint.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: CGRect(x: left, y: (bounds.height - 14) / 2, width: 14, height: 14))
        }
        (title as NSString).draw(at: CGPoint(x: left + 20, y: (bounds.height - textSize.height) / 2),
                                 withAttributes: attributes)
    }
}

enum EditorAction {
    case copy
    case save
    case quickSave
    case pin
    case ocr
}

final class EditorToolbarView: FrostedBarView {
    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onWidthChanged: ((CGFloat) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onBrushSizeChanged: ((CGFloat) -> Void)?
    var onBlockSizeChanged: ((CGFloat) -> Void)?
    var onArrowSizeChanged: ((CGFloat) -> Void)?
    var onBlurStrengthChanged: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAction: ((EditorAction) -> Void)?

    private var toolButtons: [AnnotationTool: AnnotationToolButton] = [:]
    private var activeTool: AnnotationTool = .select
    private let undoButton = HoverButton()
    private let redoButton = HoverButton()
    private let deleteButton = HoverButton()
    private let colorWell = NSColorWell()
    private let colorLabel = NSTextField(labelWithString: "颜色")
    private let widthTrack = SizeTrackControl(values: [1, 2, 4, 8, 12, 20, 32], selected: 2)
    private let fontSizeTrack = SizeTrackControl(values: [18, 26, 36, 48, 64], selected: 1)
    private let styleLabel = NSTextField(labelWithString: "线宽")
    private let brushSizeTrack = SizeTrackControl(values: [12, 24, 40, 64, 96, 128], selected: 2, appearance: .mosaic)
    private let blockGrid = MosaicBlockGridView()
    private let arrowPresets = ArrowPresetControl()
    private let blurChips = PresetChipControl(
        titles: ["弱", "中", "强"],
        tooltips: ["轻度模糊，仍能看出轮廓", "标准模糊强度", "强力模糊，完全看不清内容"],
        selected: 1,
        accessibilityLabel: "模糊强度"
    )
    private static let blurRadii: [CGFloat] = [8, 18, 36]
    private let detailLabel = NSTextField(labelWithString: "像素块")

    private let topRow = NSStackView()
    private let optionsRow = NSStackView()
    private let options = NSStackView(views: [])
    private let actions = NSStackView()
    /// The output actions always share the top row, pinned to the trailing
    /// edge as an overlay so they never fight the tools for width.
    private var actionsTopPlacement: NSLayoutConstraint!
    /// Owned height; switches between the full two-row bar and the compact
    /// single-row bar via a single constant. The options row keeps a fixed
    /// slot below the tools row (hidden when collapsed).
    private var barHeightConstraint: NSLayoutConstraint!
    private var optionsTopConstraint: NSLayoutConstraint!
    private var optionsHeightConstraint: NSLayoutConstraint!

    /// Single-row toolbar when a tool has no options; two rows otherwise.
    static let compactHeight: CGFloat = 66
    static let fullHeight: CGFloat = 130

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeightConstraint?.constant ?? Self.fullHeight)
    }

    func setHistory(canUndo: Bool, canRedo: Bool, hasSelection: Bool, hasAnnotations: Bool) {
        for (button, enabled) in [(undoButton, canUndo), (redoButton, canRedo), (deleteButton, hasSelection)] {
            button.isEnabled = enabled
            button.alphaValue = enabled ? 1 : 0.35
        }
    }

    func setTool(_ tool: AnnotationTool) {
        activeTool = tool
        for (candidate, button) in toolButtons {
            let selected = candidate == tool
            button.state = selected ? .on : .off
            button.selected = selected
            button.normalBackground = selected ? AppTheme.accent.withAlphaComponent(0.20) : .clear
            button.contentTintColor = selected ? AppTheme.accent : AppTheme.primaryText
            button.attributedTitle = NSAttributedString(string: candidate.label, attributes: [
                .font: AppTheme.font(ofSize: 11, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? AppTheme.accent : AppTheme.primaryText,
            ])
        }
        let isText = tool == .text
        let isMosaic = tool == .mosaic
        let isArrow = tool == .arrow
        let isBlur = tool == .blur
        let noStyle = [.select, .crop].contains(tool)
        styleLabel.isHidden = noStyle
        updateStyleLabel()
        widthTrack.isHidden = noStyle || isText || isMosaic || isArrow || isBlur
        fontSizeTrack.isHidden = !isText
        brushSizeTrack.isHidden = !isMosaic
        detailLabel.isHidden = !isMosaic
        detailLabel.stringValue = "像素块"
        blockGrid.isHidden = !isMosaic
        arrowPresets.isHidden = !isArrow
        blurChips.isHidden = !isBlur
        colorWell.isHidden = noStyle || isMosaic || isBlur
        colorLabel.isHidden = colorWell.isHidden
        if colorWell.isHidden { colorWell.deactivate() }
        refreshRows()
        if isArrow {
            onWidthChanged?(arrowPresets.lineWidths[arrowPresets.selectedIndex])
            onArrowSizeChanged?(arrowPresets.headSizes[arrowPresets.selectedIndex])
        } else if !noStyle && !isText && !isMosaic && !isBlur {
            onWidthChanged?(widthTrack.selectedValue)
        } else if isBlur {
            onBlurStrengthChanged?(Self.blurRadii[blurChips.selectedIndex])
        }
    }

    private func build() {
        layer?.cornerRadius = 0
        layer?.borderWidth = 0

        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 3
        topRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRow)

        for tool in AnnotationTool.allCases {
            let button = AnnotationToolButton()
            button.image = tool.icon
            button.title = tool.label
            button.imagePosition = .imageAbove
            button.font = AppTheme.font(ofSize: 11)
            button.toolTip = "\(tool.tooltip) (\(tool.shortcut.uppercased()))"
            button.setAccessibilityLabel(tool.tooltip)
            button.identifier = NSUserInterfaceItemIdentifier("EditorTool.\(tool.rawValue)")
            button.target = self
            button.action = #selector(toolClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 48),
            ])
            toolButtons[tool] = button
            topRow.addArrangedSubview(button)
            if tool == .select || tool == .arrow || tool == .text || tool == .blur {
                topRow.setCustomSpacing(11, after: button)
            }
        }

        topRow.addArrangedSubview(spacer())
        topRow.addArrangedSubview(separator())
        configureIcon(undoButton, symbol: "arrow.uturn.backward", label: "撤销 (⌘Z)", action: #selector(undoClicked))
        configureIcon(redoButton, symbol: "arrow.uturn.forward", label: "重做 (⇧⌘Z)", action: #selector(redoClicked))
        configureIcon(deleteButton, symbol: "trash", label: "删除选中标注 (Delete)", action: #selector(deleteClicked))
        topRow.addArrangedSubview(undoButton)
        topRow.addArrangedSubview(redoButton)
        topRow.addArrangedSubview(deleteButton)

        // Output actions overlay the right edge instead of living inside a
        // stack: pinning them to the trailing edge creates no minimum-width
        // pressure, so the window can always shrink. Their vertical position
        // switches between the top row and the options row (see
        // updateActionsPlacement).
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.detachesHiddenViews = true
        actions.translatesAutoresizingMaskIntoConstraints = false
        actionsTopPlacement = actions.centerYAnchor.constraint(equalTo: topRow.centerYAnchor)

        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = "标注颜色"
        colorWell.setAccessibilityLabel("标注颜色")
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        colorLabel.font = AppTheme.font(ofSize: 12)
        colorLabel.textColor = AppTheme.secondaryText
        colorLabel.identifier = NSUserInterfaceItemIdentifier("EditorStyle.colorLabel")
        styleLabel.font = AppTheme.font(ofSize: 12)
        styleLabel.textColor = AppTheme.secondaryText
        for (track, title, action) in [
            (widthTrack, "标注线宽", #selector(widthChanged)),
            (fontSizeTrack, "文字字号", #selector(fontSizeChanged)),
            (brushSizeTrack, "马赛克笔刷直径", #selector(brushSizeChanged)),
        ] {
            track.target = self
            track.action = action
            track.setAccessibilityLabel(title)
        }
        blockGrid.onSelectionChanged = { [weak self] size in
            guard let self else { return }
            self.brushSizeTrack.mosaicCellSize = 1.5 + CGFloat(self.blockGrid.selectedIndex) * 0.65
            self.onBlockSizeChanged?(size)
        }
        brushSizeTrack.mosaicCellSize = 1.5 + CGFloat(blockGrid.selectedIndex) * 0.65
        arrowPresets.onSelectionChanged = { [weak self] width, head in
            self?.onWidthChanged?(width)
            self?.onArrowSizeChanged?(head)
        }
        blurChips.onSelectionChanged = { [weak self] index in
            guard let self else { return }
            self.onBlurStrengthChanged?(Self.blurRadii[index])
        }
        detailLabel.font = AppTheme.font(ofSize: 12)
        detailLabel.textColor = AppTheme.secondaryText

        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 6
        options.detachesHiddenViews = true
        for view in [colorLabel, colorWell, styleLabel, widthTrack, fontSizeTrack,
                     brushSizeTrack, detailLabel, blockGrid, arrowPresets, blurChips] {
            options.addArrangedSubview(view)
        }
        options.setCustomSpacing(12, after: colorWell)

        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.spacing = 6
        optionsRow.translatesAutoresizingMaskIntoConstraints = false
        optionsRow.addArrangedSubview(options)
        optionsRow.addArrangedSubview(spacer())
        addSubview(optionsRow)

        addAction(title: "钉图", symbol: "pin", action: .pin, tooltip: "将截图钉在屏幕上")
        addAction(title: "提取文字", symbol: "text.viewfinder", action: .ocr, tooltip: "使用 OCR 提取文字")
        addAction(title: "保存图片", symbol: "square.and.arrow.down", action: .save, tooltip: "保存图片 (⌘S)")
        addAction(title: "复制图片", symbol: "doc.on.doc", action: .copy, tooltip: "复制图片 (⌘C)", primary: true)
        // Above the rows so the overlay never hides behind option views.
        addSubview(actions, positioned: .above, relativeTo: nil)

        optionsTopConstraint = optionsRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8)
        optionsHeightConstraint = optionsRow.heightAnchor.constraint(equalToConstant: 56)
        barHeightConstraint = heightAnchor.constraint(equalToConstant: Self.fullHeight)

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            topRow.heightAnchor.constraint(equalToConstant: 48),
            optionsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            optionsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            optionsTopConstraint,
            optionsHeightConstraint,
            barHeightConstraint,
        ])
        actionsTopPlacement.isActive = true

        setTool(.select)
        setHistory(canUndo: false, canRedo: false, hasSelection: false, hasAnnotations: false)
    }

    private var optionsRowHidden: Bool {
        options.arrangedSubviews.allSatisfy(\.isHidden)
    }

    private func refreshRows() {
        let collapsed = optionsRowHidden
        optionsRow.isHidden = collapsed
        barHeightConstraint.constant = collapsed ? Self.compactHeight : Self.fullHeight
        invalidateIntrinsicContentSize()
    }

    private func updateStyleLabel() {
        switch activeTool {
        case .text:
            styleLabel.stringValue = "字号 · \(Int(fontSizeTrack.selectedValue))"
        case .mosaic:
            styleLabel.stringValue = "笔刷 · \(Int(brushSizeTrack.selectedValue))"
        case .blur:
            styleLabel.stringValue = "强度"
        case .arrow:
            styleLabel.stringValue = "箭头"
        case .select, .crop:
            styleLabel.stringValue = ""
        default:
            styleLabel.stringValue = "粗细 · \(Int(widthTrack.selectedValue))"
        }
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private func configureIcon(_ button: HoverButton, symbol: String, label: String, action: Selector) {
        button.image = AppTheme.symbol(symbol, size: 16)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthLimit = button.widthAnchor.constraint(equalToConstant: 32)
        widthLimit.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            widthLimit,
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func textButton(title: String, symbol: String, action: Selector) -> AnnotationActionButton {
        let button = AnnotationActionButton()
        button.title = title
        button.image = AppTheme.symbol(symbol, size: 13)
        button.imagePosition = .imageLeading
        button.font = AppTheme.font(ofSize: 13, weight: .medium)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: AppTheme.font(ofSize: 13, weight: .medium),
            .foregroundColor: AppTheme.primaryText,
        ])
        button.normalBackground = NSColor.white.withAlphaComponent(0.07)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func addAction(title: String, symbol: String, action: EditorAction, tooltip: String, primary: Bool = false) {
        let button = textButton(title: title, symbol: symbol, action: #selector(actionClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("EditorAction.\(action)")
        button.toolTip = tooltip
        button.setAccessibilityLabel(title)
        if primary {
            button.primary = true
            button.normalBackground = AppTheme.accent
            button.hoverBackground = AppTheme.accent.blended(withFraction: 0.14, of: .white) ?? AppTheme.accent
            button.contentTintColor = .black
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: AppTheme.font(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.black,
            ])
        }
        actions.addArrangedSubview(button)
    }

    @objc private func toolClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
              let tool = AnnotationTool(rawValue: String(raw)) else { return }
        onToolChanged?(tool)
    }

    @objc private func colorChanged() {
        for track in [widthTrack, fontSizeTrack] { track.inkColor = colorWell.color }
        arrowPresets.inkColor = colorWell.color
        onColorChanged?(colorWell.color)
    }
    @objc private func widthChanged() {
        updateStyleLabel()
        onWidthChanged?(widthTrack.selectedValue)
    }
    @objc private func brushSizeChanged() {
        updateStyleLabel()
        onBrushSizeChanged?(brushSizeTrack.selectedValue)
    }
    @objc private func fontSizeChanged() {
        updateStyleLabel()
        onFontSizeChanged?(fontSizeTrack.selectedValue)
    }
    @objc private func undoClicked() { onUndo?() }
    @objc private func redoClicked() { onRedo?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func actionClicked(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "EditorAction.copy": onAction?(.copy)
        case "EditorAction.save": onAction?(.save)
        case "EditorAction.pin": onAction?(.pin)
        case "EditorAction.ocr": onAction?(.ocr)
        default: break
        }
    }
}
