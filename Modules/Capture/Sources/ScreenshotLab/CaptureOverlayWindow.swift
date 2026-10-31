import AppKit

enum CaptureAction {
    case gif
    case edit
    case pin
    case copy
    case save
    case quickSave
    case ocr
}

final class CaptureActionBar: FrostedBarView {
    var onAction: ((CaptureAction) -> Void)?

    private let stack = NSStackView()

    func configureGIFMode() {
        for case let button as HoverButton in stack.arrangedSubviews {
            let isGIF = button.identifier?.rawValue == "\(CaptureAction.gif)"
            button.normalBackground = isGIF ? AppTheme.accent : .clear
            button.hoverBackground = isGIF ? AppTheme.accent : NSColor.white.withAlphaComponent(0.12)
            if isGIF { button.toolTip = "开始录制 GIF (Enter / G)" }
            if button.identifier?.rawValue == "\(CaptureAction.copy)" { button.toolTip = "复制 (C)" }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        addButton(symbol: "record.circle", tooltip: "录制 GIF (G)", action: .gif)
        addButton(symbol: "pencil.tip", tooltip: "编辑标注 (E)", action: .edit)
        addButton(symbol: "pin", tooltip: "钉在屏幕上 (P)", action: .pin)
        addButton(symbol: "text.viewfinder", tooltip: "提取文字 (O)", action: .ocr)
        addButton(symbol: "square.and.arrow.down", tooltip: "保存 (S)", action: .save)
        addButton(symbol: "doc.on.doc.fill", tooltip: "复制 (Enter)", action: .copy, accent: true)
    }

    private func addButton(
        symbol: String,
        tooltip: String,
        action: CaptureAction,
        accent: Bool = false
    ) {
        let button = HoverButton()
        button.image = AppTheme.symbol(symbol)
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier("\(action)")
        if accent {
            button.normalBackground = AppTheme.accent
            button.hoverBackground = AppTheme.accent.blended(
                withFraction: 0.12,
                of: .white
            ) ?? AppTheme.accent
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 31),
            button.heightAnchor.constraint(equalToConstant: 31),
        ])
        stack.addArrangedSubview(button)
        if accent, let first = stack.arrangedSubviews.first {
            stack.setCustomSpacing(8, after: first)
        }
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else {
            return
        }

        let action: CaptureAction?
        switch identifier {
        case "\(CaptureAction.gif)":
            action = .gif
        case "\(CaptureAction.edit)":
            action = .edit
        case "\(CaptureAction.pin)":
            action = .pin
        case "\(CaptureAction.copy)":
            action = .copy
        case "\(CaptureAction.save)":
            action = .save
        case "\(CaptureAction.ocr)":
            action = .ocr
        default:
            action = nil
        }

        if let action {
            onAction?(action)
        }
    }
}

final class CaptureOverlayView: NSView {
    private enum HitZone {
        case none
        case inside
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private enum DragMode: Equatable {
        case creating
        case moving
        case resizing
    }

    let snapshot: ScreenSnapshot
    private let forGIF: Bool
    var onAction: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    var autoAction: CaptureAction?
    var currentSelection: CGRect { selection }

    private let actionBar = CaptureActionBar()
    private var selection = CGRect.zero
    private var dragMode: DragMode?
    private var dragStart = CGPoint.zero
    private var initialSelection = CGRect.zero
    private var activeHitZone = HitZone.none
    private var mouseLocation: CGPoint = .zero
    private var showingActionBar = false
    private var lastColorPixel: (x: Int, y: Int)?
    private var lastPixelColor: NSColor?

    override var acceptsFirstResponder: Bool { true }

    init(snapshot: ScreenSnapshot, initialSelection: CGRect? = nil, forGIF: Bool = false) {
        self.snapshot = snapshot
        self.forGIF = forGIF
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))

        actionBar.translatesAutoresizingMaskIntoConstraints = true
        actionBar.onAction = { [weak self] action in
            self?.onAction?(action)
        }
        actionBar.isHidden = true
        if forGIF { actionBar.configureGIFMode() }
        addSubview(actionBar)

