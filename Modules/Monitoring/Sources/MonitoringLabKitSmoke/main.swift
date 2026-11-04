import AppKit
import MonitoringLabKit

let suite = "app.meridian.monitoring.kit-smoke.\(getpid())"
setenv("MERIDIAN_MODULE_SUITE", suite, 1)
setenv("MERIDIAN_EMBEDDED", "1", 1)
defer {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
}

_ = NSApplication.shared
var failure: String?

MainActor.assumeIsolated {
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.1)
    let live = sampler.sample()
    guard live.memoryTotal > 0, !live.netInterface.isEmpty else {
        failure = "basic sampler did not produce memory/network data"
        return
    }

    let ranker = SystemSampler()
    _ = ranker.rankProcesses(includeNetwork: true)
    Thread.sleep(forTimeInterval: 1.1)
    let ranking = ranker.rankProcesses(includeNetwork: true)
    guard !ranking.byCPU.isEmpty, !ranking.byMemory.isEmpty else {
        failure = "process ranking did not produce CPU/memory rows"
        return
    }
    let networkNames = ranking.byNetwork.prefix(3).map(\.name).joined(separator: ",")
    print("Monitoring sampler live: interface=\(live.netInterface) networkRanking=\(ranking.byNetwork.count) top=\(networkNames)")

    // 累计字节不能因为计数器回绕或接口重建而变小（macOS 27 的 NET_RT_IFLIST2 只有 32 位）。
    let counters = InterfaceCounters.read()
    guard counters[live.netInterface] != nil else {
        failure = "interface counters missing for \(live.netInterface)"
        return
    }
    var tracker = InterfaceVolumeTracker()
    let first = tracker.update(["en1": (1_000, 2_000)])
    let reset = tracker.update(["en1": (5, 10)])
    guard first["en1"]?.received == 1_000, first["en1"]?.sent == 2_000,
          reset["en1"]?.received == 1_005, reset["en1"]?.sent == 2_010 else {
        failure = "volume tracker must carry the previous reading over a counter reset: \(reset)"
        return
    }
    guard tracker.update([:])["en1"]?.received == 1_005 else {
        failure = "volume tracker must keep totals when an interface disappears"
        return
    }
    print("Interface counters: \(counters.count) interfaces, volume tracker monotonic")

    let module = MonitoringLabModule(embedded: true)
    var preferencesRouted = false
    module.onShowPreferences = { preferencesRouted = true }

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
    guard initial["network.geoLookupEnabled"] as? Bool == false else {
        failure = "embedded geo lookup must be false"
        return
    }
    guard let modules = initial["modules"] as? [String: [String: Any]],
          modules["cpu"]?["widgetStyle"] as? String == "text",
          initial["modules.cpu.enabled"] as? Bool == true,
          initial["modules.cpu.widgetStyle"] as? String == "text" else {
        failure = "widget style must use a stable text id"
        return
    }
    let initialSummary = module.summary()
    guard initialSummary["embedded"] as? Bool == true,
          initialSummary["primaryStatusItemVisible"] as? Bool == false,
          let initialModules = initialSummary["modules"] as? [String: [String: Any]],
          initialModules.values.allSatisfy({
              ($0["widgetVisible"] as? Bool) == false
          }) else {
        failure = "embedded startup created a status item"
        return
    }
    guard NSApp.mainMenu == nil,
          !NSApp.windows.contains(where: \.isVisible) else {
        failure = "embedded startup created a menu or visible window"
        return
    }

    let rejectedGeo = module.updateSettings(["network.geoLookupEnabled": true])
    guard rejectedGeo["ok"] as? Bool == false else {
        failure = "embedded geo lookup update must be rejected"
        return
    }
    let rejectedLogin = module.updateSettings(["launchAtLogin": true])
    guard rejectedLogin["ok"] as? Bool == false else {
        failure = "Shell-owned login setting must be rejected"
        return
    }
    let rejectedFractional = module.updateSettings(["updateInterval": 1.5])
    guard rejectedFractional["ok"] as? Bool == false else {
        failure = "fractional interval must be rejected"
        return
    }
    let rejectedBooleanNumber = module.updateSettings(["modules.cpu.enabled": 1])
    guard rejectedBooleanNumber["ok"] as? Bool == false else {
        failure = "numeric module enable value must be rejected"
        return
    }
    let rejectedStyle = module.updateSettings(["modules.cpu.widgetStyle": "pie"])
    guard rejectedStyle["ok"] as? Bool == false else {
        failure = "unknown widget style must be rejected"
        return
    }
    let updated = module.updateSettings([
        "updateInterval": 3,
        "modules.net.widgetStyle": "graph",
        "modules.disk.enabled": false,
    ])
    guard updated["ok"] as? Bool == true else {
        failure = "valid settings update failed: \(updated)"
        return
    }
    let snapshot = module.settingsSnapshot()
    guard snapshot["updateInterval"] as? Int == 3,
          (snapshot["revision"] as? Int ?? 0) > 0,
          let changed = snapshot["modules"] as? [String: [String: Any]],
          changed["net"]?["widgetStyle"] as? String == "graph",
          changed["disk"]?["enabled"] as? Bool == false else {
        failure = "settings did not round-trip"
        return
    }

    let writableFlatSettings: [String: Any] = [
        "updateInterval": snapshot["updateInterval"] as Any,
        "network.geoLookupEnabled": snapshot["network.geoLookupEnabled"] as Any,
        "modules.cpu.enabled": snapshot["modules.cpu.enabled"] as Any,
        "modules.cpu.widgetStyle": snapshot["modules.cpu.widgetStyle"] as Any,
        "modules.ram.enabled": snapshot["modules.ram.enabled"] as Any,
        "modules.ram.widgetStyle": snapshot["modules.ram.widgetStyle"] as Any,
        "modules.net.enabled": snapshot["modules.net.enabled"] as Any,
        "modules.net.widgetStyle": snapshot["modules.net.widgetStyle"] as Any,
        "modules.disk.enabled": snapshot["modules.disk.enabled"] as Any,
        "modules.disk.widgetStyle": snapshot["modules.disk.widgetStyle"] as Any,
    ]
    let flatRoundTrip = module.execute(
        command: "updateSettings",
        payload: ["changes": writableFlatSettings]
    )
    guard flatRoundTrip["ok"] as? Bool == true else {
        failure = "flat command settings round-trip failed: \(flatRoundTrip)"
        return
    }
    let afterFlat = module.settingsSnapshot()
    guard afterFlat["updateInterval"] as? Int == 3,
          afterFlat["network.geoLookupEnabled"] as? Bool == false,
          (afterFlat["revision"] as? Int ?? 0) > (snapshot["revision"] as? Int ?? 0),
          let afterModules = afterFlat["modules"] as? [String: [String: Any]],
          afterModules["net"]?["widgetStyle"] as? String == "graph",
          afterModules["disk"]?["enabled"] as? Bool == false else {
        failure = "flat settings command did not round-trip"
        return
    }
    let getSettings = module.execute(command: "getSettings", payload: [:])
    guard getSettings["ok"] as? Bool == true,
          let commandSnapshot = getSettings["result"] as? [String: Any],
          commandSnapshot["suite"] as? String == suite,
          commandSnapshot["updateInterval"] as? Int == 3,
          (commandSnapshot["revision"] as? Int ?? -1) ==
            (afterFlat["revision"] as? Int ?? -2) else {
        failure = "getSettings command shape is invalid"
        return
    }

    _ = module.execute(command: "showPreferences", payload: [:])
    guard preferencesRouted else {
        failure = "preferences were not routed to the host"
        return
    }

    for id in ["cpu", "ram", "net", "disk"] {
        let detail = module.execute(
            command: "showDetail",
            payload: ["module": id]
        )
        guard detail["ok"] as? Bool == true else {
            failure = "showDetail(\(id)) must be available without a status item: \(detail)"
            return
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        guard let panel = NSApp.windows.first(where: {
            $0.isVisible && $0.level == .statusBar && $0 is NSPanel
        }) else {
            failure = "showDetail(\(id)) did not create a visible status-level panel"
            return
        }
        panel.orderOut(nil)
    }
    for id in ["cpu", "ram", "net", "disk"] {
        let alias = module.execute(command: id, payload: [:])
        guard alias["ok"] as? Bool == true else {
            failure = "module detail alias \(id) must be available: \(alias)"
            return
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        guard let panel = NSApp.windows.first(where: {
            $0.isVisible && $0.level == .statusBar && $0 is NSPanel
        }) else {
            failure = "module detail alias \(id) did not create a visible status-level panel"
            return
        }
        panel.orderOut(nil)
    }
    let bringForward = module.execute(command: "showAllWindows", payload: [:])
    guard bringForward["ok"] as? Bool == true,
          NSApp.mainMenu == nil else {
        failure = "showAllWindows must not install an application menu"
        return
    }
    let summary = module.execute(command: "summary", payload: [:])
    guard summary["ok"] as? Bool == true,
          let result = summary["result"] as? [String: Any],
          result["embedded"] as? Bool == true else {
        failure = "summary command failed"
        return
    }

    module.stop()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    let stopped = module.summary()
    guard stopped["running"] as? Bool == false,
          !NSApp.windows.contains(where: \.isVisible),
          NSApp.mainMenu == nil else {
        failure = "embedded stop left a menu or visible window"
        return
    }
}

if let failure {
    fputs("MonitoringLabKitSmoke failed: \(failure)\n", stderr)
    exit(1)
}
print("MonitoringLabKitSmoke ok")
