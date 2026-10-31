import AppKit

/// The only thumb is the current brush preview; its size follows the drag.
final class SizeTrackControl: NSControl {
    enum Appearance { case ink, mosaic }

    let values: [CGFloat]
    let sampleStyle: Appearance
    private(set) var selectedPosition: CGFloat
    var selectedIndex: Int { Int(selectedPosition.rounded()) }
    var selectedValue: CGFloat {
        let lower = min(Int(selectedPosition), values.count - 2)
        let fraction = selectedPosition - CGFloat(lower)
        return values[lower] + (values[lower + 1] - values[lower]) * fraction
    }
    var inkColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var mosaicCellSize: CGFloat = 3 { didSet { needsDisplay = true } }
    private(set) var displayedPosition: CGFloat
    private var animation: Timer?
    private(set) var isDragging = false
    var trackWidth: CGFloat { 2 }
    var previewDiameter: CGFloat { 5 + displayedPosition / CGFloat(values.count - 1) * 19 }
    var previewFrame: CGRect {
        let center = nodeCenter(at: displayedPosition)
        return CGRect(x: center.x - previewDiameter / 2, y: center.y - previewDiameter / 2,
                      width: previewDiameter, height: previewDiameter)
    }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 100, height: 32) }

    init(values: [CGFloat], selected: Int, appearance: Appearance = .ink) {
        self.values = values
        precondition(values.count > 1 && values.indices.contains(selected))
        self.selectedPosition = CGFloat(selected)
        self.displayedPosition = CGFloat(selected)
        self.sampleStyle = appearance
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
        setAccessibilityValue(NSNumber(value: Double(selectedValue)))
        toolTip = "左右拖动连续调整大小，圆形预览随当前尺寸变化；也可用方向键调整"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 100),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animation?.invalidate() }

    func nodeCenter(at position: CGFloat) -> CGPoint {
        CGPoint(x: 14 + position / CGFloat(values.count - 1) * (bounds.width - 28), y: bounds.midY)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = trackWidth
        path.lineCapStyle = .round
        path.move(to: nodeCenter(at: 0))
        path.line(to: nodeCenter(at: CGFloat(values.count - 1)))
        NSColor.secondaryLabelColor.withAlphaComponent(0.28).setStroke()
        path.stroke()
        let circle = NSBezierPath(ovalIn: previewFrame)
        // The opaque fill covers the rail, so the preview reads as a brush,
        // rather than a ring moving over a row of preset sizes.
        if sampleStyle == .ink {
            inkColor.setFill()
            circle.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            let cell = max(1.5, mosaicCellSize)
            let colors = [NSColor(calibratedWhite: 0.90, alpha: 1),
                          NSColor(calibratedWhite: 0.46, alpha: 1),
                          NSColor(calibratedWhite: 0.68, alpha: 1)]
            for row in 0...Int(ceil(previewDiameter / cell)) {
                for column in 0...Int(ceil(previewDiameter / cell)) {
                    colors[(row * 2 + column) % colors.count].setFill()
                    CGRect(x: previewFrame.minX + CGFloat(column) * cell,
                        y: previewFrame.minY + CGFloat(row) * cell,
                        width: cell, height: cell).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.white.withAlphaComponent(isDragging ? 0.85 : 0.4).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if window?.firstResponder === self && !isDragging {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 7, yRadius: 7)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        update(with: event, animated: true)
    }

    override func mouseDragged(with event: NSEvent) { update(with: event, animated: false) }

    override func mouseUp(with event: NSEvent) {
        if abs(position(for: event) - selectedPosition) > 0.001 {
            update(with: event, animated: false)
        }
        isDragging = false
        needsDisplay = true
    }

    private func position(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return max(0, min(CGFloat(values.count - 1),
            (point.x - 14) / max(1, bounds.width - 28) * CGFloat(values.count - 1)))
    }

    private func update(with event: NSEvent, animated: Bool) {
        let position = position(for: event)
        select(position: position)
        moveIndicator(to: position, animated: animated)
    }

    private func select(position: CGFloat) {
        let next = max(0, min(CGFloat(values.count - 1), position))
        guard next != selectedPosition else { return }
        selectedPosition = next
        setAccessibilityValue(NSNumber(value: Double(selectedValue)))
        _ = sendAction(action, to: target)
        needsDisplay = true
    }

    private func moveIndicator(to position: CGFloat, animated: Bool) {
        animation?.invalidate()
        animation = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(displayedPosition - position) > 0.01 else {
            displayedPosition = position
            needsDisplay = true
            return
        }
        let start = displayedPosition
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.18)
            let eased = progress * progress * (3 - 2 * progress)
            self.displayedPosition = start + (position - start) * eased
            self.needsDisplay = true
            if progress == 1 { timer.invalidate(); self.animation = nil }
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: step(by: -1)
        case 124, 126: step(by: 1)
        case 115: step(by: -values.count)
        case 119: step(by: values.count)
        default: super.keyDown(with: event)
        }
    }

    private func step(by delta: Int) {
        let next = delta > 0 ? floor(selectedPosition + 0.001) + CGFloat(delta)
            : ceil(selectedPosition - 0.001) + CGFloat(delta)
        select(position: next)
        moveIndicator(to: selectedPosition, animated: true)
    }

    override func accessibilityPerformIncrement() -> Bool { step(by: 1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(by: -1); return true }
}