        if let initialSelection {
            selection = clamped(initialSelection.intersection(bounds))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        if !selection.isEmpty {
            revealActionBar()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if selection == .zero {
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStart = point
        mouseLocation = point

        let hitZone = hitZone(at: point)
        if hitZone == .none {
            selection = CGRect(origin: point, size: .zero)
            dragMode = .creating
            initialSelection = selection
            hideActionBar()
        } else if hitZone == .inside {
            dragMode = .moving
            initialSelection = selection
        } else {
            dragMode = .resizing
            initialSelection = selection
            activeHitZone = hitZone
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        mouseLocation = point

        switch dragMode {
        case .creating:
            selection = standardizedRect(from: dragStart, to: point)
        case .moving:
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            var moved = initialSelection.offsetBy(dx: dx, dy: dy)
            moved.origin.x = min(max(0, moved.origin.x), bounds.width - moved.width)
            moved.origin.y = min(max(0, moved.origin.y), bounds.height - moved.height)
            selection = moved
        case .resizing:
            selection = resizedRect(initialSelection, to: point, zone: activeHitZone)
        case .none:
            break
        }

        selection = clamped(selection.integral)
        if selection.width >= 2, selection.height >= 2 {
            showActionBar()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        activeHitZone = .none
        if selection.width < 2 || selection.height < 2 {
            selection = .zero
            hideActionBar()
        } else if let autoAction, !forGIF {
            // 一步式入口（截图识字/截图贴图）：松开鼠标即执行预设动作。
            needsDisplay = true
            onAction?(autoAction)
            return
        } else {
            updateActionBarPosition()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
            return
        case 36, 76:
            guard !selection.isEmpty else {
                NSSound.beep()
                return
            }
            onAction?(forGIF ? .gif : .copy)
            return
        default:
            break
        }

        guard !selection.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e":
            onAction?(.edit)
        case "g":
            onAction?(.gif)
        case "p":
            onAction?(.pin)
        case "c":
            onAction?(.copy)
        case "s":
            if event.modifierFlags.contains(.shift) {
                onAction?(.quickSave)
            } else {
                onAction?(.save)
            }
        case "o":
            onAction?(.ocr)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()

        let dim = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.42).setFill()
        dim.fill()
        context.restoreGState()

        if selection.isEmpty {
            drawCrosshair(at: mouseLocation)
            drawInstruction()
        } else {
            drawSelection()
        }
        drawMagnifier(at: mouseLocation)
    }

    private func drawSelection() {
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        AppTheme.accent.setStroke()
        border.stroke()

        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        NSColor.white.setStroke()
        NSBezierPath(rect: selection).stroke()
        NSGraphicsContext.restoreGraphicsState()

        for point in handleCenters(for: selection) {
            let handleRect = CGRect(
                x: point.x - 3.5,
                y: point.y - 3.5,
                width: 7,
                height: 7
            )
            let handle = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handle.fill()
            AppTheme.accent.setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }

        drawSizeBadge()
    }

    private func drawCrosshair(at point: CGPoint) {
        guard bounds.contains(point) else {
            return
        }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: point.x, y: 0))
        path.line(to: CGPoint(x: point.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: point.y))
        path.line(to: CGPoint(x: bounds.width, y: point.y))
        path.lineWidth = 1 / max(1, window?.backingScaleFactor ?? 1)
        NSColor.white.withAlphaComponent(0.34).setStroke()
        path.stroke()
    }

    private func drawInstruction() {
        let text = forGIF ? "拖动选择录制区域    Enter 开始 GIF    Esc 取消" : "拖动选择截图区域    Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppTheme.font(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let rect = CGRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.midY - size.height / 2 - 10,
            width: size.width + 32,
            height: size.height + 20
        )
        let pill = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.62).setFill()
        pill.fill()
        string.draw(
            at: CGPoint(
                x: rect.minX + 16,
                y: rect.midY - size.height / 2
            )
        )
    }

    private func drawMagnifier(at point: CGPoint) {
        guard bounds.contains(point), dragMode != .moving else {
            return
        }

        let size: CGFloat = 116
        var origin = CGPoint(x: point.x + 22, y: point.y + 22)
        if origin.x + size > bounds.maxX - 12 {
            origin.x = point.x - size - 22
        }
        if origin.y + size + 44 > bounds.maxY - 12 {
            origin.y = point.y - size - 44
        }
        origin.x = min(max(12, origin.x), bounds.maxX - size - 12)
        origin.y = min(max(12, origin.y), bounds.maxY - size - 56)

        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let background = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.82).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        background.lineWidth = 1
        background.stroke()

        let pixelX = min(
            snapshot.image.width - 1,
            max(0, Int(point.x / max(1, bounds.width) * CGFloat(snapshot.image.width)))
        )
        let pixelY = min(
            snapshot.image.height - 1,
            max(
                0,
                Int(
                    (1 - point.y / max(1, bounds.height))
                        * CGFloat(snapshot.image.height)
                )
            )
        )
        let sampleSize = 27
        let cropRect = CGRect(
            x: max(0, pixelX - sampleSize / 2),
            y: max(0, pixelY - sampleSize / 2),
            width: sampleSize,
            height: sampleSize
        ).integral
        if let crop = snapshot.image.cropping(to: cropRect) {
            let imageRect = frame.insetBy(dx: 8, dy: 8)
            let context = NSGraphicsContext.current?.cgContext
            context?.interpolationQuality = .none
            context?.draw(crop, in: imageRect)

            let horizontal = NSBezierPath()
            horizontal.move(to: CGPoint(x: imageRect.midX - 9, y: imageRect.midY))
            horizontal.line(to: CGPoint(x: imageRect.midX + 9, y: imageRect.midY))
            let vertical = NSBezierPath()
            vertical.move(to: CGPoint(x: imageRect.midX, y: imageRect.midY - 9))
            vertical.line(to: CGPoint(x: imageRect.midX, y: imageRect.midY + 9))
            for path in [horizontal, vertical] {
                path.lineWidth = 1
                AppTheme.accent.setStroke()
                path.stroke()
            }
        }

        let red: Int
        let green: Int
        let blue: Int
        if let color = colorAt(pixelX: pixelX, pixelY: pixelY)?
            .usingColorSpace(.sRGB) {
            red = Int((color.redComponent * 255).rounded())
            green = Int((color.greenComponent * 255).rounded())
            blue = Int((color.blueComponent * 255).rounded())
        } else {
            red = 0
            green = 0
            blue = 0
        }

        let label = String(
            format: "%d, %d   #%02X%02X%02X",
            pixelX,
            pixelY,
            red,
            green,
            blue
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        string.draw(
            at: CGPoint(
                x: frame.minX,
                y: frame.minY - string.size().height - 6
            )
        )
    }

    private func drawSizeBadge() {
        let pixelWidth = Int((selection.width * snapshot.scale).rounded())
        let pixelHeight = Int((selection.height * snapshot.scale).rounded())
        let text = "\(pixelWidth) × \(pixelHeight)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = CGPoint(
            x: selection.minX,
            y: selection.maxY + 7
        )
        if origin.y + size.height + 10 > bounds.maxY {
            origin.y = selection.maxY - size.height - 17
        }
        if origin.x + size.width + 14 > bounds.maxX {
            origin.x = bounds.maxX - size.width - 14
        }

        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: size.width + 14,
            height: size.height + 8
        )
        let badge = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        AppTheme.graphite.setFill()
        badge.fill()
        string.draw(
            at: CGPoint(
                x: rect.minX + 7,
                y: rect.minY + 4
            )
        )
    }

    private func showActionBar() {
        guard actionBar.isHidden else {
            updateActionBarPosition()
            return
        }
        actionBar.isHidden = false
        showingActionBar = true
        updateActionBarPosition()
    }

    func revealActionBar() {
        guard !selection.isEmpty else {
            return
        }
        showActionBar()
    }

    func writeDebugSnapshot(to url: URL) {
        // The screenshot itself is drawn by a sibling layer, so composite the
        // overlay bitmap over the original image for the debug artifact.
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        cacheDisplay(in: bounds, to: representation)
        guard let overlayImage = representation.cgImage,
              let context = CGContext(
                data: nil,
                width: snapshot.image.width,
                height: snapshot.image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return
        }
        let rect = CGRect(
            x: 0,
            y: 0,
            width: snapshot.image.width,
            height: snapshot.image.height
        )
        context.draw(snapshot.image, in: rect)
        context.draw(overlayImage, in: rect)
        guard let image = context.makeImage() else {
            return
        }
        try? ImageOutput.writePNG(image, to: url)
    }

    private func hideActionBar() {
        actionBar.isHidden = true
        showingActionBar = false
    }

    private func updateActionBarPosition() {
        guard showingActionBar else {
            return
        }
        let size = NSSize(width: 236, height: 43)
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: selection.minY - size.height - 10
        )
        if origin.y < 10 {
            origin.y = min(bounds.maxY - size.height - 10, selection.maxY + 10)
        }
        origin.x = min(max(10, origin.x), bounds.maxX - size.width - 10)
        actionBar.frame = CGRect(origin: origin, size: size)
    }

    private func hitZone(at point: CGPoint) -> HitZone {
        guard !selection.isEmpty else {
            return .none
        }

        let threshold: CGFloat = 8
        let nearLeft = abs(point.x - selection.minX) <= threshold
        let nearRight = abs(point.x - selection.maxX) <= threshold
        let nearTop = abs(point.y - selection.maxY) <= threshold
        let nearBottom = abs(point.y - selection.minY) <= threshold
        let withinX = point.x >= selection.minX - threshold
            && point.x <= selection.maxX + threshold
        let withinY = point.y >= selection.minY - threshold
            && point.y <= selection.maxY + threshold

        if withinX, withinY {
            if nearLeft, nearTop { return .topLeft }
            if nearRight, nearTop { return .topRight }
            if nearLeft, nearBottom { return .bottomLeft }
            if nearRight, nearBottom { return .bottomRight }
            if nearLeft { return .left }
            if nearRight { return .right }
            if nearTop { return .top }
            if nearBottom { return .bottom }
        }

        if selection.contains(point) {
            return .inside
        }
        return .none
    }

    private func resizedRect(_ rect: CGRect, to point: CGPoint, zone: HitZone) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch zone {
        case .left, .topLeft, .bottomLeft:
            minX = point.x
        case .right, .topRight, .bottomRight:
            maxX = point.x
        default:
            break
        }

        switch zone {
        case .top, .topLeft, .topRight:
            maxY = point.y
        case .bottom, .bottomLeft, .bottomRight:
            minY = point.y
        default:
            break
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    private func handleCenters(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    private func standardizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        let x = min(max(0, rect.minX), bounds.width)
        let y = min(max(0, rect.minY), bounds.height)
        let maxX = min(bounds.width, max(x, rect.maxX))
        let maxY = min(bounds.height, max(y, rect.maxY))
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), bounds.width),
            y: min(max(0, point.y), bounds.height)
        )
    }

    private func colorAt(pixelX: Int, pixelY: Int) -> NSColor? {
        if let lastColorPixel,
           lastColorPixel.x == pixelX,
           lastColorPixel.y == pixelY {
            return lastPixelColor
        }

        let cropRect = CGRect(x: pixelX, y: pixelY, width: 1, height: 1)
        guard let pixel = snapshot.image.cropping(to: cropRect) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else {
            return nil
        }
        let red = CGFloat(bytes[0]) / 255.0
        let green = CGFloat(bytes[1]) / 255.0
        let blue = CGFloat(bytes[2]) / 255.0
        let alpha = CGFloat(bytes[3]) / 255.0
        let color = NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )

        lastColorPixel = (pixelX, pixelY)
        lastPixelColor = color
        return color
    }

}

