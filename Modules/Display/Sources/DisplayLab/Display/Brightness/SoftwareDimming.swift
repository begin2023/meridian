import AppKit
import CoreGraphics

/// Gamma-table based software dimming. Snapshots each display's default
/// transfer tables once, then scales them for dimming so Night Shift and
/// color profiles keep their baseline. The OS overwrites gamma tables on
/// wake, space changes and color profile switches, so applications are
/// re-applied and an invisible always-on-top window nudges WindowServer into
/// flushing the updated tables.
final class SoftwareDimming {
    static let shared = SoftwareDimming()

    private struct Snapshot {
        let sampleCount: UInt32
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    private var snapshots: [CGDirectDisplayID: Snapshot] = [:]
    private var activeFactors: [CGDirectDisplayID: Double] = [:]
    private let queue = DispatchQueue(label: "app.meridian.display.gamma", qos: .userInitiated)
    private var enforcerWindow: NSWindow?

    private init() {
        observeReconfiguration()
    }

    /// Dimming factor for a display; 1.0 means neutral.
    func factor(for display: CGDirectDisplayID) -> Double {
        queue.sync {
            activeFactors[display] ?? 1.0
        }
    }

    /// Applies a 0...1 dimming factor. A factor of 1 restores the snapshot.
    func apply(factor: Double, to display: CGDirectDisplayID) {
        queue.async { [weak self] in
            guard let self else { return }
            let clamped = min(1, max(0.02, factor))
            self.activeFactors[display] = clamped
            self.applyTable(factor: clamped, display: display)
        }
    }

    func restoreAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.restoreTablesNow()
        }
    }

    /// Restores every gamma table before an embedded agent stops or the app
    /// terminates. This must complete synchronously because the process may
    /// exit immediately after `applicationWillTerminate`.
    func restoreAllSynchronously() {
        queue.sync {
            restoreTablesNow()
        }
        let removeEnforcer = { [weak self] in
            self?.enforcerWindow?.orderOut(nil)
            self?.enforcerWindow = nil
        }
        if Thread.isMainThread {
            removeEnforcer()
        } else {
            DispatchQueue.main.sync(execute: removeEnforcer)
        }
    }

    // MARK: - Table application

    private func restoreTablesNow() {
        for display in Array(activeFactors.keys) {
            activeFactors[display] = 1.0
            applyTable(factor: 1.0, display: display, nudge: false)
        }
    }

    private func snapshot(for display: CGDirectDisplayID) -> Snapshot {
        if let snapshot = snapshots[display] {
            return snapshot
        }
        let capacity = max(2, Int(CGDisplayGammaTableCapacity(display)))
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        if CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &sampleCount) != .success {
            sampleCount = 0
        }
        let snapshot = Snapshot(sampleCount: sampleCount, red: red, green: green, blue: blue)
        snapshots[display] = snapshot
        return snapshot
    }

    private func applyTable(factor: Double, display: CGDirectDisplayID, nudge: Bool = true) {
        let snapshot = self.snapshot(for: display)
        guard snapshot.sampleCount > 0 else { return }

        var red = snapshot.red
        var green = snapshot.green
        var blue = snapshot.blue
        for index in 0..<Int(snapshot.sampleCount) {
            red[index] = min(1, snapshot.red[index] * CGGammaValue(factor))
            green[index] = min(1, snapshot.green[index] * CGGammaValue(factor))
            blue[index] = min(1, snapshot.blue[index] * CGGammaValue(factor))
        }
        CGSetDisplayTransferByTable(display, snapshot.sampleCount, &red, &green, &blue)
        if nudge {
            nudgeEnforcer(on: display)
        }
    }

    /// A stationary, click-through, nearly invisible window at screensaver
    /// level forces WindowServer to re-flush gamma tables right after the
    /// call above; without it the OS sometimes coalesces the change away.
    private func nudgeEnforcer(on display: CGDirectDisplayID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = self.enforcer(for: display)
            window.alphaValue = 0.01
            window.alphaValue = 0.02
        }
    }

    private func enforcer(for display: CGDirectDisplayID) -> NSWindow {
        if let enforcerWindow, enforcerWindow.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display {
            return enforcerWindow
        }
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .black
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        enforcerWindow = window
        return window
    }

    // MARK: - OS interference handling

    private func observeReconfiguration() {
        CGDisplayRegisterReconfigurationCallback({ display, _, userInfo in
            guard display != 0 else { return }
            let dimming = Unmanaged<SoftwareDimming>.fromOpaque(userInfo!).takeUnretainedValue()
            dimming.queue.async {
                // Reconfiguration invalidates cached tables and reapplies the
                // active factor once the display settles.
                dimming.snapshots.removeValue(forKey: display)
                if dimming.activeFactors[display] != nil {
                    dimming.queue.asyncAfter(deadline: .now() + 1.0) {
                        guard let factor = dimming.activeFactors[display] else { return }
                        dimming.applyTable(factor: factor, display: display)
                    }
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                for display in Array(self.activeFactors.keys) {
                    self.queue.asyncAfter(deadline: .now() + 2.0) {
                        guard let factor = self.activeFactors[display] else { return }
                        self.applyTable(factor: factor, display: display)
                    }
                }
            }
        }
    }
}
