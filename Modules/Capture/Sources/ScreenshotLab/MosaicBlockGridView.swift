import AppKit

final class MosaicBlockGridView: NSView {
    let values: [CGFloat] = [4, 8, 12, 20, 32, 48]
    private(set) var selectedIndex = 2
    var selectedValue: CGFloat { values[selectedIndex] }
    var onSelectionChanged: ((CGFloat) -> Void)?
    private(set) var optionButtons: [NSButton] = []

    private let labels = ["细腻", "细颗粒", "标准", "粗颗粒", "大颗粒", "特大颗粒"]
    private let helpTexts = [
        "像素块最小，保留更多画面细节",
        "像素块较小，颗粒细密",
        "标准大小的像素块",
        "像素块较大，颗粒更明显",
        "大块像素，细节更少",
        "最大的像素块，颗粒最粗",
    ]
    private let gridButtonSize = NSSize(width: 40, height: 26)
    private let gridSpacing: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 128, height: 56)
    }

    override var acceptsFirstResponder: Bool { true }

    func select(index: Int, notify: Bool = true) {
        let next = max(0, min(values.count - 1, index))
        let changed = next != selectedIndex
        selectedIndex = next
        updateButtonStates()
        window?.makeFirstResponder(optionButtons[next])
        if notify && changed {
            onSelectionChanged?(selectedValue)
        }
    }

    override func layout() {
        super.layout()
        for (index, button) in optionButtons.enumerated() {
            let column = CGFloat(index % 3)
            let row = CGFloat(index / 3)
            button.frame = CGRect(
                x: column * (gridButtonSize.width + gridSpacing),
                y: (1 - row) * (gridButtonSize.height + gridSpacing),
                width: gridButtonSize.width,
                height: gridButtonSize.height
            )
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleArrow(event) { return }
        if event.keyCode == 36 || event.keyCode == 49 {
            optionButtons[selectedIndex].performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    @discardableResult
    private func handleArrow(_ event: NSEvent) -> Bool {
        let forbidden: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(forbidden).isEmpty else { return false }
        let target: Int
        switch event.keyCode {
        case 123: target = selectedIndex % 3 == 0 ? selectedIndex : selectedIndex - 1
        case 124: target = selectedIndex % 3 == 2 ? selectedIndex : selectedIndex + 1
        case 126: target = selectedIndex < 3 ? selectedIndex : selectedIndex - 3
        case 125: target = selectedIndex >= 3 ? selectedIndex : selectedIndex + 3
        default: return false
        }
        select(index: target)
        return true
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        frame.size = intrinsicContentSize
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("马赛克像素块")
        toolTip = "选择马赛克颗粒的粗细"

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: intrinsicContentSize.width),
            heightAnchor.constraint(equalToConstant: intrinsicContentSize.height),
        ])

        let textures = MosaicTextureRenderer.textures(for: values)
        for (index, texture) in textures.enumerated() {
            let button = MosaicOptionButton()
            button.tag = index
            button.image = texture
            button.target = self
            button.action = #selector(optionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier("MosaicBlock.option.\(index)")
            button.toolTip = "\(labels[index])：\(helpTexts[index])"
            button.setAccessibilityLabel(labels[index])
            button.setAccessibilityHelp(helpTexts[index])
            button.onArrowKey = { [weak self] event in self?.handleArrow(event) ?? false }
            optionButtons.append(button)
            addSubview(button)
        }
        updateButtonStates()
    }

    @objc private func optionClicked(_ sender: NSButton) {
        guard values.indices.contains(sender.tag) else { return }
        window?.makeFirstResponder(sender)
        select(index: sender.tag)
    }

    private func updateButtonStates() {
        for (index, button) in optionButtons.enumerated() {
            let selected = index == selectedIndex
            button.state = selected ? .on : .off
            (button as? MosaicOptionButton)?.selectedOption = selected
        }
    }
}

private final class MosaicOptionButton: NSButton {
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
        imageScaling = .scaleAxesIndependently
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
        let bounds = self.bounds.insetBy(dx: 0.75, dy: 0.75)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        let fill: NSColor
        if selectedOption {
            fill = AppTheme.accent.withAlphaComponent(0.18)
        } else if hovering {
            fill = NSColor.white.withAlphaComponent(0.12)
        } else {
            fill = NSColor.white.withAlphaComponent(0.045)
        }
        fill.setFill()
        background.fill()

        let textureRect = bounds.insetBy(dx: 2, dy: 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: textureRect, xRadius: 5, yRadius: 5).addClip()
        image?.draw(in: textureRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        if selectedOption {
            AppTheme.accent.setStroke()
            background.lineWidth = 2
        } else if hovering {
            AppTheme.subtleBorder.withAlphaComponent(0.55).setStroke()
            background.lineWidth = 1
        } else {
            AppTheme.subtleBorder.setStroke()
            background.lineWidth = 1
        }
        background.stroke()

        if window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

private enum MosaicTextureRenderer {
    private static let imageSize = NSSize(width: 72, height: 44)

    static func textures(for values: [CGFloat]) -> [NSImage] {
        values.map { value in
            NSImage(size: imageSize, flipped: false) { rect in
                let cell = max(3, value / 2)
                let shades: [CGFloat] = [0.90, 0.46, 0.68]
                for row in 0...Int(ceil(rect.height / cell)) {
                    for column in 0...Int(ceil(rect.width / cell)) {
                        NSColor(calibratedWhite: shades[(row * 2 + column) % shades.count], alpha: 1).setFill()
                        CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell).intersection(rect).fill()
                    }
                }
                return true
            }
        }
    }
}
