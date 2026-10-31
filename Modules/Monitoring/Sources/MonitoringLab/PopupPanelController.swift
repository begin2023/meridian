import AppKit

// 模块详情弹窗:非激活面板,锚定在状态栏图标下方,点击面板外部自动关闭。
final class PopupPanelController: NSPanel {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorWindow: NSWindow?

    /// 面板因任何原因关闭(主动 close 或点击外部)时回调一次。
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        worksWhenModal = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func setContentView(_ content: NSView) {
        let surface = FrostedBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        surface.autoresizingMask = [.width, .height]
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
        ])
        contentView = surface

        surface.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let width = max(320, ceil(fitting.width) + 28)
        let height = ceil(fitting.height) + 24
        setContentSize(NSSize(width: width, height: height))
    }

    func show(anchoredTo button: NSStatusBarButton, moduleID: String) {
        anchorWindow = button.window
        position(anchoredTo: button)
        orderFront(nil)
        installDismissMonitors()
    }

    /// Detached presentation for the embedded Agent, where no status item is
    /// created. Clicking outside still dismisses the non-activating panel.
    func showCentered(moduleID: String) {
        center()
        orderFront(nil)
        installDismissMonitors()
    }

    private func installDismissMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === self.anchorWindow || event.window === self { return event }
            DispatchQueue.main.async { self.close() }
            return event
        }
    }

    override func close() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        anchorWindow = nil
        let handler = onClose
        onClose = nil
        handler?()
        super.close()
    }

    private func position(anchoredTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        guard let contentView, let surface = contentView as? NSVisualEffectView else { return }
        surface.layoutSubtreeIfNeeded()

        let buttonFrame = buttonWindow.convertToScreen(button.bounds)
        let size = frame.size
        let visibleFrame = screen.visibleFrame

        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = visibleFrame.maxY - size.height - 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
