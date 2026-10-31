import Foundation
import ServiceManagement

final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let smoothingEnabled = "smoothingEnabled"
        static let smoothingDurationMilliseconds = "smoothingDurationMilliseconds"
        static let combinedDimmingPoint = "combinedDimmingPoint"
        static let ddcWriteCount = "ddcWriteCount"
        static let ddcWriteDelayMilliseconds = "ddcWriteDelayMilliseconds"
        static let ddcRetryCount = "ddcRetryCount"
        static let showLowResolutionModes = "showLowResolutionModes"
        static let launchAtLogin = "launchAtLogin"
        static let takeOverBrightnessKeys = "takeOverBrightnessKeys"
        static let showVirtualScreens = "showVirtualScreens"
    }

    private let defaults: UserDefaults

    private init() {
        if let suite = ProcessInfo.processInfo.environment["MERIDIAN_MODULE_SUITE"],
           !suite.isEmpty,
           let scopedDefaults = UserDefaults(suiteName: suite) {
            defaults = scopedDefaults
        } else {
            defaults = .standard
        }
    }

    /// Whether slider moves fade through intermediate values instead of jumping.
    var smoothingEnabled: Bool {
        get { defaults.object(forKey: Keys.smoothingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.smoothingEnabled) }
    }

    /// Wall-clock duration of a smooth brightness transition in milliseconds.
    var smoothingDurationMilliseconds: Double {
        get {
            let stored = defaults.object(forKey: Keys.smoothingDurationMilliseconds) as? Double ?? 300
            return max(80, min(2000, stored))
        }
        set { defaults.set(max(80, min(2000, newValue)), forKey: Keys.smoothingDurationMilliseconds) }
    }

    /// Combined brightness level (0-1) below which software dimming takes over
    /// from hardware DDC control.
    var combinedDimmingPoint: Double {
        get {
            let stored = defaults.object(forKey: Keys.combinedDimmingPoint) as? Double ?? 0.25
            return max(0.0, min(0.6, stored))
        }
        set { defaults.set(max(0.0, min(0.6, newValue)), forKey: Keys.combinedDimmingPoint) }
    }

    /// DDC command repetitions per brightness write.
    var ddcWriteCount: Int {
        get {
            let stored = defaults.object(forKey: Keys.ddcWriteCount) as? Int ?? 2
            return max(1, min(6, stored))
        }
        set { defaults.set(max(1, min(6, newValue)), forKey: Keys.ddcWriteCount) }
    }

    /// Pause between DDC command repetitions in milliseconds.
    var ddcWriteDelayMilliseconds: Int {
        get {
            let stored = defaults.object(forKey: Keys.ddcWriteDelayMilliseconds) as? Int ?? 10
            return max(2, min(100, stored))
        }
        set { defaults.set(max(2, min(100, newValue)), forKey: Keys.ddcWriteDelayMilliseconds) }
    }

    /// Retry attempts after a failed DDC write.
    var ddcRetryCount: Int {
        get {
            let stored = defaults.object(forKey: Keys.ddcRetryCount) as? Int ?? 4
            return max(0, min(10, stored))
        }
        set { defaults.set(max(0, min(10, newValue)), forKey: Keys.ddcRetryCount) }
    }

    /// Whether the resolution menu also lists plain low resolution modes.
    var showLowResolutionModes: Bool {
        get { defaults.object(forKey: Keys.showLowResolutionModes) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showLowResolutionModes) }
    }

    /// Whether F1/F2 media keys adjust external display brightness. Off by
    /// default: the user opts in explicitly (it also needs the Input
    /// Monitoring permission).
    var takeOverBrightnessKeys: Bool {
        get { defaults.object(forKey: Keys.takeOverBrightnessKeys) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.takeOverBrightnessKeys) }
    }

    /// Whether the virtual screens section appears in the status menu.
    var showVirtualScreens: Bool {
        get { defaults.object(forKey: Keys.showVirtualScreens) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showVirtualScreens) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("DisplayLab login item update failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
