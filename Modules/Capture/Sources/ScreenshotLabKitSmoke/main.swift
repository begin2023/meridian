import AppKit
import Foundation
import ScreenshotLabKit

@main
@MainActor
struct ScreenshotLabKitSmoke {
    static func main() {
        let suite = "app.meridian.screenshotKitSmoke.\(UUID().uuidString)"
        setenv("MERIDIAN_MODULE_SUITE", suite, 1)
        defer {
            unsetenv("MERIDIAN_MODULE_SUITE")
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        _ = NSApplication.shared
        let module = ScreenshotLabModule()
        module.start()
        defer { module.stop() }

        var preferencesRequests = 0
        module.onShowPreferences = {
            preferencesRequests += 1
        }

        let initial = module.summary()
        guard initial["moduleID"] as? String == "capture",
              initial["started"] as? Bool == true,
              initial["embedded"] as? Bool == true,
              initial["hotKeysManagedByShell"] as? Bool == true,
              initial["settingsSuite"] as? String == suite,
              initial["lastError"] as? String == "" else {
            fail("embedded summary")
        }

        let snapshot = module.settingsSnapshot()
        guard snapshot["schemaVersion"] as? Int == 1,
              snapshot["captureHotKey"] as? [String: Any] != nil,
              snapshot["launchAtLogin"] == nil else {
            fail("settings snapshot")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotLabKitSmoke-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            fail("temporary directory: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let update = module.updateSettings([
            "quickSaveDirectory": directory.path,
            "screenshotScale": 0.5,
            "screenshotHistoryLimit": 12,
            "gifMaximumWidth": 640,
            "gifFramesPerSecond": 5,
        ])
        guard update["ok"] as? Bool == true,
              module.settingsSnapshot()["quickSaveDirectory"] as? String == directory.path,
              (module.settingsSnapshot()["revision"] as? Int ?? 0) > 0 else {
            fail("settings update")
        }

        var roundTrip = module.settingsSnapshot()
        roundTrip["expectedRevision"] = roundTrip["revision"]
        guard module.updateSettings(roundTrip)["ok"] as? Bool == true else {
            fail("settings snapshot round-trip")
        }

        let invalid = module.updateSettings(["screenshotScale": 0.42])
        guard invalid["ok"] as? Bool == false,
              invalid["error"] as? String != nil else {
            fail("settings validation")
        }

        let conflict = module.updateSettings([
            "expectedRevision": 0,
            "gifFramesPerSecond": 10,
        ])
        guard conflict["ok"] as? Bool == false else {
            fail("settings revision conflict")
        }

        let rejectedCommand = module.execute(
            command: "settings.update",
            payload: ["screenshotScale": 0.42]
        )
        guard rejectedCommand["ok"] as? Bool == false else {
            fail("settings command error propagation")
        }

        let routed = module.execute(command: "preferences.show", payload: [:])
        guard routed["ok"] as? Bool == true,
              preferencesRequests == 1,
              module.summary()["preferencesWindowOpen"] as? Bool == false else {
            fail("settings routing")
        }

        guard module.execute(command: "ping", payload: [:])["ok"] as? Bool == true else {
            fail("ping")
        }
        guard module.execute(command: "shell.exec", payload: [:])["ok"] as? Bool == false else {
            fail("command allow-list")
        }

        module.stop()
        guard module.summary()["started"] as? Bool == false else {
            fail("stop lifecycle")
        }
        module.start()
        guard module.summary()["started"] as? Bool == true else {
            fail("restart lifecycle")
        }

        print("SCREENSHOT_KIT_SMOKE_PASS")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(
            Data("SCREENSHOT_KIT_SMOKE_FAIL \(message)\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}
