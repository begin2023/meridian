import AppKit
import CoreGraphics
import DisplayCore

/// Owns the live display list, refreshes on reconfiguration, and keeps the
/// per-display DDC devices wired to their IOAVServices.
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []
    private var ddcDevices: [CGDirectDisplayID: DDCDevice] = [:]
    private var brightnessControllers: [CGDirectDisplayID: DisplayBrightnessController] = [:]
    private var lastKnownBrightness: [CGDirectDisplayID: Double] = [:]
    private var isMonitoringDisplayChanges = false

    var onDisplaysChanged: (() -> Void)?

    init() {
        refresh()
    }

    deinit {
        stopMonitoringDisplayChanges()
    }

    func startMonitoringDisplayChanges() {
        guard !isMonitoringDisplayChanges else { return }
        CGDisplayRegisterReconfigurationCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isMonitoringDisplayChanges = true
    }

    func stopMonitoringDisplayChanges() {
        guard isMonitoringDisplayChanges else { return }
        CGDisplayRemoveReconfigurationCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isMonitoringDisplayChanges = false
    }

    func refresh() {
        displays = (try? DisplayEnumerator.enumerate()) ?? []
        onDisplaysChanged?()
    }

    func display(with identifier: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.identifier == identifier }
    }

    /// DDC device for a display, created on first use and cached. Returns nil
    /// when the display has no IOAVService (built-in panels, virtual screens).
    func ddcDevice(for display: CGDirectDisplayID) -> DDCDevice? {
        if let device = ddcDevices[display] {
            return device
        }
        guard let service = try? AVServiceLocator.avService(for: display) else {
            return nil
        }
        let settings = AppSettings.shared
        let device = DDCDevice(
            displayID: display,
            service: service,
            writeCount: settings.ddcWriteCount,
            writeDelayMilliseconds: settings.ddcWriteDelayMilliseconds,
            retryCount: settings.ddcRetryCount
        )
        ddcDevices[display] = device
        return device
    }

    /// Probes whether a display supports DDC by attempting one luminance read.
    /// Result is cached with a negative marker only for the current session;
    /// reconfigurations retry because wake/hot-plug can change availability.
    func supportsDDC(_ display: CGDirectDisplayID) -> Bool {
        ddcDevice(for: display) != nil
    }

    /// Brightness controller for a display, created on first use. Backends:
    /// DDC for external panels with an AV service, DisplayServices for Apple
    /// built-ins, gamma-only for virtual screens.
    func brightnessController(for display: CGDirectDisplayID) -> DisplayBrightnessController? {
        if let controller = brightnessControllers[display] {
            return controller
        }
        guard let info = self.display(with: display) else { return nil }

        let controller: DisplayBrightnessController
        if let device = ddcDevice(for: display) {
            controller = DisplayBrightnessController(displayID: display, ddcDevice: device, appleBrightness: nil)
        } else if info.isBuiltIn, let apple = AppleBrightness.make() {
            controller = DisplayBrightnessController(displayID: display, ddcDevice: nil, appleBrightness: apple)
        } else {
            controller = DisplayBrightnessController(displayID: display, ddcDevice: nil, appleBrightness: nil)
        }
        brightnessControllers[display] = controller
        return controller
    }

    /// Last brightness fraction observed for a display (0...1); defaults to 1.
    func cachedBrightness(for display: CGDirectDisplayID) -> Double {
        lastKnownBrightness[display] ?? 1.0
    }

    func updateCachedBrightness(_ fraction: Double, for display: CGDirectDisplayID) {
        lastKnownBrightness[display] = fraction
    }

    /// Reads the current hardware brightness for every display in the
    /// background so the menu slider starts at the real value.
    func refreshBrightnessCache() {
        // DisplayManager's caches are main-thread owned. Resolve controllers
        // before leaving the main thread, then publish only the read results
        // back on the main queue.
        let controllers = displays.compactMap { display in
            brightnessController(for: display.identifier).map {
                (display.identifier, $0)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let readings = controllers.compactMap { identifier, controller in
                controller.readCurrentFraction().map { (identifier, $0) }
            }
            guard !readings.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (identifier, fraction) in readings {
                    self.updateCachedBrightness(fraction, for: identifier)
                }
            }
        }
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.refresh()
        }
    }
}
