import AppKit
import BrightnessMapping
import CoreGraphics
import DisplayCore

/// Per-display brightness facade. Picks a hardware backend (DDC for external
/// panels, DisplayServices for Apple displays), layers gamma-based software
/// dimming below the combined dimming point, and smooths transitions on a
/// serial queue with coalescing so slider drags never backlog the I2C bus.
final class DisplayBrightnessController {
    enum BackendKind: String {
        case ddc
        case apple
        case gammaOnly
        case unavailable
    }

    enum BrightnessError: LocalizedError {
        case backendUnavailable
        case hardwareWriteFailed

        var errorDescription: String? {
            switch self {
            case .backendUnavailable:
                return "此显示器不支持亮度调节。"
            case .hardwareWriteFailed:
                return "硬件亮度写入失败。"
            }
        }
    }

    let displayID: CGDirectDisplayID
    let backendKind: BackendKind

    private let ddcDevice: DDCDevice?
    private let appleBrightness: AppleBrightness?
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "app.meridian.display.brightness", qos: .userInitiated)
    private var currentTarget: Double
    private var pendingWrite: Double?
    private var isWriting = false
    private var settleWorkItem: DispatchWorkItem?

    init(
        displayID: CGDirectDisplayID,
        ddcDevice: DDCDevice?,
        appleBrightness: AppleBrightness?,
        settings: AppSettings = .shared
    ) {
        self.displayID = displayID
        self.ddcDevice = ddcDevice
        self.appleBrightness = appleBrightness
        self.settings = settings

        if ddcDevice != nil {
            backendKind = .ddc
            DispatchQueue.global(qos: .utility).async { [weak ddcDevice] in
                ddcDevice?.primeMaxLuminance()
            }
        } else if appleBrightness != nil {
            backendKind = .apple
        } else {
            backendKind = .gammaOnly
        }
        currentTarget = 1.0
    }

    /// Last target set through this controller (0...1).
    var targetFraction: Double {
        queue.sync { currentTarget }
    }

    /// Reads the hardware brightness in slider space. Software dimming is an
    /// additional low-end adjustment and does not change the slider mapping.
    /// Expensive (DDC pacing); call off-main.
    func readCurrentFraction() -> Double? {
        let hardwareFraction: Double?
        switch backendKind {
        case .ddc:
            guard let ddcDevice else { return nil }
            guard let value = try? ddcDevice.readLuminance() else { return nil }
            hardwareFraction = value.fraction
        case .apple:
            hardwareFraction = appleBrightness?.currentFraction(for: displayID)
        case .gammaOnly, .unavailable:
            return nil
        }

        guard let hardwareFraction else { return nil }
        return BrightnessMapping.sliderFraction(forHardwareFraction: hardwareFraction)
    }

    /// Sets brightness. `smooth` interpolates through intermediate values;
    /// otherwise writes are coalesced latest-wins: each slider tick writes
    /// immediately with a single DDC send, and 200 ms after the last tick a
    /// full paced write settles the final value.
    func setTarget(_ fraction: Double, smooth: Bool, completion: ((Error?) -> Void)? = nil) {
        let clamped = min(1, max(0, fraction))

        if !smooth {
            queue.async { [weak self] in
                guard let self else { return }
                self.currentTarget = clamped
                self.pendingWrite = clamped
                self.settleWorkItem?.cancel()
                self.pump(completion: completion)
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWrite = nil
            self.settleWorkItem?.cancel()
            let from = self.currentTarget
            let to = clamped
            self.currentTarget = to

            let duration = self.settings.smoothingDurationMilliseconds / 1000
            let steps = max(3, min(16, Int(duration / 0.045)))
            for step in 1...steps {
                let progress = Double(step) / Double(steps)
                // Ease-out so the tail settles gently.
                let eased = from + (to - from) * (1 - pow(1 - progress, 2))
                let isLast = step == steps
                self.queue.asyncAfter(deadline: .now() + duration * progress) {
                    do {
                        try self.applyFraction(eased)
                        if isLast {
                            completion?(nil)
                        }
                    } catch {
                        if isLast {
                            completion?(error)
                        }
                    }
                }
            }
        }
    }

    /// Serializes writes on the controller queue. Intermediate slider ticks
    /// use a single DDC send; when no new tick arrives for 200 ms the final
    /// value is re-sent with the full paced repetition count.
    private func pump(completion: ((Error?) -> Void)?) {
        guard !isWriting, let target = pendingWrite else {
            return
        }
        pendingWrite = nil
        isWriting = true
        do {
            try applyFraction(target, sends: 1)
            isWriting = false
            scheduleSettle(for: target)
            if pendingWrite != nil {
                pump(completion: nil)
            } else {
                completion?(nil)
            }
        } catch {
            isWriting = false
            completion?(error)
        }
    }

    private func scheduleSettle(for target: Double) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingWrite == nil else { return }
            try? self.applyFraction(target, sends: nil)
        }
        settleWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Hardware follows the full slider range. Below the switchover point,
    /// gamma dimming extends the low end without creating a control handoff.
    private func applyFraction(_ fraction: Double, sends: Int? = nil) throws {
        let mapping = BrightnessMapping.make(
            fraction: fraction,
            switchover: settings.combinedDimmingPoint
        )
        let dimming = SoftwareDimming.shared

        guard mapping.softwareDimmingFactor < 1 else {
            do {
                try applyHardware(mapping.hardwareFraction, sends: sends)
            } catch {
                if dimming.factor(for: displayID) != 1.0 {
                    dimming.apply(factor: 1.0, to: displayID)
                }
                throw error
            }
            if dimming.factor(for: displayID) != 1.0 {
                dimming.apply(factor: 1.0, to: displayID)
            }
            return
        }

        try? applyHardware(mapping.hardwareFraction, sends: sends)
        dimming.apply(factor: mapping.softwareDimmingFactor, to: displayID)
    }

    private func applyHardware(_ fraction: Double, sends: Int? = nil) throws {
        switch backendKind {
        case .ddc:
            guard let ddcDevice else { throw BrightnessError.backendUnavailable }
            try ddcDevice.writeLuminance(fraction: fraction, sends: sends)
        case .apple:
            guard let appleBrightness else { throw BrightnessError.backendUnavailable }
            if !appleBrightness.apply(fraction: fraction, to: displayID) {
                throw BrightnessError.hardwareWriteFailed
            }
        case .gammaOnly, .unavailable:
            throw BrightnessError.backendUnavailable
        }
    }
}
