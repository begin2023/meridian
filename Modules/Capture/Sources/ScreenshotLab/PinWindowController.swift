import AppKit

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinImageView: NSView {
    let image: CGImage
    var onContextMenu: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var closeButton: HoverButton!
    private var resizeFlags = 0
    private var dragging = false
    private var dragStartFrame = CGRect.zero
    private var dragStartMouse = CGPoint.zero
    private var scrollRemainder: CGFloat = 0
    private var initialWindowFrame = CGRect.zero
    private var initialMouseLocation = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        buildCloseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(
            x: max(2, bounds.maxX - 28),
            y: max(2, bounds.maxY - 28),
            width: 21,
            height: 21
        )
    }

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

    override func resetCursorRects() {
        let threshold: CGFloat = 8
        addCursorRect(
            CGRect(x: 0, y: bounds.maxY - threshold, width: bounds.width, height: threshold),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(x: 0, y: 0, width: bounds.width, height: threshold),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(x: 0, y: 0, width: threshold, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(x: bounds.maxX - threshold, y: 0, width: threshold, height: bounds.height),
            cursor: .resizeLeftRight
        )
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onClose?()
            return
        }
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        resizeFlags = flagsForPoint(point)
        if resizeFlags != 0 {
            initialWindowFrame = window?.frame ?? .zero
            initialMouseLocation = screenLocation(of: event)
        } else {
            // Manual drag: mouseDragged events are always delivered to a
            // non-activating panel, while the system performDrag session is
            // frequently dropped when another app is frontmost.
            dragging = true
            dragStartFrame = window?.frame ?? .zero
            dragStartMouse = screenLocation(of: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            return
        }
        if resizeFlags != 0 {
            applyResize(to: event)
            return
        }
        guard dragging else {
            return
        }
        let current = screenLocation(of: event)
        var frame = dragStartFrame
        frame.origin.x += current.x - dragStartMouse.x
        frame.origin.y += current.y - dragStartMouse.y
        window.setFrame(frame, display: true)
        window.invalidateCursorRects(for: self)
    }

    private func applyResize(to event: NSEvent) {
        guard let window else {
            return
        }
        let current = screenLocation(of: event)
        let dx = current.x - initialMouseLocation.x
        let dy = current.y - initialMouseLocation.y
        var frame = initialWindowFrame
        let minimumWidth: CGFloat = 100
        let minimumHeight: CGFloat = 80

        if resizeFlags & 1 != 0 {
            let newX = min(initialWindowFrame.minX + dx, initialWindowFrame.maxX - minimumWidth)
            frame.origin.x = newX
            frame.size.width = initialWindowFrame.maxX - newX
        }
        if resizeFlags & 2 != 0 {
            frame.size.width = max(minimumWidth, initialWindowFrame.width + dx)
        }
        if resizeFlags & 4 != 0 {
            let newY = min(initialWindowFrame.minY + dy, initialWindowFrame.maxY - minimumHeight)
            frame.origin.y = newY
            frame.size.height = initialWindowFrame.maxY - newY
        }
        if resizeFlags & 8 != 0 {
            frame.size.height = max(minimumHeight, initialWindowFrame.height + dy)
        }

        window.setFrame(frame, display: true)
    }

    /// Screen-space location of the event. Event-driven (not the global
    /// mouse position) so gestures also work in unit tests.
    private func screenLocation(of event: NSEvent) -> CGPoint {
        guard let window else {
            return NSEvent.mouseLocation
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        return window.convertToScreen(CGRect(origin: viewPoint, size: .zero)).origin
    }

    override func mouseUp(with event: NSEvent) {
        resizeFlags = 0
        dragging = false
        scrollRemainder = 0
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Inertia events keep firing after the fingers lift; honoring them
        // made zoom overshoot wildly. (NSEvent.Phase has no `.none` case —
        // an empty set means no momentum.)
        guard event.momentumPhase.isEmpty else {
            return
        }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else {
            return
        }
        // One gentle step per gesture: mouse notches fire once per step;
        // trackpad travel accumulates 20pt before stepping.
        let step: CGFloat = 1.1
        let factor: CGFloat
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += deltaY
            guard abs(scrollRemainder) >= 20 else {
                return
            }
            factor = scrollRemainder > 0 ? step : 1 / step
            scrollRemainder = 0
        } else {
            factor = deltaY > 0 ? step : 1 / step
        }
        onZoom?(factor, event.locationInWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            bounds.width / max(1, imageSize.width),
            bounds.height / max(1, imageSize.height)
        )
        let drawSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let drawRect = CGRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
    }

    private func buildCloseButton() {
        closeButton = HoverButton()
        closeButton.image = AppTheme.symbol("xmark", size: 10, weight: .bold)
        closeButton.normalBackground = NSColor.black.withAlphaComponent(0.58)
        closeButton.hoverBackground = NSColor.systemRed.withAlphaComponent(0.88)
        closeButton.contentTintColor = .white
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func flagsForPoint(_ point: CGPoint) -> Int {
        let threshold: CGFloat = 8
        var flags = 0
        if point.x <= threshold { flags |= 1 }
        if point.x >= bounds.maxX - threshold { flags |= 2 }
        if point.y <= threshold { flags |= 4 }
        if point.y >= bounds.maxY - threshold { flags |= 8 }
        return flags
    }
}

final class PinWindowController: NSWindowController, NSWindowDelegate {
    let image: CGImage
    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onQuickSave: ((CGImage) -> Void)?
    var onOCR: ((CGImage, CGRect?) -> Void)?
    var onEdit: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    private let imageView: PinImageView
    private var pinned = true

    init(
        image: CGImage,
        appearance: NSAppearance? = nil,
        anchor: CGRect? = nil
    ) {
        self.image = image
        imageView = PinImageView(image: image)

        let screen = ScreenCaptureService.screenAtMouse()
        // The image is in pixels; the window frame is in points. Without
        // dividing by the backing scale a Retina capture opens at double size.
        let pixelScale = max(1, screen.backingScaleFactor)
        let naturalWidth = CGFloat(image.width) / pixelScale
        let naturalHeight = CGFloat(image.height) / pixelScale

        let frame: CGRect
        if let anchor, anchor.width >= 1, anchor.height >= 1 {
            // Created from a capture: stay exactly at the selected region.
            frame = anchor
        } else {
            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let maxSize = CGSize(
                width: screen.visibleFrame.width * 0.58,
                height: screen.visibleFrame.height * 0.58
            )
            var width = naturalWidth
            var height = naturalHeight
            let fitScale = min(1, min(maxSize.width / width, maxSize.height / height))
            width *= fitScale
            height *= fitScale
            width = max(160, width)
            height = max(100, height)
            if width / height > imageAspect * 1.2 {
                width = height * imageAspect
            }

            let origin = CGPoint(
                x: NSEvent.mouseLocation.x + 24,
                y: NSEvent.mouseLocation.y - height - 24
            )
            frame = CGRect(
                x: origin.x,
                y: max(screen.visibleFrame.minY + 20, origin.y),
                width: width,
                height: height
            )
        }

        let panel = PinPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("ScreenshotLabPin")
        panel.contentView = imageView

        super.init(window: panel)
        panel.delegate = self
        imageView.onClose = { [weak self] in self?.closePin() }
        imageView.toolTip = "双击或按 Esc 关闭 · 拖动移动 · 滚轮缩放 · 拖动边缘调整大小"
        imageView.onContextMenu = { [weak self] event in
            self?.showContextMenu(event)
        }
        imageView.onZoom = { [weak self] factor, point in
            self?.zoom(by: factor, anchorInWindow: point)
        }
    }

    /// Scroll-wheel zoom that keeps the point under the cursor anchored.
    func zoom(by factor: CGFloat, anchorInWindow point: CGPoint) {
        guard let window, factor > 0 else {
            return
        }
        let oldFrame = window.frame
        guard oldFrame.width > 0, oldFrame.height > 0 else {
            return
        }

        let screen = window.screen ?? ScreenCaptureService.screenAtMouse()
        let maxWidth = screen.visibleFrame.width * 0.95
        let targetWidth = min(max(oldFrame.width * factor, 120), maxWidth)
        guard abs(targetWidth - oldFrame.width) > 0.5 else {
            return
        }

        let ratio = targetWidth / oldFrame.width
        let newSize = CGSize(
            width: targetWidth,
            height: oldFrame.height * ratio
        )
        let anchor = window.convertToScreen(
            CGRect(origin: point, size: .zero)
        ).origin

        var newFrame = CGRect(
            x: anchor.x - (anchor.x - oldFrame.minX) * ratio,
            y: anchor.y - (anchor.y - oldFrame.minY) * ratio,
            width: newSize.width,
            height: newSize.height
        )

        // Keep at least a strip of the pin reachable.
        let visible = screen.visibleFrame
        newFrame.origin.x = min(
            max(visible.minX - newSize.width + 80, newFrame.origin.x),
            visible.maxX - 80
        )
        newFrame.origin.y = min(
            max(visible.minY - newSize.height + 80, newFrame.origin.y),
            visible.maxY - 80
        )

        window.setFrame(newFrame, display: true)
        window.invalidateCursorRects(for: imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
#if DEBUG
        if CommandLine.arguments.contains("--demo-pin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.imageView.writeDebugPNG(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-pin.png")
                )
            }
        }
#endif
    }

    func showAgain() {
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func closePin() {
        close()
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("复制", action: #selector(copyAction)))
        menu.addItem(item("保存…", action: #selector(saveAction)))
        menu.addItem(item("快速保存", action: #selector(quickSaveAction)))
        menu.addItem(item("编辑标注", action: #selector(editAction)))
        menu.addItem(item("提取文字", action: #selector(ocrAction)))
        menu.addItem(.separator())

        let pinnedItem = item("始终置顶", action: #selector(togglePinned))
        pinnedItem.state = pinned ? .on : .off
        menu.addItem(pinnedItem)

        menu.addItem(.separator())
        menu.addItem(item("关闭", action: #selector(closeAction)))
        NSMenu.popUpContextMenu(menu, with: event, for: imageView)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func copyAction() {
        onCopy?(image)
    }

    @objc private func saveAction() {
        onSave?(image)
    }

    @objc private func quickSaveAction() {
        onQuickSave?(image)
    }

    @objc private func editAction() {
        onEdit?(image)
    }

    @objc private func ocrAction() {
        onOCR?(image, window?.frame)
    }

    @objc private func togglePinned() {
        pinned.toggle()
        window?.level = pinned ? .floating : .normal
    }

    @objc private func closeAction() {
        closePin()
    }
}
