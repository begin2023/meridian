import AppKit

// MARK: - 模块协议

// 每个模块 = 一个菜单栏 widget + 一个点击弹出的详情面板。
// 协议为后续新增模块(电池/传感器/GPU 等)和工具包整合预留。
// 线程约定:UI 只在主线程更新;采样在各自的 sampleQueue 上执行。
protocol MonitorModule: AnyObject {
    var id: String { get }
    var displayName: String { get }

    func start()
    func stop()

    /// 设置变化后调用:重新读取开关/样式/间隔并即时生效。
    func rebuild()

    /// 只读快照，供统一 Shell 绘制 widget/详情；不暴露内部对象。
    func readOnlySummary() -> [String: Any]
}

// MARK: - Widget 内容快照

/// 模块每轮采样后产出的菜单栏渲染素材。
/// 文本样式用 text/secondaryText,条形样式用 fraction,图表样式用 history。
struct WidgetContent {
    var iconSymbol: String?
    var text: String = ""
    var secondaryText: String?
    var fraction: Double = 0
    var secondaryFraction: Double?
    var history: [Double] = []
    var secondaryHistory: [Double]?
    /// 图表样式的固定纵轴上限(百分比类模块传 100);nil 时按可见数据自适应。
    var graphMax: Double?
}

// MARK: - 模块基类

class BaseModule: NSObject, MonitorModule {
    let id: String
    let displayName: String

    let settings = AppSettings.shared
    private(set) var statusItem: NSStatusItem?
    private var popup: PopupPanelController?
    private var timer: DispatchSourceTimer?
    private var lastInterval: Int = 0

    private let sampleQueue: DispatchQueue
    private let historyCapacity = 120
    private var lastWidgetSignature: String?
    var widgetsEnabled = true
    private(set) var hasSampled = false

    /// 子类实现:在后台采样队列执行一次采样。
    /// 采样差分状态只允许在采样队列访问;主线程仅消费快照。
    func sample() {}

    /// 子类实现:主线程,把最新快照刷到 widget 与弹窗。
    func applySnapshot() {}

