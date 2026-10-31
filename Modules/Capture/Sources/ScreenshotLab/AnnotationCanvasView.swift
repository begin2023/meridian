import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum AnnotationTool: String, CaseIterable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case pen
    case highlighter
    case text
    case mosaic
    case blur
    case crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        case .blur: return "drop.half.filled"
        case .crop: return "crop"
        }
    }

    var label: String { self == .select ? "选择" : tooltip }

    var icon: NSImage? {
        guard self == .text || self == .blur else { return AppTheme.symbol(symbol, size: 17) }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if self == .text {
                let path = NSBezierPath()
                path.lineWidth = 1.8
                path.move(to: NSPoint(x: 3, y: 15))
                path.line(to: NSPoint(x: 3, y: 17))
                path.line(to: NSPoint(x: 17, y: 17))
                path.line(to: NSPoint(x: 17, y: 15))
                path.move(to: NSPoint(x: 10, y: 17))
                path.line(to: NSPoint(x: 10, y: 3))
                path.move(to: NSPoint(x: 6, y: 3))
                path.line(to: NSPoint(x: 14, y: 3))
                path.stroke()
            } else {
                for row in 0..<3 {
                    for column in 0..<3 {
                        NSColor.black.withAlphaComponent(column == 1 && row == 1 ? 0.95 : 0.35).setFill()
                        NSBezierPath(ovalIn: NSRect(x: CGFloat(2 + column * 6), y: CGFloat(2 + row * 6), width: 4, height: 4)).fill()
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var tooltip: String {
        switch self {
        case .select: return "选择与移动"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .crop: return "裁剪"
        }
    }

    var shortcut: String {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .pen: return "b"
        case .highlighter: return "h"
        case .text: return "t"
        case .mosaic: return "m"
        case .blur: return "u"
        case .crop: return "c"
        }
    }

    var instructions: String {
        switch self {
        case .select: return "点击选择标注，拖动移动 · Delete 删除 · Esc 取消选择，再按退出"
        case .text: return "点击图片添加文字 · 回车完成 · Esc 取消输入"
        case .crop: return "拖出保留区域后松开鼠标裁剪 · ⌘Z 撤销"
        case .mosaic: return "拖动笔刷调范围，点击纹理选颗粒 · 在图片上涂抹 · ⌘Z 撤销"
        case .blur: return "拖出矩形区域做高斯模糊，强度可选弱/中/强 · ⌘Z 撤销"
        default: return "在图片上拖动绘制\(tooltip) · Esc 返回选择工具，再按退出"
        }
    }
}

private enum AnnotationKind {
    case rectangle
    case ellipse
    case line
    case arrow
    case pen
    case highlighter
    case text
    case mosaic
    case blur
}

private struct Annotation {
    let id: UUID
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var text: String?
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var patch: CGImage?
    var blockSize: CGFloat = 12
    var arrowHeadSize: CGFloat = 24

    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter:
            guard let first = points.first else {
                return CGRect(origin: start, size: .zero)
            }
            var rect = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            return rect.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text:
            let estimatedWidth = max(40, CGFloat(text?.count ?? 1) * fontSize * 0.75)
            return CGRect(
                x: start.x,
                y: start.y - fontSize * 1.2,
                width: estimatedWidth,
                height: fontSize * 1.45
            )
        case .mosaic, .blur:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        default:
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ).insetBy(dx: -lineWidth, dy: -lineWidth)
        }
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        start.x += dx
        start.y += dy
        end.x += dx
        end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

private struct CanvasState {
    let image: CGImage
    var annotations: [Annotation]
}

private enum CanvasInteraction {
    case none
    case drawing
    case movingAnnotation
    case resizingAnnotation
}

private enum AnnotationResizeCorner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    var tool: AnnotationTool = .select {
        willSet {
            if newValue != tool { commitPendingTextIfNeeded() }
        }
        didSet {
            if tool != .select {
                selectedIndex = nil
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            refreshBrushCursor()
            onToolChanged?(tool)
        }
    }

    var strokeColor = NSColor.systemRed
    /// Style values are on-screen points; they are converted to image pixels
    /// with the current display scale when an annotation is built, so the
    /// toolbar preview always matches what gets painted.
    var strokeWidth: CGFloat = 4 { didSet { refreshBrushCursor() } }
    var textFontSize: CGFloat = 26
    var mosaicBrushSize: CGFloat = 40 { didSet { refreshBrushCursor() } }
    var mosaicBlockSize: CGFloat = 12
    var arrowHeadSize: CGFloat = 24
    var blurRadius: CGFloat = 18
    var onHistoryChanged: (() -> Void)?
    var onToolChanged: ((AnnotationTool) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Fired when Esc is pressed with nothing left to cancel (select tool,
    /// no selection, no draft) so the editor window can close.
    var onRequestExit: (() -> Void)?

    private(set) var image: CGImage
    private var annotations: [Annotation] = []
    private var undoStates: [CanvasState] = []
    private var redoStates: [CanvasState] = []
    private var selectedIndex: Int? {
        didSet { onSelectionChanged?() }
    }
    private var interaction = CanvasInteraction.none
    private var draftAnnotation: Annotation?
    private var dragStartImagePoint = CGPoint.zero
    private var initialAnnotation: Annotation?
    private var activeResizeCorner: AnnotationResizeCorner?
    private var textEditor: NSTextField?
    private var pendingTextStart = CGPoint.zero
    private var effectSource: CGImage?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var brushCursorOverlay: BrushCursorOverlay = {
        let overlay = BrushCursorOverlay()
        overlay.isHidden = true
        addSubview(overlay)
        return overlay
    }()
    private var brushCursorPoint: CGPoint?
    private var brushTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var hasSelection: Bool { selectedIndex != nil }
    var hasAnnotations: Bool { !annotations.isEmpty }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityLabel("截图标注画布")
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            calibratedWhite: 0.095,
            alpha: 1
        ).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair)
    }

    // MARK: Brush cursor (size-true preview under the mouse)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let brushTrackingArea {
            removeTrackingArea(brushTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        brushTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateBrushCursor(fromWindowPoint: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        updateBrushCursor(fromWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        hideBrushCursor()
    }

    private var brushCursorRadius: CGFloat? {
        switch tool {
        case .mosaic:
            return mosaicBrushSize / 2
        case .pen:
            return strokeWidth / 2
        case .highlighter:
            return strokeWidth * 4.5 / 2
        default:
            return nil
        }
    }

    private func updateBrushCursor(fromWindowPoint windowPoint: CGPoint) {
        guard let radius = brushCursorRadius else {
            hideBrushCursor()
            return
        }
        let point = convert(windowPoint, from: nil)
        guard imageDisplayRect().insetBy(dx: -radius, dy: -radius).contains(point) else {
            hideBrushCursor()
            return
        }
        brushCursorPoint = point
        placeBrushCursor()
    }

    private func refreshBrushCursor() {
        guard brushCursorPoint != nil else { return }
        if brushCursorRadius == nil {
            hideBrushCursor()
        } else {
            placeBrushCursor()
        }
    }

    private func placeBrushCursor() {
        guard let point = brushCursorPoint, let radius = brushCursorRadius else {
            hideBrushCursor()
            return
        }
        let overlay = brushCursorOverlay
        overlay.radius = radius
        let diameter = radius * 2 + 8
        overlay.frame = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        overlay.isHidden = false
    }

    private func hideBrushCursor() {
        brushCursorPoint = nil
        brushCursorOverlay.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = imagePoint(fromViewPoint: point) else {
            return
        }

        window?.makeFirstResponder(self)
        dragStartImagePoint = imagePoint

        if tool == .select {
            if let selectedIndex,
               let corner = resizeCorner(
                   for: annotations[selectedIndex],
                   near: imagePoint
               ) {
                initialAnnotation = annotations[selectedIndex]
                activeResizeCorner = corner
                interaction = .resizingAnnotation
                return
            }
            if let index = hitTest(imagePoint: imagePoint) {
                selectedIndex = index
                initialAnnotation = annotations[index]
                interaction = .movingAnnotation
            } else {
                selectedIndex = nil
                interaction = .none
            }
            needsDisplay = true
            return
        }

        if tool == .crop {
            interaction = .drawing
            draftAnnotation = makeDraftAnnotation(start: imagePoint, end: imagePoint)
            needsDisplay = true
            return
        }

        if tool == .text {
            beginTextEntry(at: imagePoint)
            return
        }

        interaction = .drawing
        draftAnnotation = makeDraftAnnotation(start: imagePoint, end: imagePoint)
        if tool == .pen || tool == .highlighter || tool == .mosaic {
            draftAnnotation?.points = [imagePoint]
        }
        if tool == .mosaic || tool == .blur {
            effectSource = renderFinalImage()
        }
        if tool == .mosaic {
            draftAnnotation?.lineWidth = mosaicBrushSize / displayScale
            draftAnnotation?.blockSize = mosaicBlockSize
            updateMosaicDraft()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateBrushCursor(fromWindowPoint: event.locationInWindow)
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = clampedImagePoint(fromViewPoint: point) else {
            return
        }

        switch interaction {
        case .drawing:
            if tool == .pen || tool == .highlighter || tool == .mosaic {
                draftAnnotation?.points.append(imagePoint)
                draftAnnotation?.end = imagePoint
            } else {
                draftAnnotation?.end = imagePoint
            }
            if tool == .mosaic { updateMosaicDraft() }
            needsDisplay = true
        case .movingAnnotation:
            guard let selectedIndex, let initialAnnotation else {
                return
            }
            let dx = imagePoint.x - dragStartImagePoint.x
            let dy = imagePoint.y - dragStartImagePoint.y
            var moved = initialAnnotation
            moved.offset(dx: dx, dy: dy)
            annotations[selectedIndex] = moved
            needsDisplay = true
        case .resizingAnnotation:
            guard let selectedIndex, let initialAnnotation, let activeResizeCorner else {
                return
            }
            let initialBounds = initialAnnotation.bounds
            var minX = initialBounds.minX
            var maxX = initialBounds.maxX
            var minY = initialBounds.minY
            var maxY = initialBounds.maxY

            switch activeResizeCorner {
            case .topLeft:
                minX = imagePoint.x
                maxY = imagePoint.y
            case .topRight:
                maxX = imagePoint.x
                maxY = imagePoint.y
            case .bottomLeft:
                minX = imagePoint.x
                minY = imagePoint.y
            case .bottomRight:
                maxX = imagePoint.x
                minY = imagePoint.y
            }

            let newBounds = CGRect(
                x: min(minX, maxX),
                y: min(minY, maxY),
                width: max(8, abs(maxX - minX)),
                height: max(8, abs(maxY - minY))
            )
            annotations[selectedIndex] = scaled(
                initialAnnotation,
                from: initialBounds,
                to: newBounds
            )
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if interaction == .drawing {
            mouseDragged(with: event)
        }
        switch interaction {
        case .drawing:
            guard var draft = draftAnnotation else {
                interaction = .none
                return
            }
            if tool == .crop {
                performCrop(rect: normalizedRect(start: draft.start, end: draft.end))
            } else if tool == .mosaic {
                if draft.patch != nil {
                    pushUndo()
                    annotations.append(draft)
                    notifyHistoryChanged()
                }
            } else if tool == .blur {
                let rect = normalizedRect(start: draft.start, end: draft.end)
                if rect.width >= 3, rect.height >= 3 {
                    if let patch = makePatch(for: rect, kind: draft.kind, source: effectSource) {
                        pushUndo()
                        draft.patch = patch
                        draft.start = rect.origin
                        draft.end = CGPoint(x: rect.maxX, y: rect.maxY)
                        annotations.append(draft)
                        notifyHistoryChanged()
                    }
                }
            } else if annotationIsMeaningful(draft) {
                pushUndo()
                annotations.append(draft)
                notifyHistoryChanged()
            }
        case .movingAnnotation:
            if let initialAnnotation,
               let selectedIndex,
               annotations[selectedIndex].bounds != initialAnnotation.bounds {
                var state = currentState
                state.annotations[selectedIndex] = initialAnnotation
                pushUndo(stateOverride: state)
                notifyHistoryChanged()
            }
        case .resizingAnnotation:
            guard let selectedIndex,
                  let initialAnnotation,
                  annotations[selectedIndex].bounds != initialAnnotation.bounds else {
                interaction = .none
                activeResizeCorner = nil
                needsDisplay = true
                return
            }
            var state = currentState
            state.annotations[selectedIndex] = initialAnnotation
            pushUndo(stateOverride: state)
            if annotations[selectedIndex].kind == .blur {
                let rect = normalizedRect(start: annotations[selectedIndex].start, end: annotations[selectedIndex].end)
                annotations[selectedIndex].patch = makePatch(
                    for: rect,
                    kind: annotations[selectedIndex].kind
                )
            }
            notifyHistoryChanged()
        case .none:
            break
        }

        interaction = .none
        draftAnnotation = nil
        initialAnnotation = nil
        activeResizeCorner = nil
        effectSource = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if event.modifierFlags.contains(.shift) {
                    redo()
                } else {
                    undo()
                }
                return
            case "y":
                redo()
                return
            default:
                break
            }
        }

        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }

        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let selectedTool = AnnotationTool.allCases.first(where: { $0.shortcut == key }) {
            tool = selectedTool
            return
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        let idle = tool == .select
            && selectedIndex == nil
            && interaction == .none
            && draftAnnotation == nil
            && initialAnnotation == nil
            && textEditor == nil
        if idle {
            // Nothing to cancel: Esc exits the editor instead.
            onRequestExit?()
            return
        }
        if let selectedIndex, let initialAnnotation {
            annotations[selectedIndex] = initialAnnotation
        }
        interaction = .none
        draftAnnotation = nil
        initialAnnotation = nil
        activeResizeCorner = nil
        effectSource = nil
        selectedIndex = nil
        tool = .select
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let displayRect = imageDisplayRect()
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.interpolationQuality = .high
        context.draw(image, in: displayRect)

        for (index, annotation) in annotations.enumerated() {
            draw(
                annotation,
                displayRect: displayRect,
                selected: tool == .select && selectedIndex == index
            )
        }

        if let draftAnnotation {
            draw(draftAnnotation, displayRect: displayRect, selected: false)
        }

        let border = NSBezierPath(rect: displayRect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.16).setStroke()
        border.stroke()
    }

    func setColor(_ color: NSColor) {
        strokeColor = color
        guard let selectedIndex else {
            return
        }
        var updated = annotations[selectedIndex]
        guard updated.color != color else {
            return
        }
        pushUndo()
        updated.color = color
        annotations[selectedIndex] = updated
        notifyHistoryChanged()
        needsDisplay = true
    }

    func setLineWidth(_ width: CGFloat) {
        strokeWidth = width
        guard let selectedIndex else {
            return
        }
        var updated = annotations[selectedIndex]
        let lineWidth = width / displayScale
        guard updated.lineWidth != lineWidth else {
            return
        }
        pushUndo()
        updated.lineWidth = lineWidth
        annotations[selectedIndex] = updated
        notifyHistoryChanged()
        needsDisplay = true
    }

    func undo() {
        guard let previous = undoStates.popLast() else {
            NSSound.beep()
            return
        }
        redoStates.append(currentState)
        restore(previous)
        notifyHistoryChanged()
    }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    @objc func copy(_ sender: Any?) { onCopy?() }

    func redo() {
        guard let next = redoStates.popLast() else {
            NSSound.beep()
            return
        }
        undoStates.append(currentState)
        restore(next)
        notifyHistoryChanged()
    }

    func renderFinalImage() -> CGImage {
        commitPendingTextIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width,
            pixelsHigh: image.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return image
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(image, in: imageRect)
        for annotation in annotations {
            draw(annotation, displayRect: imageRect, selected: false)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage ?? image
    }

#if DEBUG
    func seedDemoAnnotations() {
        pushUndo()
        let rectangle = makeAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 135, y: 835),
            end: CGPoint(x: 865, y: 985),
            color: NSColor.systemBlue,
            lineWidth: 8
        )
        let arrow = makeAnnotation(
            kind: .arrow,
            start: CGPoint(x: 920, y: 860),
            end: CGPoint(x: 1240, y: 650),
            color: NSColor.systemOrange,
            lineWidth: 8
        )
        var text = makeAnnotation(
            kind: .text,
            start: CGPoint(x: 150, y: 360),
            end: CGPoint(x: 150, y: 360),
            color: NSColor.systemGreen,
            lineWidth: 4
        )
        text.text = "这是可二次编辑的文字标注"
        text.fontSize = 34

        let mosaicRect = CGRect(x: 150, y: 650, width: 620, height: 130)
        var mosaic = makeAnnotation(
            kind: .mosaic,
            start: mosaicRect.origin,
            end: CGPoint(x: mosaicRect.maxX, y: mosaicRect.maxY),
            color: NSColor.black,
            lineWidth: 4
        )
        mosaic.patch = makePatch(for: mosaicRect, kind: .mosaic)

        let ellipse = makeAnnotation(
            kind: .ellipse,
            start: CGPoint(x: 1000, y: 470),
            end: CGPoint(x: 1380, y: 660),
            color: NSColor.systemPurple,
            lineWidth: 6
        )
        let line = makeAnnotation(
            kind: .line,
            start: CGPoint(x: 1000, y: 1000),
            end: CGPoint(x: 1400, y: 820),
            color: NSColor.systemTeal,
            lineWidth: 6
        )
        let pen = makeAnnotation(
            kind: .pen,
            start: CGPoint(x: 960, y: 980),
            end: CGPoint(x: 1160, y: 930),
            color: NSColor.systemPink,
            lineWidth: 6,
            points: [
                CGPoint(x: 960, y: 980),
                CGPoint(x: 1010, y: 930),
                CGPoint(x: 1060, y: 980),
                CGPoint(x: 1110, y: 930),
                CGPoint(x: 1160, y: 980),
            ]
        )
        let highlighter = makeAnnotation(
            kind: .highlighter,
            start: CGPoint(x: 960, y: 760),
            end: CGPoint(x: 1400, y: 760),
            color: NSColor.systemYellow,
            lineWidth: 26,
            points: [
                CGPoint(x: 960, y: 760),
                CGPoint(x: 1400, y: 760),
            ]
        )
        let blurRect = CGRect(x: 150, y: 585, width: 520, height: 70)
        var blur = makeAnnotation(
            kind: .blur,
            start: blurRect.origin,
            end: CGPoint(x: blurRect.maxX, y: blurRect.maxY),
            color: NSColor.black,
            lineWidth: 2
        )
        blur.patch = makePatch(for: blurRect, kind: .blur)

        annotations = [
            mosaic, arrow, rectangle, text,
            ellipse, line, pen, highlighter, blur,
        ]
        notifyHistoryChanged()
        needsDisplay = true
    }

    /// Applies a crop without a mouse drag and returns the new pixel size.
    func demoCropSize(rect: CGRect) -> CGSize {
        performCrop(rect: rect)
        return CGSize(width: image.width, height: image.height)
    }
#endif

    private var currentState: CanvasState {
        CanvasState(image: image, annotations: annotations)
    }

    private func restore(_ state: CanvasState) {
        image = state.image
        annotations = state.annotations
        selectedIndex = nil
        needsDisplay = true
    }

    private func pushUndo(stateOverride: CanvasState? = nil) {
        undoStates.append(stateOverride ?? currentState)
        if undoStates.count > 40 {
            undoStates.removeFirst(undoStates.count - 40)
        }
        redoStates.removeAll()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?()
    }

    private func makeDraftAnnotation(start: CGPoint, end: CGPoint) -> Annotation {
        let kind: AnnotationKind
        switch tool {
        case .rectangle, .crop: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .line: kind = .line
        case .arrow: kind = .arrow
        case .pen: kind = .pen
        case .highlighter: kind = .highlighter
        case .text: kind = .text
        case .mosaic: kind = .mosaic
        case .blur: kind = .blur
        case .select: kind = .rectangle
        }
        return Annotation(
            id: UUID(),
            kind: kind,
            start: start,
            end: end,
            points: [],
            text: nil,
            color: strokeColor,
            lineWidth: strokeWidth / displayScale,
            fontSize: textFontSize / displayScale,
            patch: nil,
            arrowHeadSize: arrowHeadSize / displayScale
        )
    }

    private func makeAnnotation(
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        color: NSColor,
        lineWidth: CGFloat,
        points: [CGPoint] = []
    ) -> Annotation {
        Annotation(
            id: UUID(),
            kind: kind,
            start: start,
            end: end,
            points: points,
            text: nil,
            color: color,
            lineWidth: lineWidth,
            fontSize: 26,
            patch: nil
        )
    }

    private func annotationIsMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .pen, .highlighter:
            return annotation.points.count > 1
        case .text:
            return !(annotation.text?.isEmpty ?? true)
        default:
            return abs(annotation.end.x - annotation.start.x) >= 2
                || abs(annotation.end.y - annotation.start.y) >= 2
        }
    }

    private func draw(
        _ annotation: Annotation,
        displayRect: CGRect,
        selected: Bool
    ) {
        let transform = AnnotationTransform(displayRect: displayRect, image: image)
        let lineWidth = max(1, annotation.lineWidth * transform.scale)
        annotation.color.setStroke()
        annotation.color.setFill()

        switch annotation.kind {
        case .rectangle:
            let rect = transform.rect(from: normalizedRect(start: annotation.start, end: annotation.end))
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .ellipse:
            let rect = transform.rect(from: normalizedRect(start: annotation.start, end: annotation.end))
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: transform.point(annotation.start))
            path.line(to: transform.point(annotation.end))
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()
        case .arrow:
            drawArrow(annotation, transform: transform, lineWidth: lineWidth)
        case .pen, .highlighter:
            guard annotation.points.count > 1 else {
                return
            }
            let path = NSBezierPath()
            path.move(to: transform.point(annotation.points[0]))
            for point in annotation.points.dropFirst() {
                path.line(to: transform.point(point))
            }
            path.lineWidth = annotation.kind == .highlighter
                ? max(4, lineWidth * 4.5)
                : lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if annotation.kind == .highlighter {
                annotation.color.withAlphaComponent(0.34).setStroke()
            }
            path.stroke()
        case .text:
            guard let text = annotation.text, !text.isEmpty else {
                return
            }
            let fontSize = max(9, annotation.fontSize * transform.scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: annotation.color,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let origin = transform.point(annotation.start)
            string.draw(
                at: CGPoint(
                    x: origin.x,
                    y: origin.y - string.size().height
                )
            )
        case .mosaic, .blur:
            if let patch = annotation.patch {
                let rect = transform.rect(
                    from: normalizedRect(start: annotation.start, end: annotation.end)
                )
                if let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    if annotation.kind == .mosaic, let first = annotation.points.first {
                        let diameter = annotation.lineWidth * transform.scale
                        let path = CGMutablePath()
                        path.move(to: transform.point(first))
                        for point in annotation.points.dropFirst() { path.addLine(to: transform.point(point)) }
                        if annotation.points.contains(where: { $0 != first }) {
                            context.addPath(path.copy(strokingWithWidth: diameter, lineCap: .round, lineJoin: .round, miterLimit: 10))
                        } else {
                            context.addEllipse(in: CGRect(x: transform.point(first).x - diameter / 2,
                                                         y: transform.point(first).y - diameter / 2,
                                                         width: diameter, height: diameter))
                        }
                        context.clip()
                    }
                    context.interpolationQuality = .none
                    context.draw(patch, in: rect)
                    context.restoreGState()
                }
            }
        }

        if selected {
            let selectionRect = transform.rect(from: annotation.bounds.insetBy(dx: -5, dy: -5))
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 1.2
            path.setLineDash([5, 3], count: 2, phase: 0)
            AppTheme.accent.setStroke()
            path.stroke()

            for corner in resizeHandlePoints(for: annotation.bounds) {
                let handleRect = CGRect(
                    x: corner.x - 3.5,
                    y: corner.y - 3.5,
                    width: 7,
                    height: 7
                )
                let handle = NSBezierPath(ovalIn: handleRect)
                NSColor.white.setFill()
                handle.fill()
                AppTheme.accent.setStroke()
                handle.lineWidth = 1
                handle.stroke()
            }
        }
    }

    private func drawArrow(
        _ annotation: Annotation,
        transform: AnnotationTransform,
        lineWidth: CGFloat
    ) {
        let start = transform.point(annotation.start)
        let end = transform.point(annotation.end)
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(lineWidth * 2, annotation.arrowHeadSize * transform.scale)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: p1)
        head.move(to: end)
        head.line(to: p2)
        head.lineWidth = lineWidth
        head.lineCapStyle = .round
        head.stroke()
    }

    private func hitTest(imagePoint: CGPoint) -> Int? {
        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            switch annotation.kind {
            case .line, .arrow:
                if distance(
                    from: imagePoint,
                    toSegmentFrom: annotation.start,
                    to: annotation.end
                ) <= max(8, annotation.lineWidth * 2) {
                    return index
                }
            case .pen, .highlighter:
                if annotation.points.count > 1 {
                    for pair in zip(annotation.points, annotation.points.dropFirst()) {
                        if distance(from: imagePoint, toSegmentFrom: pair.0, to: pair.1)
                            <= max(8, annotation.lineWidth * 2) {
                            return index
                        }
                    }
                }
            default:
                if annotation.bounds.insetBy(dx: -4, dy: -4).contains(imagePoint) {
                    return index
                }
            }
        }
        return nil
    }

    private func resizeCorner(
        for annotation: Annotation,
        near point: CGPoint
    ) -> AnnotationResizeCorner? {
        let threshold = 12 / max(0.1, imageDisplayRect().width / CGFloat(image.width))
        let bounds = annotation.bounds
        let candidates: [(AnnotationResizeCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.topRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.minY)),
        ]
        return candidates.first {
            hypot($0.1.x - point.x, $0.1.y - point.y) <= threshold
        }?.0
    }

    private func resizeHandlePoints(for bounds: CGRect) -> [CGPoint] {
        let transform = AnnotationTransform(
            displayRect: imageDisplayRect(),
            image: image
        )
        return [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ].map(transform.point)
    }

    private func scaled(
        _ annotation: Annotation,
        from source: CGRect,
        to destination: CGRect
    ) -> Annotation {
        let scaleX = source.width > 0.5 ? destination.width / source.width : 1
        let scaleY = source.height > 0.5 ? destination.height / source.height : 1

        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: destination.minX + (point.x - source.minX) * scaleX,
                y: destination.minY + (point.y - source.minY) * scaleY
            )
        }

        var result = annotation
        result.start = map(annotation.start)
        result.end = map(annotation.end)
        result.points = annotation.points.map(map)
        if result.kind == .mosaic {
            result.lineWidth *= min(scaleX, scaleY)
        }
        if result.kind == .text {
            result.fontSize = max(8, annotation.fontSize * min(scaleX, scaleY))
        }
        return result
    }

    func deleteSelection() {
        guard let selectedIndex else {
            return
        }
        pushUndo()
        annotations.remove(at: selectedIndex)
        self.selectedIndex = nil
        notifyHistoryChanged()
        needsDisplay = true
    }

    func clearAll() {
        guard !annotations.isEmpty else {
            NSSound.beep()
            return
        }
        pushUndo()
        annotations.removeAll()
        selectedIndex = nil
        notifyHistoryChanged()
        needsDisplay = true
    }

    private func performCrop(rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4 else {
            return
        }
        let final = renderFinalImage()
        let cropRect = pixelRect(forImageRect: rect, imageSize: CGSize(
            width: final.width,
            height: final.height
        )).integral
        guard let cropped = final.cropping(to: cropRect) else {
            return
        }

        pushUndo()
        image = cropped
        annotations.removeAll()
        selectedIndex = nil
        notifyHistoryChanged()
        needsDisplay = true
    }

    private func updateMosaicDraft() {
        guard var draft = draftAnnotation, let first = draft.points.first else { return }
        let radius = draft.lineWidth / 2
        var rect = CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        for point in draft.points {
            rect = rect.union(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        draft.start = rect.origin
        draft.end = CGPoint(x: rect.maxX, y: rect.maxY)
        draft.patch = makePatch(for: rect, kind: .mosaic, source: effectSource, blockSize: draft.blockSize)
        draftAnnotation = draft
    }

    private func makePatch(for rect: CGRect, kind: AnnotationKind, source: CGImage? = nil, blockSize: CGFloat = 12) -> CGImage? {
        let source = source ?? image
        let pixelRect = pixelRect(
            forImageRect: rect,
            imageSize: CGSize(width: source.width, height: source.height)
        ).integral
        guard let crop = source.cropping(to: pixelRect) else {
            return nil
        }
        let input = CIImage(cgImage: crop)
        let output: CIImage?

        if kind == .mosaic {
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.scale = Float(blockSize)
            filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            output = filter.outputImage?.cropped(to: input.extent)
        } else {
            // The strength chip is in screen points; blur runs in image
            // pixels so the visual strength stays the same at any zoom.
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(4, blurRadius / displayScale))
            output = filter.outputImage?.cropped(to: input.extent)
        }

        guard let output else {
            return nil
        }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private func beginTextEntry(at imagePoint: CGPoint) {
        commitPendingTextIfNeeded()
        pendingTextStart = imagePoint

        let viewPoint = viewPoint(fromImagePoint: imagePoint)
        let field = NSTextField(
            frame: CGRect(
                x: min(viewPoint.x, bounds.maxX - 260),
                y: min(max(0, viewPoint.y), bounds.maxY - 34),
                width: 240,
                height: 32
            )
        )
        field.placeholderString = "输入文字，回车完成"
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.textColor = strokeColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineText)
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textEditor?.removeFromSuperview()
            textEditor = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === textEditor else {
            return
        }
        commitInlineText()
    }

    @objc private func commitInlineText() {
        guard let field = textEditor else {
            return
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        guard !text.isEmpty else {
            return
        }

        var annotation = makeDraftAnnotation(start: pendingTextStart, end: pendingTextStart)
        annotation.kind = .text
        annotation.text = text
        pushUndo()
        annotations.append(annotation)
        notifyHistoryChanged()
        needsDisplay = true
    }

    private func commitPendingTextIfNeeded() {
        if textEditor != nil {
            commitInlineText()
        }
    }

    private func imageDisplayRect() -> CGRect {
        let padding: CGFloat = 28
        let availableWidth = max(1, bounds.width - padding * 2)
        let availableHeight = max(1, bounds.height - padding * 2)
        let scale = min(
            availableWidth / CGFloat(image.width),
            availableHeight / CGFloat(image.height)
        )
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// View points per image pixel. Style values are screen points, so this
    /// is the bridge between the toolbar preview and the painted result.
    var displayScale: CGFloat {
        guard bounds.width > 1, bounds.height > 1 else { return 1 }
        let rect = imageDisplayRect()
        return max(0.05, rect.width / CGFloat(image.width))
    }

    private func imagePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let rect = imageDisplayRect()
        guard rect.contains(point) else {
            return nil
        }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * CGFloat(image.width),
            y: (point.y - rect.minY) / rect.height * CGFloat(image.height)
        )
    }

    private func clampedImagePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let rect = imageDisplayRect()
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return CGPoint(
            x: (x - rect.minX) / rect.width * CGFloat(image.width),
            y: (y - rect.minY) / rect.height * CGFloat(image.height)
        )
    }

    private func viewPoint(fromImagePoint point: CGPoint) -> CGPoint {
        let rect = imageDisplayRect()
        return CGPoint(
            x: rect.minX + point.x / CGFloat(image.width) * rect.width,
            y: rect.minY + point.y / CGFloat(image.height) * rect.height
        )
    }

    private func normalizedRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func pixelRect(forImageRect rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX,
            y: imageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard dx != 0 || dy != 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

private struct AnnotationTransform {
    let displayRect: CGRect
    let image: CGImage
    var scale: CGFloat {
        displayRect.width / CGFloat(image.width)
    }

    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: displayRect.minX + point.x * scale,
            y: displayRect.minY + point.y * scale
        )
    }

    func rect(from rect: CGRect) -> CGRect {
        CGRect(
            x: displayRect.minX + rect.minX * scale,
            y: displayRect.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

/// Size-true circle that follows the mouse for brush tools. The canvas keeps
/// it frame-positioned so mouse moves only redraw a tiny view.
private final class BrushCursorOverlay: NSView {
    var radius: CGFloat = 10 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(
            x: bounds.midX - radius,
            y: bounds.midY - radius,
            width: radius * 2,
            height: radius * 2
        )
        for (width, color) in [
            (3.0, NSColor.black.withAlphaComponent(0.35)),
            (1.2, NSColor.white.withAlphaComponent(0.95)),
        ] {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: rect)
        }
    }
}
