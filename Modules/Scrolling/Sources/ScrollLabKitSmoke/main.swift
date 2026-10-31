import AppKit
import Foundation
import ScrollLabKit

@main
@MainActor
struct ScrollLabKitSmoke {
    static func main() {
        let suite = "app.meridian.scrollKitSmoke.\(UUID().uuidString)"
        setenv("MERIDIAN_MODULE_SUITE", suite, 1)
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(false, forKey: "reverse")
        defaults?.set(false, forKey: "enabled")
        defer {
            defaults?.removePersistentDomain(forName: suite)
        }

        _ = NSApplication.shared
        let module = ScrollLabModule(embedded: true)
        var preferencesRequests = 0
        module.onShowPreferences = {
            preferencesRequests += 1
        }
        module.start()
        defer { module.stop() }

        let initial = module.summary()
        guard initial["embedded"] as? Bool == true,
              initial["enabled"] as? Bool == false,
              initial["temporarilyPaused"] as? Bool == false,
              initial["eventTapActive"] as? Bool == false else {
            fail("embedded read-only initial state")
        }
        guard module.settingsSnapshot()["reverse"] as? Bool == false else {
            fail("suite isolation")
        }

        guard module.updateSettings(["unknown": true])["ok"] as? Bool == false else {
            fail("unknown setting")
        }
        guard module.updateSettings(["reverse": 1])["ok"] as? Bool == false else {
            fail("strict boolean validation")
        }
        guard module.updateSettings(["speed": Double.nan])["ok"] as? Bool == false else {
            fail("finite number validation")
        }
        guard module.updateSettings(["duration": 9.0])["ok"] as? Bool == false else {
            fail("range validation")
        }
        guard module.updateSettings([
            "exceptions": [["id": "broken"]],
        ])["ok"] as? Bool == false else {
            fail("exception schema validation")
        }
        guard module.updateSettings([
            "allowlist": true,
            "rules": ["allowlist": false],
        ])["ok"] as? Bool == false else {
            fail("duplicate rule validation")
        }

        let update = module.updateSettings([
            "enabled": false,
            "reverse": true,
            "step": 24.5,
            "speed": 1.25,
            "duration": 1.5,
            "rules": ["allowlist": true, "exceptions": []],
        ])
        guard update["ok"] as? Bool == true else {
            fail("valid settings update")
        }
        let snapshot = module.settingsSnapshot()
        guard snapshot["reverse"] as? Bool == true,
              snapshot["step"] as? Double == 24.5,
              snapshot["speed"] as? Double == 1.25,
              snapshot["duration"] as? Double == 1.5 else {
            fail("settings round-trip")
        }

        let paused = module.execute(command: "pause", payload: [:])
        guard paused["ok"] as? Bool == true,
              module.summary()["temporarilyPaused"] as? Bool == true,
              module.settingsSnapshot()["enabled"] as? Bool == false else {
            fail("temporary pause")
        }
        let resumed = module.execute(command: "resume", payload: [:])
        guard resumed["ok"] as? Bool == true,
              module.summary()["temporarilyPaused"] as? Bool == false,
              module.settingsSnapshot()["enabled"] as? Bool == false else {
            fail("temporary resume")
        }

        let routed = module.execute(command: "preferences.show", payload: [:])
        guard routed["ok"] as? Bool == true, preferencesRequests == 1 else {
            fail("preferences routing")
        }
        guard module.execute(command: "shell.exec", payload: [:])["ok"] as? Bool == false else {
            fail("command allow-list")
        }

        module.stop()
        guard module.summary()["eventTapActive"] as? Bool == false else {
            fail("stop lifecycle")
        }
        module.start()
        guard module.summary()["embedded"] as? Bool == true else {
            fail("restart lifecycle")
        }

        print("SCROLL_KIT_SMOKE_PASS")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("SCROLL_KIT_SMOKE_FAIL \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
