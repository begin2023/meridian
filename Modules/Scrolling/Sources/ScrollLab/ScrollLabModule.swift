import AppKit

/// Public lifecycle facade used by the standalone app and the unified toolkit.
@MainActor
public final class ScrollLabModule {
    private let delegate: AppDelegate
    private let embedded: Bool

    public var onShowPreferences: (() -> Void)? {
        didSet {
            delegate.onShowPreferences = onShowPreferences
        }
    }

    /// In embedded mode the module does not create a second menu-bar item.
    public init(embedded: Bool = true) {
        self.embedded = embedded
        delegate = AppDelegate(embedded: embedded)
    }

    public func start() {
        delegate.start(
            promptForAccessibility: !embedded,
            handleTestArguments: !embedded
        )
    }

    public func stop() {
        delegate.stop()
    }

    public func showPreferences() {
        delegate.showPreferences()
    }

    public func summary() -> [String: Any] {
        delegate.summary()
    }

    public func settingsSnapshot() -> [String: Any] {
        AppSettings.shared.snapshot()
    }

    /// Applies a validated settings patch and returns the resulting snapshot.
    public func updateSettings(_ patch: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        var actions: [() -> Void] = []
        let supportedKeys: Set<String> = [
            "enabled", "reverse", "reverseVertical", "reverseHorizontal",
            "smooth", "smoothVertical", "smoothHorizontal", "smoothSimTrackpad",
            "step", "speed", "duration", "deadZone",
            "allowlist", "exceptions", "rules",
        ]
        if let unknown = patch.keys.first(where: { !supportedKeys.contains($0) }) {
            return unknownSetting(unknown)
        }

        let rules: [String: Any]
        if let rawRules = patch["rules"] {
            guard let value = rawRules as? [String: Any] else {
                return invalidType("rules", expected: "Object")
            }
            let supportedRuleKeys: Set<String> = ["allowlist", "exceptions"]
            if let unknown = value.keys.first(where: { !supportedRuleKeys.contains($0) }) {
                return unknownSetting("rules.\(unknown)")
            }
            if patch["allowlist"] != nil, value["allowlist"] != nil {
                return duplicateSetting("allowlist")
            }
            if patch["exceptions"] != nil, value["exceptions"] != nil {
                return duplicateSetting("exceptions")
            }
            rules = value
        } else {
            rules = [:]
        }

        func boolValue(_ raw: Any?) -> Bool? {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID(),
                  let value = raw as? Bool else {
                return nil
            }
            return value
        }

        func doubleValue(_ raw: Any?) -> Double? {
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID() {
                return value.doubleValue
            }
            return nil
        }

        func dictionaries(_ raw: Any?) -> [[String: Any]]? {
            if let value = raw as? [[String: Any]] { return value }
            if let value = raw as? [Any] { return value as? [[String: Any]] }
            return nil
        }

        let boolSetters: [(String, (Bool) -> Void)] = [
            ("enabled", settings.setEnabled),
            ("reverse", settings.setReverse),
            ("reverseVertical", settings.setReverseVertical),
            ("reverseHorizontal", settings.setReverseHorizontal),
            ("smooth", settings.setSmooth),
            ("smoothVertical", settings.setSmoothVertical),
            ("smoothHorizontal", settings.setSmoothHorizontal),
            ("smoothSimTrackpad", settings.setSmoothSimTrackpad),
        ]
        for (key, setter) in boolSetters {
            guard let raw = patch[key] else { continue }
            guard let value = boolValue(raw) else { return invalidType(key, expected: "Bool") }
            actions.append { setter(value) }
        }

        let doubleSetters: [(String, ClosedRange<Double>, (Double) -> Void)] = [
            ("step", 1.0...200.0, settings.setStep),
            ("speed", 0.1...10.0, settings.setSpeed),
            ("duration", 0.1...5.0, settings.setDuration),
            ("deadZone", 0.01...20.0, settings.setDeadZone),
        ]
        for (key, range, setter) in doubleSetters {
            guard let raw = patch[key] else { continue }
            guard let value = doubleValue(raw), value.isFinite, range.contains(value) else {
                return invalidType(key, expected: "finite number in \(range)")
            }
            actions.append { setter(value) }
        }

        if let raw = patch["allowlist"] ?? rules["allowlist"] {
            guard let value = boolValue(raw) else { return invalidType("allowlist", expected: "Bool") }
            actions.append { settings.setAllowlist(value) }
        }
        if let raw = patch["exceptions"] ?? rules["exceptions"] {
            guard let values = dictionaries(raw),
                  values.count <= 128,
                  JSONSerialization.isValidJSONObject(values),
                  let data = try? JSONSerialization.data(withJSONObject: values),
                  let exceptions = try? JSONDecoder().decode([AppException].self, from: data) else {
                return invalidType("exceptions", expected: "at most 128 valid AppException objects")
            }
            var identifiers = Set<String>()
            for exception in exceptions {
                guard !exception.id.isEmpty,
                      exception.id.utf8.count <= 128,
                      identifiers.insert(exception.id).inserted,
                      exception.name.utf8.count <= 256,
                      exception.bundlePath.utf8.count <= 4096,
                      exception.executablePath.utf8.count <= 4096,
                      !exception.name.contains("\0"),
                      !exception.bundlePath.contains("\0"),
                      !exception.executablePath.contains("\0"),
                      exception.step.isFinite,
                      (1.0...200.0).contains(exception.step),
                      exception.speed.isFinite,
                      (0.1...10.0).contains(exception.speed),
                      exception.duration.isFinite,
                      (0.1...5.0).contains(exception.duration) else {
                    return invalidType(
                        "exceptions",
                        expected: "unique IDs, bounded strings, and finite numeric ranges"
                    )
                }
            }
            if let encoded = try? JSONEncoder().encode(exceptions), encoded.count > 65_536 {
                return invalidType("exceptions", expected: "JSON payload no larger than 65536 bytes")
            }
            actions.append { settings.setExceptions(exceptions) }
        }

        if patch["enabled"] != nil {
            delegate.clearTemporaryPauseForSettingsChange()
        }
        actions.forEach { $0() }

        return ["ok": true]
    }

