import AppKit

enum AppTheme {
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let face = weight >= .semibold ? "PingFangSC-Semibold"
            : weight >= .medium ? "PingFangSC-Medium" : "PingFangSC-Regular"
        return NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static let accent = NSColor.controlAccentColor
    static let graphite = NSColor.windowBackgroundColor
    static let panel = NSColor.controlBackgroundColor
    static let subtleBorder = NSColor.separatorColor
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let floatingSurface = NSColor.controlBackgroundColor

    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .medium) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

class HoverButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var hovering = false {
        didSet {
            updateAppearance()
        }
    }

    var normalBackground = NSColor.clear {
        didSet { updateAppearance() }
    }

    var hoverBackground = NSColor.white.withAlphaComponent(0.12) {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        contentTintColor = AppTheme.primaryText
        focusRingType = .none
        updateAppearance()
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

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = (hovering ? hoverBackground : normalBackground).cgColor
    }
}

class FrostedBarView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.borderColor = AppTheme.subtleBorder.cgColor
        layer?.backgroundColor = AppTheme.floatingSurface.cgColor
    }
}
