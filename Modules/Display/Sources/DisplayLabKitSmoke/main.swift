import AppKit
import DisplayLabKit
import Foundation

@main
@MainActor
struct DisplayLabKitSmoke {
    static func main() {
        let suite = "app.meridian.displayKitSmoke.\(UUID().uuidString)"
        setenv("MERIDIAN_MODULE_SUITE", suite, 1)
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(false, forKey: "smoothingEnabled")
        defaults?.set(false, forKey: "takeOverBrightnessKeys")
        defer {
            defaults?.removePersistentDomain(forName: suite)
        }

        _ = NSApplication.shared
        let module = DisplayLabModule(embedded: true)
        var preferencesRequests = 0
        module.onShowPreferences = {
            preferencesRequests += 1
        }
        module.start()
        defer { module.stop() }

        let initial = module.summary()
        guard initial["embedded"] as? Bool == true,
              initial["hardwareWritesEnabled"] as? Bool == false,
              initial["displayCount"] as? Int != nil else {
            fail("embedded read-only summary")
        }
        guard module.settingsSnapshot()["smoothingEnabled"] as? Bool == false else {
            fail("suite isolation")
        }

        guard module.updateSettings(["unknown": true])["ok"] as? Bool == false else {
            fail("unknown setting")
        }
        guard module.updateSettings(["launchAtLogin": true])["ok"] as? Bool == false else {
            fail("Shell-owned setting")
        }
        guard module.updateSettings(["takeOverBrightnessKeys": 1])["ok"] as? Bool == false else {
            fail("strict boolean validation")
        }
        guard module.updateSettings(["combinedDimmingPoint": Double.nan])["ok"] as? Bool == false else {
            fail("finite number validation")
        }
        guard module.updateSettings(["smoothingDurationMilliseconds": 79.0])["ok"] as? Bool == false else {
            fail("range validation")
        }
        guard module.updateSettings(["ddcWriteCount": 2.5])["ok"] as? Bool == false else {
            fail("integer validation")
        }

        let update = module.updateSettings([
            "smoothingEnabled": true,
            "smoothingDurationMilliseconds": 240.0,
            "combinedDimmingPoint": 0.2,
            "ddcWriteCount": 3,
            "ddcWriteDelayMilliseconds": 9,
            "ddcRetryCount": 2,
            "showLowResolutionModes": false,
            "takeOverBrightnessKeys": false,
            "showVirtualScreens": false,
        ])
        guard update["ok"] as? Bool == true else {
            fail("valid settings update")
        }
        let snapshot = module.settingsSnapshot()
        guard snapshot["smoothingEnabled"] as? Bool == true,
              snapshot["smoothingDurationMilliseconds"] as? Double == 240.0,
              snapshot["ddcWriteCount"] as? Int == 3,
              snapshot["ddcWriteDelayMilliseconds"] as? Int == 9,
              snapshot["showLowResolutionModes"] as? Bool == false else {
            fail("settings round-trip")
        }

        for command in ["brightness.set", "mode.switch", "hdr.toggle", "setBrightness"] {
            let result = module.execute(command: command, payload: [:])
            guard result["ok"] as? Bool == false,
                  result["error"] as? String == "hardware_writes_disabled" else {
                fail("hardware write rejection: \(command)")
            }
        }

        let routed = module.execute(command: "preferences.show", payload: [:])
        guard routed["ok"] as? Bool == true, preferencesRequests == 1 else {
            fail("preferences routing")
        }
        guard module.execute(command: "shell.exec", payload: [:])["ok"] as? Bool == false else {
            fail("command allow-list")
        }

        module.stop()
        module.start()
        guard module.summary()["embedded"] as? Bool == true else {
            fail("restart lifecycle")
        }

        print("DISPLAY_KIT_SMOKE_PASS")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("DISPLAY_KIT_SMOKE_FAIL \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
