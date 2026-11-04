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

        // 借位模式校验：回放真实面板的数据——5120×2880 帧缓冲在同一刷新率下只有
        // 144/120/60 有同比例的真实链路时序；75Hz 唯一的真实 timing 是 1280×1024@75
        // （4:3），WindowServer 会把 5K 画面压进去并横向拉伸 4.0 倍，桌面仍谎报 2560×1440。
        func mode(_ pw: Int, _ ph: Int, _ w: Int, _ h: Int, _ hz: Double,
                  hidpi: Bool, current: Bool = false) -> DisplayModeInfo {
            DisplayModeInfo(pixelWidth: pw, pixelHeight: ph, pointWidth: w, pointHeight: h,
                            refreshRate: hz, isHiDPI: hidpi, cgsIndex: nil, isCurrent: current)
        }
        let panel = [
            mode(2560, 1440, 2560, 1440, 144, hidpi: false, current: true),
            mode(2560, 1440, 2560, 1440, 120, hidpi: false),
            mode(2560, 1440, 2560, 1440, 60, hidpi: false),
            mode(1280, 1024, 1280, 1024, 75, hidpi: false),
            mode(1280, 1024, 1280, 1024, 60, hidpi: false),
            mode(1920, 1080, 1920, 1080, 60, hidpi: false),
            mode(5120, 2880, 2560, 1440, 144, hidpi: true, current: true),
            mode(5120, 2880, 2560, 1440, 120, hidpi: true),
            mode(5120, 2880, 2560, 1440, 60, hidpi: true),
            mode(5120, 2880, 2560, 1440, 75, hidpi: true),
            mode(5120, 2880, 2560, 1440, 72, hidpi: true),
            mode(5120, 2880, 2560, 1440, 70, hidpi: true),
            mode(5120, 2880, 2560, 1440, 56, hidpi: true),
            mode(5120, 2880, 2560, 1440, 50, hidpi: true),
            mode(3840, 2160, 1920, 1080, 50, hidpi: true),
        ]
        guard ModeValidation.isRenderable(mode(5120, 2880, 2560, 1440, 144, hidpi: true), in: panel) else {
            fail("validation keeps 5120x2880 @144")
        }
        guard ModeValidation.isRenderable(mode(5120, 2880, 2560, 1440, 60, hidpi: true), in: panel) else {
            fail("validation keeps 5120x2880 @60")
        }
        for broken in [75.0, 72.0, 70.0, 56.0] {
            guard !ModeValidation.isRenderable(mode(5120, 2880, 2560, 1440, broken, hidpi: true), in: panel) else {
                fail("validation rejects borrowed 5120x2880 @\(broken)")
            }
        }
        guard !ModeValidation.isRenderable(mode(5120, 2880, 2560, 1440, 50, hidpi: true), in: panel) else {
            fail("validation rejects 5120x2880 @50 (4K carrier)")
        }
        guard ModeValidation.isRenderable(mode(1280, 1024, 1280, 1024, 75, hidpi: false), in: panel) else {
            fail("validation keeps the 1280x1024 @75 carrier")
        }
        let selectable = ModeValidation.usableModes(in: panel)
        guard !selectable.contains(where: { $0.isHiDPI && $0.pixelWidth == 5120 && abs($0.refreshRate - 75) < 0.5 }) else {
            fail("usableModes drops the borrowed 75Hz HiDPI mode")
        }
        guard selectable.contains(where: { $0.isHiDPI && $0.pixelWidth == 5120 && abs($0.refreshRate - 144) < 0.5 }) else {
            fail("usableModes keeps the current 144Hz HiDPI mode")
        }
        guard ModeValidation.usableModes(in: [mode(5120, 2880, 2560, 1440, 75, hidpi: true)]).count == 1 else {
            fail("usableModes leaves a table without carriers untouched")
        }

        print("DISPLAY_KIT_SMOKE_PASS")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("DISPLAY_KIT_SMOKE_FAIL \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
