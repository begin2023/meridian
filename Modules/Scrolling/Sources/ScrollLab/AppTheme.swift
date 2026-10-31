import AppKit

/// 模块间共享的主题约定，
/// 为将来合并为工具包做准备。
enum AppTheme {
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let face = weight >= .semibold ? "PingFangSC-Semibold"
            : weight >= .medium ? "PingFangSC-Medium" : "PingFangSC-Regular"
        return NSFont(name: face, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static let accent = NSColor(
        calibratedRed: 1.0,
        green: 0.67,
        blue: 0.24,
        alpha: 1
    )

    static let graphite = NSColor(
        calibratedRed: 0.09,
        green: 0.10,
        blue: 0.12,
        alpha: 0.94
    )

    static let panel = NSColor(
        calibratedRed: 0.13,
        green: 0.14,
        blue: 0.17,
        alpha: 0.96
    )

    static let subtleBorder = NSColor.white.withAlphaComponent(0.14)
    static let primaryText = NSColor.white.withAlphaComponent(0.96)
    static let secondaryText = NSColor.white.withAlphaComponent(0.76)

    static let floatingSurface = NSColor(calibratedWhite: 0.12, alpha: 1)

    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .medium) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

class HoverButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var hovering = false {
        didSet { updateAppearance() }
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
        layer?.borderColor = AppTheme.subtleBorder.cgColor
        layer?.backgroundColor = AppTheme.floatingSurface.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
