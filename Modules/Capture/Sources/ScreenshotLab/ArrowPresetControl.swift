import AppKit

/// Three discrete arrow presets. Each preview uses the real shaft and head
/// proportions, while the selected preset emits both values together.
final class ArrowPresetControl: NSView {
    let lineWidths: [CGFloat] = [2, 4, 8]
    let headSizes: [CGFloat] = [12, 24, 40]
    private(set) var selectedIndex = 1
    var selectedLineWidth: CGFloat { lineWidths[selectedIndex] }
    var selectedHeadSize: CGFloat { headSizes[selectedIndex] }
    var inkColor: NSColor = .systemRed {
        didSet { updateButtons() }
    }
    var onSelectionChanged: ((CGFloat, CGFloat) -> Void)?
    private(set) var buttons: [ArrowPresetButton] = []

    private let labels = ["小箭头", "中箭头", "大箭头"]
    private let helpTexts = [
        "较细的线条和较小的箭头",
        "标准线条和箭头",
        "较粗的线条和较大的箭头",
    ]
    private let buttonSize = NSSize(width: 36, height: 32)
    private let spacing: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 112, height: 32)
    }

    override var acceptsFirstResponder: Bool { true }

    func select(index: Int, notify: Bool = true) {
        let next = max(0, min(lineWidths.count - 1, index))
        let changed = next != selectedIndex
        selectedIndex = next
        updateButtons()
        setAccessibilityValue(labels[next])
        window?.makeFirstResponder(buttons[next])
        if notify && changed {
            onSelectionChanged?(selectedLineWidth, selectedHeadSize)
        }
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * (buttonSize.width + spacing),
                y: (bounds.height - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleArrow(event) { return }
        if event.keyCode == 36 || event.keyCode == 49 {
            buttons[selectedIndex].performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    @discardableResult
    private func handleArrow(_ event: NSEvent) -> Bool {
        let forbidden: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(forbidden).isEmpty else { return false }
        switch event.keyCode {
        case 123, 126:
            select(index: selectedIndex - 1)
        case 124, 125:
            select(index: selectedIndex + 1)
        default:
            return false
        }
        return true
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        frame.size = intrinsicContentSize
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("箭头大小")
        setAccessibilityValue(labels[selectedIndex])
        toolTip = "选择小、中、大三种箭头"

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: intrinsicContentSize.width),
            heightAnchor.constraint(equalToConstant: intrinsicContentSize.height),
        ])

        for index in lineWidths.indices {
            let button = ArrowPresetButton()
            button.tag = index
            button.lineWidth = lineWidths[index]
            button.headSize = headSizes[index]
            button.inkColor = inkColor
            button.target = self
            button.action = #selector(optionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier("ArrowPreset.option.\(index)")
            button.toolTip = "\(labels[index])：\(helpTexts[index])"
            button.setAccessibilityLabel(labels[index])
            button.setAccessibilityHelp(helpTexts[index])
            button.onArrowKey = { [weak self] event in self?.handleArrow(event) ?? false }
            buttons.append(button)
            addSubview(button)
        }
        updateButtons()
    }

    @objc private func optionClicked(_ sender: NSButton) {
        guard lineWidths.indices.contains(sender.tag) else { return }
        window?.makeFirstResponder(sender)
        select(index: sender.tag)
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            button.state = selected ? .on : .off
            button.selectedOption = selected
            button.inkColor = inkColor
        }
    }
}

final class ArrowPresetButton: NSButton {
    var lineWidth: CGFloat = 4
    var headSize: CGFloat = 24
    var inkColor: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }
    var selectedOption = false {
        didSet { needsDisplay = true }
    }
    var onArrowKey: ((NSEvent) -> Bool)?

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingAreaReference: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        setButtonType(.toggle)
        setAccessibilityRole(.radioButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onArrowKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let panelRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 7, yRadius: 7)
        if selectedOption {
            AppTheme.accent.withAlphaComponent(0.18).setFill()
        } else if hovering {
            NSColor.white.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.045).setFill()
        }
        panel.fill()

        if selectedOption {
            AppTheme.accent.setStroke()
            panel.lineWidth = 2
        } else if hovering {
            AppTheme.subtleBorder.withAlphaComponent(0.55).setStroke()
            panel.lineWidth = 1
        } else {
            AppTheme.subtleBorder.setStroke()
            panel.lineWidth = 1
        }
        panel.stroke()

        drawArrow(in: bounds.insetBy(dx: 4, dy: 4))

        if window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: panelRect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private func drawArrow(in rect: CGRect) {
        let shaftWidth = max(1, lineWidth * 0.7)
        let headLength = min(rect.width * 0.48, max(4, headSize * 0.42))
        let headWidth = min(rect.height * 0.78, max(4, headSize * 0.46))
        let tip = CGPoint(x: rect.maxX - 1, y: rect.midY)
        let headBackX = tip.x - headLength
        let shaftEndX = min(tip.x - 1, headBackX + shaftWidth * 0.25)

        inkColor.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = shaftWidth
        shaft.lineCapStyle = .round
        shaft.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        shaft.line(to: CGPoint(x: shaftEndX, y: rect.midY))
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: headBackX, y: rect.midY - headWidth / 2))
        head.line(to: CGPoint(x: headBackX, y: rect.midY + headWidth / 2))
        head.close()
        inkColor.setFill()
        head.fill()
    }
}