    /// 子类实现:主线程,构建弹窗内容视图。
    func makePopupContentView() -> NSView { NSView() }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
        self.sampleQueue = DispatchQueue(label: "monitoringlab.sample.\(id)", qos: .utility)
        super.init()
    }

    // MARK: 生命周期

    func start() {
        guard settings.moduleEnabled(id) else { return }
        if widgetsEnabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage()
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(statusItemClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.toolTip = displayName
            }
            statusItem = item
        }
        lastInterval = settings.updateInterval
        scheduleTimer(interval: lastInterval)
        sampleQueue.async { [weak self] in self?.sample() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        closePopup()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func rebuild() {
        if settings.moduleEnabled(id) {
            if lastInterval != settings.updateInterval {
                scheduleTimer(interval: settings.updateInterval)
                lastInterval = settings.updateInterval
            }
            applySnapshot()
        } else {
            stop()
        }
        if !widgetsEnabled, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func setWidgetsEnabled(_ enabled: Bool) {
        guard widgetsEnabled != enabled else { return }
        widgetsEnabled = enabled
        if enabled {
            start()
        } else {
            closePopup()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    private func scheduleTimer(interval: Int) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: Double(interval), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sample()
            DispatchQueue.main.async { [weak self] in
                self?.hasSampled = true
                self?.applySnapshot()
            }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: 状态栏交互

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopup()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let preferences = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: "")
        preferences.target = AppDelegate.shared
        menu.addItem(preferences)
        if AppDelegate.shared?.allowsQuitAction == true {
            let quit = NSMenuItem(title: "退出 MonitoringLab", action: #selector(quitApp), keyEquivalent: "")
            quit.target = AppDelegate.shared
            menu.addItem(quit)
        }
        button.menu = menu
        button.performClick(nil)
        button.menu = nil
    }

    @objc private func openPreferences() {
        AppDelegate.shared?.requestShowPreferences()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 弹窗

    func togglePopup() {
        if popup?.isVisible == true {
            closePopup()
        } else {
            showPopup()
        }
    }

    func showPopup() {
        guard let button = statusItem?.button else { return }
        closePopup()
        let panel = PopupPanelController()
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.popup = nil
            self.popupDidClose()
        }
        panel.setContentView(makePopupContentView())
        panel.show(anchoredTo: button, moduleID: id)
        popup = panel
        applySnapshot()
        popupDidOpen()
    }

    func showDetachedPopup() -> Bool {
        closePopup()
        let panel = PopupPanelController()
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.popup = nil
            self.popupDidClose()
        }
        panel.setContentView(makePopupContentView())
        panel.showCentered(moduleID: id)
        popup = panel
        applySnapshot()
        popupDidOpen()
        return true
    }

    func closePopup() {
        guard let panel = popup else { return }
        popup = nil
        panel.onClose = nil
        panel.close()
        popupDidClose()
    }

    var popupVisible: Bool { popup?.isVisible == true }

    /// 弹窗打开后回调,子类按需启动配套采样(如每进程网速)。
    func popupDidOpen() {}

    /// 弹窗关闭后回调(含点击面板外部导致的关闭),子类按需停止配套采样。
    func popupDidClose() {}

    // MARK: 工具

    /// 追加一个历史点并裁剪容量;只允许主线程调用。
    func appendHistory(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
    }

    func renderWidget(_ content: WidgetContent) {
        guard widgetsEnabled, let button = statusItem?.button else { return }
        let style = settings.widgetStyle(for: id)
        // 内容未变化时跳过重绘:文本样式看文本,条形看比例,图表看最近几个点。
        var signature = "\(id)|\(style.rawValue)|\(content.iconSymbol ?? "")|\(content.text)|\(content.secondaryText ?? "")"
        switch style {
        case .text:
            break
        case .bar:
            signature += "|\(String(format: "%.3f", content.fraction))"
        case .graph:
            signature += "|" + content.history.suffix(3).map { String(format: "%.1f", $0) }.joined(separator: ",")
        }
        guard signature != lastWidgetSignature else { return }
        lastWidgetSignature = signature
        button.image = StatusBarWidgetRenderer.image(for: content, style: style)
    }

    func readOnlySummary() -> [String: Any] {
        [
            "id": id,
            "displayName": displayName,
            "sampled": hasSampled,
            "enabled": settings.moduleEnabled(id),
            "widgetsEnabled": widgetsEnabled,
            "widgetVisible": statusItem?.isVisible == true,
            "detailVisible": popupVisible,
            "widgetStyle": settings.widgetStyle(for: id).id,
        ]
    }
}

// MARK: - 状态栏 Widget 渲染

// 菜单栏统一走模板图:黑色前景 + isTemplate,系统自动适配亮/暗菜单栏和高亮态。
enum StatusBarWidgetRenderer {
    static let imageHeight: CGFloat = 18

    static func image(for content: WidgetContent, style: WidgetStyle) -> NSImage {
        switch style {
        case .text:
            return textImage(for: content)
        case .bar:
            return barImage(for: content)
        case .graph:
            return graphImage(for: content)
        }
    }

    // MARK: 文本

    private static func textImage(for content: WidgetContent) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black.withAlphaComponent(0.55),
            .paragraphStyle: paragraph,
        ]

        enum Segment {
            case image(NSImage, CGFloat)
            case text(NSAttributedString, CGFloat)
        }

        var segments: [Segment] = []
        var totalWidth: CGFloat = 0
        if let symbolName = content.iconSymbol,
           let symbol = symbolImage(named: symbolName, size: 12) {
            segments.append(.image(symbol, symbol.size.width + 3))
            totalWidth += symbol.size.width + 3
        }
        let primary = NSAttributedString(string: content.text, attributes: primaryAttributes)
        let primaryWidth = primary.size().width
        segments.append(.text(primary, primaryWidth))
        totalWidth += primaryWidth
        if let secondaryText = content.secondaryText {
            let secondary = NSAttributedString(string: secondaryText, attributes: secondaryAttributes)
            let secondaryWidth = secondary.size().width
            segments.append(.text(secondary, secondaryWidth + 6))
            totalWidth += secondaryWidth + 6
        }

        let width = ceil(totalWidth) + 2
        return drawImage(width: width) { size in
            var x: CGFloat = 1
            for segment in segments {
                switch segment {
                case .image(let symbol, let segmentWidth):
                    symbol.draw(
                        in: NSRect(x: x, y: (size.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                    x += segmentWidth
                case .text(let string, let segmentWidth):
                    let lineHeight = string.size().height
                    string.draw(
                        at: NSPoint(x: x, y: (size.height - lineHeight) / 2 - 0.5)
                    )
                    x += segmentWidth
                }
            }
        }
    }

    private static func symbolImage(named name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol
    }

    // MARK: 条形

    private static func barImage(for content: WidgetContent) -> NSImage {
        let barWidth: CGFloat = 46
        let barHeight: CGFloat = 5
        let gap: CGFloat = 4

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        let text = NSAttributedString(string: content.text, attributes: textAttributes)
        let textSize = text.size()

        let iconWidth: CGFloat
        if let symbolName = content.iconSymbol, let symbol = symbolImage(named: symbolName, size: 12) {
            iconWidth = symbol.size.width + 4
        } else {
            iconWidth = 0
        }

        let width = ceil(iconWidth + barWidth + gap + textSize.width) + 2
        return drawImage(width: width) { size in
            var x: CGFloat = 1
            if let symbolName = content.iconSymbol, let symbol = symbolImage(named: symbolName, size: 12) {
                symbol.draw(
                    in: NSRect(x: x, y: (size.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += symbol.size.width + 4
            }

            let barY = (size.height - barHeight) / 2
            let track = NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barWidth, height: barHeight), xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.black.withAlphaComponent(0.22).setFill()
            track.fill()

            let fill = min(max(content.fraction, 0), 1)
            if fill > 0.01 {
                let fillRect = NSRect(x: x, y: barY, width: max(barWidth * CGFloat(fill), barHeight), height: barHeight)
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
                NSColor.black.setFill()
                fillPath.fill()
            }
            x += barWidth + gap

            text.draw(at: NSPoint(x: x, y: (size.height - textSize.height) / 2 - 0.5))
        }
    }

    // MARK: 图表

    private static func graphImage(for content: WidgetContent) -> NSImage {
        let graphWidth: CGFloat = 40
        let gap: CGFloat = 5

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        let text = NSAttributedString(string: content.text, attributes: textAttributes)
        let textSize = text.size()

        let width = ceil(graphWidth + gap + textSize.width) + 2
        return drawImage(width: width) { size in
            let rect = NSRect(x: 1, y: (size.height - imageHeight) / 2, width: graphWidth, height: imageHeight)
            drawGraph(content.history, in: rect, alpha: 1, fixedMax: content.graphMax)
            if let secondary = content.secondaryHistory {
                drawGraph(secondary, in: rect, alpha: 0.55, fixedMax: content.graphMax)
            }
            text.draw(at: NSPoint(x: rect.maxX + gap, y: (size.height - textSize.height) / 2 - 0.5))
        }
    }

    private static func drawGraph(_ values: [Double], in rect: NSRect, alpha: CGFloat, fixedMax: Double?) {
        guard values.count > 1 else { return }
        let recent = Array(values.suffix(24))
        let maxValue = max(fixedMax ?? recent.max() ?? 1, 0.0001)
        // 无论点数多少都铺满整条 mini 图,保证刚启动时也能看出走势
        let stepX = rect.width / CGFloat(recent.count - 1)

        func point(at index: Int) -> NSPoint {
            let fraction = CGFloat(min(recent[index] / maxValue, 1))
            return NSPoint(
                x: rect.minX + stepX * CGFloat(index),
                y: rect.minY + 1 + (rect.height - 2) * fraction
            )
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: rect.minX, y: rect.minY + 1))
        for index in recent.indices {
            fill.line(to: point(at: index))
        }
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY + 1))
        fill.close()
        NSColor.black.withAlphaComponent(0.20 * alpha).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.move(to: point(at: 0))
        for index in recent.indices.dropFirst() {
            line.line(to: point(at: index))
        }
        line.lineWidth = 1
        NSColor.black.withAlphaComponent(alpha).setStroke()
        line.stroke()
    }

    // MARK: 公共绘制

    private static func drawImage(width: CGFloat, draw: (NSSize) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let size = NSSize(width: width, height: imageHeight)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(imageHeight * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

// MARK: - 数值格式化

enum Format {
    // 内存使用 1024 进制（GB 标签对应 GiB）。
    static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        formatBytes(value, base: 1024, perSecond: perSecond)
    }

    // 磁盘与网络使用 1000 进制（GB = 10^9）。
    static func decimalBytes(_ value: Double, perSecond: Bool = false) -> String {
        formatBytes(value, base: 1000, perSecond: perSecond)
    }

    private static func formatBytes(_ value: Double, base: Double, perSecond: Bool) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var normalized = max(value, 0)
        var unitIndex = 0
        while normalized >= base, unitIndex < units.count - 1 {
            normalized /= base
            unitIndex += 1
        }
        let text: String
        if unitIndex == 0 {
            text = String(Int(normalized))
        } else if normalized >= 100 {
            text = String(format: "%.0f", normalized)
        } else if normalized >= 10 {
            text = String(format: "%.1f", normalized)
        } else {
            text = String(format: "%.2f", normalized)
        }
        return perSecond ? "\(text)\(units[unitIndex])/s" : "\(text)\(units[unitIndex])"
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", min(max(value, 0), 100))
    }
}

#if DEBUG
extension BaseModule {
    var debugStatusItem: NSStatusItem? { statusItem }
}
#endif
