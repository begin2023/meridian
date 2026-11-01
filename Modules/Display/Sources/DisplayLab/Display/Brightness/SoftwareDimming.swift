import AppKit
import CoreGraphics

/// Gamma-table based software dimming and HDR brightness boost. Snapshots
/// each display's default transfer tables once, then scales them (below 1.0
/// to dim, above 1.0 to boost while EDRKeeper holds the display in EDR) so
/// Night Shift and color profiles keep their baseline. The OS overwrites gamma tables on
/// wake, space changes and color profile switches, so applications are
/// re-applied and an invisible always-on-top window nudges WindowServer into
/// flushing the updated tables.
final class SoftwareDimming {
    static let shared = SoftwareDimming()

    /// Upper bound for boost factors; the usable range is the display's EDR
    /// headroom, which callers clamp to.
    static let maxBoost = 4.0

    private struct Snapshot {
        let sampleCount: UInt32
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    private var snapshots: [CGDirectDisplayID: Snapshot] = [:]
    /// Last table written per display. After a reconfiguration the snapshot
    /// is only replaced when the OS really reset the table; otherwise the
    /// re-read table would be our own dimmed table and dimming would compound.
    private var appliedTables: [CGDirectDisplayID: Snapshot] = [:]
    private var staleSnapshots: Set<CGDirectDisplayID> = []
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

    /// Applies a dimming (< 1) or boost (> 1) factor. A factor of 1 restores
    /// the snapshot.
    func apply(factor: Double, to display: CGDirectDisplayID) {
        queue.async { [weak self] in
            guard let self else { return }
            let clamped = min(Self.maxBoost, max(0.02, factor))
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
        if let snapshot = snapshots[display], !staleSnapshots.contains(display) {
            return snapshot
        }
        staleSnapshots.remove(display)
        let capacity = max(2, Int(CGDisplayGammaTableCapacity(display)))
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        if CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &sampleCount) != .success {
            sampleCount = 0
        }
        let snapshot = Snapshot(sampleCount: sampleCount, red: red, green: green, blue: blue)
        let boostedTable = (0..<Int(sampleCount)).contains {
            red[$0] > 1.0001 || green[$0] > 1.0001 || blue[$0] > 1.0001
        }
        if let previous = snapshots[display],
           boostedTable || appliedTables[display].map({ Self.tablesMatch(snapshot, $0) }) == true {
            // The OS kept our adjusted table (system tables never exceed
            // 1.0); the old baseline is still right.
            return previous
        }
        snapshots[display] = snapshot
        return snapshot
    }

    private func applyTable(factor: Double, display: CGDirectDisplayID, nudge: Bool = true) {
        let snapshot = self.snapshot(for: display)
        guard snapshot.sampleCount > 0 else { return }

        // 实测（macOS 27.2）：1024 项的色表里高于 1.0 的值会被截到 1.0，256/512 项则保留。
        // 提升亮度时改写 256 项（系统读回时再插值成 1024 项）。
        let sourceCount = Int(snapshot.sampleCount)
        let count = factor > 1 ? min(sourceCount, 256) : sourceCount
        let cap = CGGammaValue(max(1, factor))
        var red = Self.resample(snapshot.red, count: sourceCount, to: count).map { min(cap, $0 * CGGammaValue(factor)) }
        var green = Self.resample(snapshot.green, count: sourceCount, to: count).map { min(cap, $0 * CGGammaValue(factor)) }
        var blue = Self.resample(snapshot.blue, count: sourceCount, to: count).map { min(cap, $0 * CGGammaValue(factor)) }
        CGSetDisplayTransferByTable(display, UInt32(count), &red, &green, &blue)
        appliedTables[display] = Snapshot(
            sampleCount: snapshot.sampleCount,
            red: Self.resample(red, count: count, to: sourceCount),
            green: Self.resample(green, count: count, to: sourceCount),
            blue: Self.resample(blue, count: count, to: sourceCount)
        )
        let boosting = factor > 1.001
        DispatchQueue.main.async {
            EDRKeeper.shared.setActive(boosting, for: display)
        }
        if nudge {
            nudgeEnforcer(on: display)
        }
    }

    /// Linear resampling of a transfer table to `target` entries.
    private static func resample(_ values: [CGGammaValue], count: Int, to target: Int) -> [CGGammaValue] {
        guard count > 1, target > 1, count != target else { return Array(values.prefix(max(count, 0))) }
        return (0..<target).map { index in
            let position = Double(index) * Double(count - 1) / Double(target - 1)
            let lower = Int(position)
            let upper = min(lower + 1, count - 1)
            let fraction = CGGammaValue(position - Double(lower))
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }

    private static func tablesMatch(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        guard lhs.sampleCount == rhs.sampleCount, lhs.sampleCount > 0 else { return false }
        for index in 0..<Int(lhs.sampleCount) {
            if abs(lhs.red[index] - rhs.red[index]) > 0.01
                || abs(lhs.green[index] - rhs.green[index]) > 0.01
                || abs(lhs.blue[index] - rhs.blue[index]) > 0.01 {
                return false
            }
        }
        return true
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
                dimming.staleSnapshots.insert(display)
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
