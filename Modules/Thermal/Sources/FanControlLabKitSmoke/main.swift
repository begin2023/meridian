import AppKit
import FanControlLabKit

let suite = "app.meridian.thermal.kit-smoke.\(getpid())"
setenv("MERIDIAN_MODULE_SUITE", suite, 1)
setenv("MERIDIAN_EMBEDDED", "1", 1)
defer {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
}

_ = NSApplication.shared
var failure: String?

func toolOutput(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FanControlLabKitSmoke-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let output = try? FileHandle(forWritingTo: outputURL) else {
        return nil
    }
    process.standardOutput = output
    process.standardError = output
    defer {
        try? FileManager.default.removeItem(at: outputURL)
    }
    do {
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            try? output.close()
            return nil
        }
        try? output.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        try? output.close()
        return nil
    }
}

func decoded(_ base64: String) -> String {
    guard let data = Data(base64Encoded: base64) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
let nmOutput = toolOutput("/usr/bin/nm", ["-m", executable])
let stringsOutput = toolOutput("/usr/bin/strings", ["-a", executable])
if nmOutput == nil || stringsOutput == nil {
    failure = "could not inspect the read-only Kit binary"
}
let binarySurface = [
    nmOutput ?? "",
    stringsOutput ?? "",
].joined(separator: "\n")
// 控制链路（ControlService → desired.json → root 守护进程）由宿主应用使用；
// Kit 本身仍不得包含进程内 SMC 写入或写入实验代码，硬件写入只发生在守护进程里。
let forbiddenMarkers = [
    "RmFuV3JpdGVFeHBlcmltZW50",
    "d3JpdGVCeXRlcw==",
    "d3JpdGVGbG9hdA==",
].map(decoded)
for marker in forbiddenMarkers where binarySurface.contains(marker) {
    failure = "Kit binary contains in-process SMC write marker: \(marker)"
}

MainActor.assumeIsolated {
    guard failure == nil else { return }

    let module = FanControlLabModule(embedded: true)
    var preferencesRouted = 0
    module.onShowPreferences = { preferencesRouted += 1 }

    guard NSApp.mainMenu == nil else {
        failure = "startup must not install an application main menu"
        return
    }
    guard !NSApp.windows.contains(where: \.isVisible) else {
        failure = "startup must not create a visible window"
        return
    }

    module.start()
    defer { module.stop() }

    let initial = module.settingsSnapshot()
    guard initial["suite"] as? String == suite else {
        failure = "suite isolation failed"
        return
    }
    guard initial["controlArmed"] as? Bool == false else {
        failure = "control must be unarmed"
        return
    }
    let initialSummary = module.summary()
    guard initialSummary["embedded"] as? Bool == true,
          initialSummary["mode"] as? String == "read_only",
          initialSummary["controlArmed"] as? Bool == false,
          initialSummary["writesSupported"] as? Bool == false,
          NSApp.mainMenu == nil,
          !NSApp.windows.contains(where: \.isVisible) else {
        failure = "embedded startup created a menu, status surface, or visible window"
        return
    }
    let updated = module.updateSettings([
        "refreshInterval": 2.0,
        "fahrenheit": true,
        "menuBarShowsTemperature": true,
        "maximumRPMFraction": 0.8,
        "defaultIncreaseAt": 55.0,
        "defaultMaxAt": 85.0,
    ])
    guard updated["ok"] as? Bool == true else {
        failure = "valid monitor settings update failed: \(updated)"
        return
    }
    let snapshot = module.settingsSnapshot()
    guard snapshot["refreshInterval"] as? Double == 2.0,
          snapshot["fahrenheit"] as? Bool == true,
          snapshot["maximumRPMFraction"] as? Double == 0.8 else {
        failure = "settings did not round-trip"
        return
    }
    let rejectedBoolean = module.updateSettings(["fahrenheit": 1])
    guard rejectedBoolean["ok"] as? Bool == false else {
        failure = "numeric boolean setting must be rejected"
        return
    }
    let rejectedCurve = module.updateSettings([
        "defaultIncreaseAt": 85.0,
        "defaultMaxAt": 80.0,
    ])
    guard rejectedCurve["ok"] as? Bool == false else {
        failure = "invalid temperature curve must be rejected"
        return
    }
    let writableSettings: [String: Any] = [
        "refreshInterval": snapshot["refreshInterval"] as Any,
        "fahrenheit": snapshot["fahrenheit"] as Any,
        "menuBarShowsTemperature": snapshot["menuBarShowsTemperature"] as Any,
        "maximumRPMFraction": snapshot["maximumRPMFraction"] as Any,
        "defaultIncreaseAt": snapshot["defaultIncreaseAt"] as Any,
        "defaultMaxAt": snapshot["defaultMaxAt"] as Any,
    ]
    let commandRoundTrip = module.execute(
        command: "updateSettings",
        payload: ["changes": writableSettings]
    )
    guard commandRoundTrip["ok"] as? Bool == true,
          let responseSettings = commandRoundTrip["settings"] as? [String: Any],
          responseSettings["refreshInterval"] as? Double == 2.0,
          (responseSettings["revision"] as? Int ?? 0) >
            (snapshot["revision"] as? Int ?? 0) else {
        failure = "atomic settings command round-trip failed: \(commandRoundTrip)"
        return
    }
    let getSettings = module.execute(command: "getSettings", payload: [:])
    guard getSettings["ok"] as? Bool == true,
          let commandSnapshot = getSettings["result"] as? [String: Any],
          commandSnapshot["suite"] as? String == suite,
          commandSnapshot["refreshInterval"] as? Double == 2.0 else {
        failure = "getSettings command shape is invalid"
        return
    }

    _ = module.execute(command: "showPreferences", payload: [:])
    guard preferencesRouted == 1 else {
        failure = "preferences were not routed to the host"
        return
    }
    let showMain = module.execute(command: "showMainWindow", payload: [:])
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    guard showMain["ok"] as? Bool == true,
          preferencesRouted == 1,
          NSApp.mainMenu == nil,
          let sensorWindow = NSApp.windows.first(where: {
              $0.isVisible && $0.title == "传感器详情"
          }),
          module.summary()["sensorWindowVisible"] as? Bool == true else {
        failure = "showMainWindow did not create the read-only sensor window"
        return
    }
    let sensorWindowID = ObjectIdentifier(sensorWindow)

    let showAll = module.execute(command: "showAllWindows", payload: [:])
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    guard showAll["ok"] as? Bool == true,
          preferencesRouted == 1,
          NSApp.windows.filter({ $0.isVisible && $0.title == "传感器详情" }).count == 1,
          let reopened = NSApp.windows.first(where: {
              $0.isVisible && $0.title == "传感器详情"
          }),
          ObjectIdentifier(reopened) == sensorWindowID else {
        failure = "showAllWindows must reuse the singleton sensor window"
        return
    }

    _ = module.execute(command: "showPreferences", payload: [:])
    guard preferencesRouted == 2,
          NSApp.windows.filter(\.isVisible).count == 1,
          NSApp.windows.filter({ $0.isVisible && $0.title == "传感器详情" }).count == 1 else {
        failure = "showPreferences must stay centralized without opening a local settings window"
        return
    }
    let write = module.execute(command: "writeFan", payload: [:])
    guard write["ok"] as? Bool == false,
          write["error"] as? String == "control_unarmed" else {
        failure = "fan write command was not rejected"
        return
    }
    let helper = module.execute(command: "installHelper", payload: [:])
    guard helper["ok"] as? Bool == false else {
        failure = "helper install command was not rejected"
        return
    }
    let summary = module.execute(command: "summary", payload: [:])
    guard summary["ok"] as? Bool == true,
          let result = summary["result"] as? [String: Any],
          result["mode"] as? String == "read_only",
          result["controlArmed"] as? Bool == false,
          result["writesSupported"] as? Bool == false,
          result["sensorWindowVisible"] as? Bool == true else {
        failure = "read-only summary shape is invalid"
        return
    }

    module.stop()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    guard !NSApp.windows.contains(where: \.isVisible),
          NSApp.mainMenu == nil,
          module.summary()["sensorWindowVisible"] as? Bool == false else {
        failure = "embedded stop left a menu or visible window"
        return
    }
}

if let failure {
    fputs("FanControlLabKitSmoke failed: \(failure)\n", stderr)
    exit(1)
}
print("FanControlLabKitSmoke ok")
