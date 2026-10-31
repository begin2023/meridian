import AppKit

extension NSView {
    /// Renders the view tree offscreen into a PNG; smoke tests use this to
    /// verify window layouts without user interaction.
    func writeDebugPNG(to path: String) {
        layoutSubtreeIfNeeded()
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            NSLog("DisplayLab: could not create bitmap for debug snapshot \(path)")
            return
        }
        cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            NSLog("DisplayLab: could not encode PNG for \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            NSLog("DisplayLab failed to write \(path): \(error.localizedDescription)")
        }
    }
}
