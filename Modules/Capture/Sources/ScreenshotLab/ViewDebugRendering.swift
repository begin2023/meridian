import AppKit

extension NSView {
    func writeDebugPNG(to url: URL) {
        layoutSubtreeIfNeeded()
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url)
    }
}
