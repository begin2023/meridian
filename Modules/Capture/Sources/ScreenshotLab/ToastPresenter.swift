import AppKit

final class ToastPresenter {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(
        _ message: String,
        duration: TimeInterval = 3,
        on screen: NSScreen? = nil
    ) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let targetScreen = screen ?? ScreenCaptureService.screenAtMouse()
        let label = NSTextField(labelWithString: message)
        label.font = AppTheme.font(ofSize: 15, weight: .semibold)
        label.textColor = AppTheme.primaryText
        label.alignment = .center
        let textSize = label.intrinsicContentSize
        let size = CGSize(
            width: min(targetScreen.visibleFrame.width - 32, max(200, textSize.width + 76)),
            height: 58
        )

        let visual = NSView(frame: CGRect(origin: .zero, size: size))
        visual.wantsLayer = true
        visual.layer?.backgroundColor = AppTheme.floatingSurface.cgColor
        visual.layer?.cornerRadius = 12
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.frame = CGRect(
            x: 48,
            y: (size.height - textSize.height) / 2,
            width: size.width - 64,
            height: textSize.height
        )
        visual.addSubview(label)
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(frame: CGRect(x: 18, y: 18, width: 22, height: 22))
        icon.image = AppTheme.symbol("info.circle.fill", size: 21)
        icon.contentTintColor = AppTheme.accent
        visual.addSubview(icon)

        let panel = NSPanel(
            contentRect: CGRect(
                x: targetScreen.visibleFrame.midX - size.width / 2,
                y: targetScreen.visibleFrame.maxY - size.height - 60,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = visual
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        let hide = DispatchWorkItem { [weak self, weak panel] in
            guard let panel else {
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                if self?.panel === panel {
                    self?.panel = nil
                }
            }
        }
        hideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
    }
}
