import AppKit
import CoreFoundation
import ServiceManagement

/// 用户可调设置，使用 UserDefaults 持久化。
/// （见 docs/reverse-engineering-notes.md 的真机配置快照）。
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "enabled"
        static let reverse = "reverse"
        static let reverseVertical = "reverseVertical"
        static let reverseHorizontal = "reverseHorizontal"
        static let smooth = "smooth"
        static let smoothVertical = "smoothVertical"
        static let smoothHorizontal = "smoothHorizontal"
        static let smoothSimTrackpad = "smoothSimTrackpad"
        static let step = "step"
        static let speed = "speed"
        static let duration = "duration"
        static let deadZone = "deadZone"
        static let allowlist = "allowlist"
        static let applications = "applications"
        static let hideStatusItem = "hideStatusItem"
        static let launchAtLogin = "launchAtLogin"
    }

    static let defaultStep = 33.6
    static let defaultSpeed = 2.7
    static let defaultDuration = 4.35
    static let defaultDeadZone = 1.0

    /// duration 滑杆的上界；transition 公式里有 0.2 的偏移，保证结果不为 0。
    static let durationSliderMax = 5.0

    private(set) var enabled: Bool = true
    private(set) var reverse: Bool = false
    private(set) var reverseVertical: Bool = true
    private(set) var reverseHorizontal: Bool = true
    private(set) var smooth: Bool = true
    private(set) var smoothVertical: Bool = true
    private(set) var smoothHorizontal: Bool = true
    private(set) var smoothSimTrackpad: Bool = false
    private(set) var step: Double = AppSettings.defaultStep
    private(set) var speed: Double = AppSettings.defaultSpeed
    private(set) var duration: Double = AppSettings.defaultDuration
    private(set) var deadZone: Double = AppSettings.defaultDeadZone
    private(set) var allowlist: Bool = false
    private(set) var exceptions: [AppException] = []
    private(set) var hideStatusItem: Bool = false
    private(set) var launchAtLogin: Bool = false

    /// 每帧收缩比例：剩余距离 × transition。duration 越大走越慢。
    var transitionFactor: Double {
        let upperLimit = AppSettings.durationSliderMax + 0.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (value * 1000).rounded() / 1000
    }

    var onChange: (() -> Void)?

    private init() {
        if let suite = ProcessInfo.processInfo.environment["MERIDIAN_MODULE_SUITE"],
           !suite.isEmpty,
           let scopedDefaults = UserDefaults(suiteName: suite) {
            defaults = scopedDefaults
        } else {
            defaults = .standard
        }
        load()
    }

    func load() {
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        reverse = defaults.object(forKey: Key.reverse) as? Bool ?? false
        reverseVertical = defaults.object(forKey: Key.reverseVertical) as? Bool ?? true
        reverseHorizontal = defaults.object(forKey: Key.reverseHorizontal) as? Bool ?? true
        smooth = defaults.object(forKey: Key.smooth) as? Bool ?? true
        smoothVertical = defaults.object(forKey: Key.smoothVertical) as? Bool ?? true
        smoothHorizontal = defaults.object(forKey: Key.smoothHorizontal) as? Bool ?? true
        smoothSimTrackpad = defaults.object(forKey: Key.smoothSimTrackpad) as? Bool ?? false
        step = defaults.object(forKey: Key.step) as? Double ?? AppSettings.defaultStep
        speed = defaults.object(forKey: Key.speed) as? Double ?? AppSettings.defaultSpeed
        duration = defaults.object(forKey: Key.duration) as? Double ?? AppSettings.defaultDuration
        deadZone = defaults.object(forKey: Key.deadZone) as? Double ?? AppSettings.defaultDeadZone
        allowlist = defaults.object(forKey: Key.allowlist) as? Bool ?? false
        hideStatusItem = defaults.object(forKey: Key.hideStatusItem) as? Bool ?? false
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        if let raw = defaults.data(forKey: Key.applications),
           let decoded = try? JSONDecoder().decode([AppException].self, from: raw) {
            exceptions = decoded
        } else {
            exceptions = []
        }
    }

    func setEnabled(_ value: Bool) { commit(Key.enabled) { enabled = value; defaults.set(value, forKey: Key.enabled) } }
    func setReverse(_ value: Bool) { commit(Key.reverse) { reverse = value; defaults.set(value, forKey: Key.reverse) } }
    func setReverseVertical(_ value: Bool) { commit(Key.reverseVertical) { reverseVertical = value; defaults.set(value, forKey: Key.reverseVertical) } }
    func setReverseHorizontal(_ value: Bool) { commit(Key.reverseHorizontal) { reverseHorizontal = value; defaults.set(value, forKey: Key.reverseHorizontal) } }
    func setSmooth(_ value: Bool) { commit(Key.smooth) { smooth = value; defaults.set(value, forKey: Key.smooth) } }
    func setSmoothVertical(_ value: Bool) { commit(Key.smoothVertical) { smoothVertical = value; defaults.set(value, forKey: Key.smoothVertical) } }
    func setSmoothHorizontal(_ value: Bool) { commit(Key.smoothHorizontal) { smoothHorizontal = value; defaults.set(value, forKey: Key.smoothHorizontal) } }
    func setSmoothSimTrackpad(_ value: Bool) { commit(Key.smoothSimTrackpad) { smoothSimTrackpad = value; defaults.set(value, forKey: Key.smoothSimTrackpad) } }
    func setStep(_ value: Double) { commit(Key.step) { step = value; defaults.set(value, forKey: Key.step) } }
    func setSpeed(_ value: Double) { commit(Key.speed) { speed = value; defaults.set(value, forKey: Key.speed) } }
    func setDuration(_ value: Double) { commit(Key.duration) { duration = value; defaults.set(value, forKey: Key.duration) } }
    func setDeadZone(_ value: Double) { commit(Key.deadZone) { deadZone = value; defaults.set(value, forKey: Key.deadZone) } }
    func setAllowlist(_ value: Bool) { commit(Key.allowlist) { allowlist = value; defaults.set(value, forKey: Key.allowlist) } }
    func setHideStatusItem(_ value: Bool) { commit(Key.hideStatusItem) { hideStatusItem = value; defaults.set(value, forKey: Key.hideStatusItem) } }

    func setExceptions(_ value: [AppException]) {
        exceptions = value
        if let raw = try? JSONEncoder().encode(value) {
            defaults.set(raw, forKey: Key.applications)
        }
        notifyChange()
    }

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLogin = value
        defaults.set(value, forKey: Key.launchAtLogin)
        applyLaunchAtLogin()
        notifyChange()
    }

    func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("ScrollLab: launch-at-login update failed: \(error)")
        }
    }

    private func commit(_ key: String, apply: () -> Void) {
        apply()
        notifyChange()
    }

    private func notifyChange() {
        onChange?()
    }

    /// JSON-compatible state for the module agent. `rules` is the canonical
    /// exception-policy group; the flat aliases ease UI binding.
    func snapshot() -> [String: Any] {
        let exceptionValues = exceptions.map { exception -> [String: Any] in
            [
                "id": exception.id,
                "name": exception.name,
                "bundlePath": exception.bundlePath,
                "executablePath": exception.executablePath,
                "inherit": exception.inherit,
                "reverse": exception.reverse,
                "reverseVertical": exception.reverseVertical,
                "reverseHorizontal": exception.reverseHorizontal,
                "smooth": exception.smooth,
                "smoothVertical": exception.smoothVertical,
                "smoothHorizontal": exception.smoothHorizontal,
                "step": exception.step,
                "speed": exception.speed,
                "duration": exception.duration,
            ]
        }
        return [
            "enabled": enabled,
            "reverse": reverse,
            "reverseVertical": reverseVertical,
            "reverseHorizontal": reverseHorizontal,
            "smooth": smooth,
            "smoothVertical": smoothVertical,
            "smoothHorizontal": smoothHorizontal,
            "smoothSimTrackpad": smoothSimTrackpad,
            "step": step,
            "speed": speed,
            "duration": duration,
            "deadZone": deadZone,
            "allowlist": allowlist,
            "exceptions": exceptionValues,
            "rules": [
                "allowlist": allowlist,
                "exceptions": exceptionValues,
            ],
            "launchAtLogin": launchAtLogin,
            "hideStatusItem": hideStatusItem,
        ]
    }
}

/// 单个例外应用：默认继承全局设置，可单独覆盖。
struct AppException: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var bundlePath: String
    var executablePath: String
    var inherit: Bool
    var reverse: Bool
    var reverseVertical: Bool
    var reverseHorizontal: Bool
    var smooth: Bool
    var smoothVertical: Bool
    var smoothHorizontal: Bool
    var step: Double
    var speed: Double
    var duration: Double

    init(
        id: String = UUID().uuidString,
        name: String,
        bundlePath: String,
        executablePath: String,
        inherit: Bool = true,
        reverse: Bool = false,
        reverseVertical: Bool = true,
        reverseHorizontal: Bool = true,
        smooth: Bool = true,
        smoothVertical: Bool = true,
        smoothHorizontal: Bool = true,
        step: Double = AppSettings.defaultStep,
        speed: Double = AppSettings.defaultSpeed,
        duration: Double = AppSettings.defaultDuration
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.inherit = inherit
        self.reverse = reverse
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.smooth = smooth
        self.smoothVertical = smoothVertical
        self.smoothHorizontal = smoothHorizontal
        self.step = step
        self.speed = speed
        self.duration = duration
    }
}
