import AppKit
import Carbon.HIToolbox

/// A keycap-style button that records an arbitrary key combination.
final class HotKeyRecorderButton: NSButton {
    var onChange: ((HotKeyChoice) -> Void)?

    private(set) var choice: HotKeyChoice?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func apply(_ choice: HotKeyChoice) {
        self.choice = choice
        isRecording = false
        title = choice.name
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancelRecording()
        } else {
            beginRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let modifiers = HotKeyChoice.carbonModifiers(from: event.modifierFlags)
        let hasRequiredModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRequiredModifier else {
            NSSound.beep()
            return
        }

        let recorded = HotKeyChoice(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
        isRecording = false
        choice = recorded
        title = recorded.name
        updateAppearance()
        window?.makeFirstResponder(nil)
        onChange?(recorded)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func configure() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        contentTintColor = .labelColor
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        updateAppearance()
    }

    private func beginRecording() {
        isRecording = true
        title = "按下快捷键…"
        window?.makeFirstResponder(self)
        updateAppearance()
    }

    private func cancelRecording() {
        isRecording = false
        title = choice?.name ?? "未设置"
        updateAppearance()
    }

    private func updateAppearance() {
        let background = isRecording
            ? AppTheme.accent.withAlphaComponent(0.16)
            : NSColor.textBackgroundColor
        let border = isRecording
            ? AppTheme.accent
            : NSColor.separatorColor
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.backgroundColor = background.cgColor
            self?.layer?.borderColor = border.cgColor
        }
    }
}
