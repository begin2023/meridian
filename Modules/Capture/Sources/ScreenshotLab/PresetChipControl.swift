import AppKit

/// A row of labelled discrete options, e.g. blur strength 弱/中/强.
/// Same interaction contract as ArrowPresetControl: radio semantics,
/// arrow-key navigation, per-option tooltips and accessibility.
final class PresetChipControl: NSView {
    let titles: [String]
    private(set) var selectedIndex: Int
    var onSelectionChanged: ((Int) -> Void)?
    private(set) var buttons: [PresetChipButton] = []

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(titles.count) * 34 + CGFloat(titles.count - 1) * 4, height: 24)
    }
    override var acceptsFirstResponder: Bool { true }

    init(titles: [String], tooltips: [String], selected: Int, accessibilityLabel: String) {
        precondition(titles.count == tooltips.count && titles.indices.contains(selected))
        self.titles = titles
        self.selectedIndex = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(titles[selected])

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: intrinsicContentSize.width),
            heightAnchor.constraint(equalToConstant: intrinsicContentSize.height),
        ])

        for (index, title) in titles.enumerated() {
            let button = PresetChipButton()
            button.tag = index
            button.title = title
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: AppTheme.font(ofSize: 12, weight: .medium),
                .foregroundColor: AppTheme.primaryText,
            ])
            button.toolTip = tooltips[index]
            button.setAccessibilityLabel(title)
            button.setAccessibilityRole(.radioButton)
            button.identifier = NSUserInterfaceItemIdentifier("PresetChip.option.\(index)")
            button.target = self
            button.action = #selector(optionClicked(_:))
            button.onArrowKey = { [weak self] event in self?.handleArrow(event) ?? false }
            buttons.append(button)
            addSubview(button)
        }
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(index: Int, notify: Bool = true) {
        let next = max(0, min(titles.count - 1, index))
        let changed = next != selectedIndex
        selectedIndex = next
        updateButtons()
        setAccessibilityValue(titles[next])
        if changed && notify {
            onSelectionChanged?(next)
        }
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 34, height: 24)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * (size.width + 4),
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
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

    @objc private func optionClicked(_ sender: NSButton) {
        guard titles.indices.contains(sender.tag) else { return }
        window?.makeFirstResponder(sender)
        select(index: sender.tag)
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            button.selectedOption = index == selectedIndex
        }
    }
}

final class PresetChipButton: NSButton {
    var selectedOption = false {
        didSet { needsDisplay = true }
    }
    var onArrowKey: ((NSEvent) -> Bool)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingAreaReference: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

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
        } else {
            AppTheme.subtleBorder.setStroke()
            panel.lineWidth = 1
        }
        panel.stroke()

        let tint = selectedOption ? AppTheme.accent : AppTheme.primaryText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppTheme.font(ofSize: 12, weight: selectedOption ? .semibold : .regular),
            .foregroundColor: tint,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: CGPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }
}
