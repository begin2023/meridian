import AppKit
import MeridianLocalization

final class GIFRecordingHUDController: NSWindowController {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let titleLabel = NSTextField(labelWithString: L("GIF 录制", "GIF Recording"))
    private let frameLabel = NSTextField(labelWithString: L("0 帧", "0 frames"))
    private let stopButton = HoverButton()
    private let cancelButton = HoverButton()

    convenience init() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 332, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.title = L("GIF 录制", "GIF Recording")
        panel.setAccessibilityTitle(panel.title)
        self.init(window: panel)
        buildInterface()
    }

    func show(on screen: NSScreen) {
        guard let window else {
            return
        }
        let frame = window.frame
        window.setFrameOrigin(
            CGPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + 22
            )
        )
        window.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval, frames: Int, capturedFrames: Int = 0) {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        timeLabel.stringValue = String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
        frameLabel.stringValue = L("\(frames) 帧", frames == 1 ? "1 frame" : "\(frames) frames")
    }

    func showFinishing(saving: Bool) {
        titleLabel.stringValue = saving ? L("正在保存 GIF…", "Saving GIF…") : L("正在取消…", "Canceling…")
        stopButton.isEnabled = false
        cancelButton.isEnabled = false
        stopButton.alphaValue = 0.4
        cancelButton.alphaValue = 0.4
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else {
            return
        }

        let background = FrostedBarView(frame: contentView.bounds)
        background.autoresizingMask = [.width, .height]
        background.layer?.cornerRadius = 15
        contentView.addSubview(background)

        let redDot = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        redDot.wantsLayer = true
        redDot.layer?.cornerRadius = 5
        redDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        redDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            redDot.widthAnchor.constraint(equalToConstant: 10),
            redDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        titleLabel.font = AppTheme.font(ofSize: 13, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = AppTheme.primaryText

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        frameLabel.textColor = AppTheme.secondaryText

        stopButton.image = AppTheme.symbol("stop.fill", size: 12, weight: .bold)
        stopButton.toolTip = L("停止并保存", "Stop and save")
        stopButton.normalBackground = NSColor.systemRed.withAlphaComponent(0.85)
        stopButton.hoverBackground = NSColor.systemRed
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.image = AppTheme.symbol("xmark", size: 11, weight: .bold)
        cancelButton.toolTip = L("取消录制", "Cancel recording")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stopButton.widthAnchor.constraint(equalToConstant: 31),
            stopButton.heightAnchor.constraint(equalToConstant: 31),
            cancelButton.widthAnchor.constraint(equalToConstant: 28),
            cancelButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let stack = NSStackView(views: [
            redDot,
            titleLabel,
            timeLabel,
            frameLabel,
            NSView(),
            cancelButton,
            stopButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
