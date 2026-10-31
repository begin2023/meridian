import AppKit

/// 语义色主题；由窗口/视图继承系统浅色、深色或宿主外观。
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

    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .medium) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