/// Shows the capture at its original resolution; the layer contents are
/// composited by the window server instead of being redrawn by CoreGraphics.
private final class OverlayBackgroundView: NSView {
    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }
}

final class CaptureOverlayWindow: NSWindow {
    let overlayView: CaptureOverlayView

    init(
        snapshot: ScreenSnapshot,
        initialSelection: CGRect? = nil,
        forGIF: Bool = false,
        autoAction: CaptureAction? = nil,
        onAction: @escaping (CaptureAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        overlayView = CaptureOverlayView(
            snapshot: snapshot,
            initialSelection: initialSelection,
            forGIF: forGIF
        )

        super.init(
            contentRect: snapshot.screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        title = forGIF ? "GIF 录制选区" : "区域截图"
        setAccessibilityTitle(title)

        overlayView.onAction = onAction
        overlayView.onCancel = onCancel
        overlayView.autoAction = autoAction
        let container = NSView(
            frame: CGRect(origin: .zero, size: snapshot.screenFrame.size)
        )
        let background = OverlayBackgroundView(image: snapshot.image)
        background.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        container.addSubview(overlayView)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: container.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        setFrame(snapshot.screenFrame, display: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = false
        // NSWindow defaults to true, which sends an extra release on close and
        // over-releases the ARC-owned window (crash after capture/OCR).
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
