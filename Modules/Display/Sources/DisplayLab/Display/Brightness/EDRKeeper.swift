import AppKit
import Metal
import QuartzCore

/// Keeps a display compositing in EDR mode so gamma-table values above 1.0
/// actually raise brightness (HDR brightness boost). A 4×4 pixel, nearly
/// transparent Metal layer holding extended-range content is enough: measured
/// on an HDR10 external panel (macOS 27.2) the current EDR headroom rises from
/// 1.0 to ~2 while it is on screen. Same idea as BetterDisplay's EDR enforcer
/// window. Main thread only.
final class EDRKeeper {
    static let shared = EDRKeeper()

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private lazy var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    func setActive(_ active: Bool, for display: CGDirectDisplayID) {
        guard active else {
            windows.removeValue(forKey: display)?.orderOut(nil)
            return
        }
        guard let screen = Self.screen(for: display) else { return }
        if let window = windows[display], window.screen == screen {
            return
        }
        windows.removeValue(forKey: display)?.orderOut(nil)
        guard let window = makeWindow(on: screen) else { return }
        windows[display] = window
    }

    func deactivateAll() {
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow? {
        guard let device, let commandQueue else { return nil }
        let size = CGSize(width: 4, height: 4)
        let window = NSWindow(
            contentRect: CGRect(origin: screen.frame.origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.isOpaque = false
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = size
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.setFrameOrigin(screen.frame.origin)
        window.orderFrontRegardless()

        // One extended-range frame stays presented; alpha keeps it invisible.
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return window }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 2, green: 2, blue: 2, alpha: 0.01)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return window
    }

    private static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display
        }
    }
}