    /// Small JSON-command surface for the stdio agent. This method never
    /// writes to stdout; the agent transport owns framing and logging.
    public func execute(command: String, payload: [String: Any]) -> [String: Any] {
        switch command {
        case "state.get", "state.getState", "summary", "scroll.summary":
            return ["ok": true, "data": summary()]
        case "settings.snapshot", "settings.get", "getSettings":
            return ["ok": true, "settings": settingsSnapshot()]
        case "settings.update", "updateSettings":
            return updateSettings(payload)
        case "setEnabled", "scroll.setEnabled":
            guard let value = payload["enabled"] ?? payload["value"] else {
                return missing("enabled")
            }
            return updateSettings(["enabled": value])
        case "setReverse", "scroll.setReverse":
            guard let value = payload["reverse"] ?? payload["value"] else {
                return missing("reverse")
            }
            return updateSettings(["reverse": value])
        case "setSmooth", "scroll.setSmooth":
            guard let value = payload["smooth"] ?? payload["value"] else {
                return missing("smooth")
            }
            return updateSettings(["smooth": value])
        case "setRules", "scroll.setRules":
            let rules = payload["rules"] as? [String: Any] ?? payload
            return updateSettings(["rules": rules])
        case "pause", "scroll.pause":
            delegate.pauseTemporarily()
            return ["ok": true, "temporarilyPaused": true]
        case "resume", "scroll.resume":
            delegate.resumeAfterTemporaryPause()
            return ["ok": true, "temporarilyPaused": false]
        case "preferences.show", "showPreferences":
            showPreferences()
            return ["ok": true]
        case "requestPermission", "scroll.requestPermission":
            let granted = ScrollTapController.promptAccessibility()
            return ["ok": true, "granted": granted]
        case "module.start", "start":
            delegate.start(promptForAccessibility: false, handleTestArguments: false)
            return ["ok": true, "started": true]
        case "module.stop", "stop":
            stop()
            return ["ok": true, "started": false]
        default:
            return [
                "ok": false,
                "error": "unsupported_command",
                "message": "Unknown ScrollLab command: \(command)",
            ]
        }
    }

    private func invalidType(_ key: String, expected: String) -> [String: Any] {
        [
            "ok": false,
            "error": "invalid_setting",
            "message": "\(key) must be \(expected)",
        ]
    }

    private func missing(_ key: String) -> [String: Any] {
        [
            "ok": false,
            "error": "missing_argument",
            "message": "Missing \(key)",
        ]
    }

    private func unknownSetting(_ key: String) -> [String: Any] {
        [
            "ok": false,
            "error": "unknown_setting",
            "message": "Unknown setting: \(key)",
        ]
    }

    private func duplicateSetting(_ key: String) -> [String: Any] {
        [
            "ok": false,
            "error": "duplicate_setting",
            "message": "Setting specified both at top level and under rules: \(key)",
        ]
    }
}
