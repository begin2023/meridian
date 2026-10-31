import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private(set) var isEmbedded = false
    private(set) var isRunning = false
    private var windowPresence: WindowPresenceController?
    private var preferencesWindowController: PreferencesWindowController?
    private var modules: [MonitorModule] = []
    private var hostStatusItem: NSStatusItem?
    private var didStart = false

    var onShowPreferences: (() -> Void)?
    var allowsQuitAction: Bool {
        !isEmbedded
    }

    var isTestSession: Bool {
        CommandLine.arguments.contains("--test-instance")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start(embedded: false)
    }

    func start(embedded: Bool) {
        guard !didStart else { return }
        didStart = true
        isEmbedded = embedded
        isRunning = true
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        let presence = WindowPresenceController()
        windowPresence = presence

        modules = [CPUModule(), RAMModule(), NetModule(), DiskModule()]
        for module in modules {
            (module as? BaseModule)?.widgetsEnabled = !embedded
        }
        modules.forEach { $0.start() }

        if !embedded {
            buildHostStatusItem()
            handleLaunchFlags()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    func stop() {
        guard didStart else { return }
        modules.forEach { $0.stop() }
        modules.removeAll()
        if let hostStatusItem {
            NSStatusBar.system.removeStatusItem(hostStatusItem)
            self.hostStatusItem = nil
        }
        preferencesWindowController?.close()
        preferencesWindowController = nil
        isRunning = false
        didStart = false
        if AppDelegate.shared === self {
            AppDelegate.shared = nil
        }
    }

    func setEmbedded(_ embedded: Bool) {
        guard isEmbedded != embedded else { return }
        isEmbedded = embedded
        for module in modules {
            (module as? BaseModule)?.setWidgetsEnabled(!embedded)
        }
        if embedded, let hostStatusItem {
            NSStatusBar.system.removeStatusItem(hostStatusItem)
            self.hostStatusItem = nil
        } else if !embedded, hostStatusItem == nil {
            buildHostStatusItem()
        }
    }

    // MARK: - 常驻菜单

    private func buildHostStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppTheme.symbol("gauge", size: 15, weight: .medium)
        item.button?.toolTip = "MonitoringLab"
        let menu = NSMenu()
        menu.addItem(withTitle: "偏好设置…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        menu.addItem(withTitle: "显示所有窗口", action: #selector(showAllWindowsAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MonitoringLab", action: #selector(quitAction), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        hostStatusItem = item
    }

    // MARK: - 偏好设置

    func showPreferences() {
        if preferencesWindowController == nil {
            let controller = PreferencesWindowController(onChange: { [weak self] in
                self?.modules.forEach { $0.rebuild() }
            })
            preferencesWindowController = controller
        }
        windowPresence?.register(preferencesWindowController?.window)
        preferencesWindowController?.show()
    }

    @objc func openPreferencesAction() {
        requestShowPreferences()
    }

    func requestShowPreferences() {
        if let onShowPreferences {
            onShowPreferences()
        } else if !isEmbedded {
            showPreferences()
        }
    }

    @objc func showAllWindowsAction() {
        windowPresence?.bringForward()
    }

    @objc func quitAction() {
        requestQuit()
    }

    func requestQuit() {
        if !isEmbedded { NSApp.terminate(nil) }
    }

    func runtimeSettingsDidChange() {
        modules.forEach { $0.rebuild() }
    }

    func showDetail(moduleID: String) -> Bool {
        guard let module = modules.first(where: { $0.id == moduleID }),
              let base = module as? BaseModule else {
            return false
        }
        return base.showDetachedPopup()
    }

    func windowPresenceBringForward() {
        windowPresence?.bringForward()
    }

    func summary() -> [String: Any] {
        [
            "id": "monitoring",
            "embedded": isEmbedded,
            "running": isRunning,
            "primaryStatusItemVisible": hostStatusItem?.isVisible == true,
            "widgetsEnabled": !isEmbedded,
            "settingsSuite": AppSettings.shared.suiteName,
            "modules": Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0.readOnlySummary()) }),
        ]
    }

    // MARK: - 启动旗标(离屏验证与采样冒烟,仅 Debug 构建)

    private func handleLaunchFlags() {
        #if DEBUG
        runTestFlags()
        #endif
    }

    #if DEBUG
    private func runTestFlags() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--test-instance") else { return }

        if arguments.contains("--show-preferences") {
            // 保持运行,用于真机截图验证设置窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPreferences()
            }
        } else if arguments.contains("--dump-status") {
            dumpStatusItems()
        } else if arguments.contains("--dump-procs") {
            dumpProcesses()
        } else if arguments.contains("--dump-net") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NetModule.debugDumpBuffer(path: "/tmp/app-buffer.bin")
                let counters = NetModule.interfaceCounters()
                for (name, value) in counters.sorted(by: { $0.key < $1.key }) {
                    print(String(format: "%-10@ down=%9.3f GB up=%9.3f GB", name as NSString, Double(value.received)/1e9, Double(value.sent)/1e9))
                }
                let primary = counters.max { $0.value.received + $0.value.sent < $1.value.received + $1.value.sent }?.key
                print("primary =", primary ?? "nil")
                exit(0)
            }
        } else if let index = arguments.firstIndex(of: "--render-popup-live"), index + 2 < arguments.count {
            renderPopup(moduleID: arguments[index + 1], outputPath: arguments[index + 2], live: true)
        } else if let index = arguments.firstIndex(of: "--render-popup"), index + 2 < arguments.count {
            renderPopup(moduleID: arguments[index + 1], outputPath: arguments[index + 2], live: false)
        } else if let index = arguments.firstIndex(of: "--render-preferences"), index + 1 < arguments.count {
            renderPreferences(outputPath: arguments[index + 1])
        } else if arguments.contains("--sampler-smoke"), let index = arguments.firstIndex(of: "--smoke-output"), index + 1 < arguments.count {
            runSamplerSmoke(outputPath: arguments[index + 1])
        }
    }
    #endif

    #if DEBUG
    private func dumpProcesses() {
        // 第一轮建立基线,1 秒后第二轮给出真实百分比
        _ = ProcessListProvider.shared.topProcesses(sort: .cpu, limit: 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let samples = ProcessListProvider.shared.topProcesses(sort: .cpu, limit: 8)
            for sample in samples {
                print(String(format: "%@ pid=%d cpu=%.1f%% mem=%.0fMB",
                             sample.name, sample.pid, sample.cpuPercent,
                             Double(sample.memoryBytes) / 1_048_576))
            }
            exit(0)
        }
    }

    private func dumpStatusItems() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { exit(2) }
            for module in self.modules {
                guard let base = module as? BaseModule, let item = base.debugStatusItem else {
                    print("\(module.id): no status item")
                    continue
                }
                let button = item.button
                let frame = button?.window?.convertToScreen(button?.bounds ?? .zero) ?? .zero
                print("""
                \(module.id): visible=\(item.isVisible) \
                len=\(item.length) \
                img=\(button?.image?.size ?? .zero) \
                screenFrame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))
                """)
            }
            exit(0)
        }
    }

    private func renderPopup(moduleID: String, outputPath: String, live: Bool) {
        guard ["cpu", "ram", "net", "disk"].contains(moduleID) else {
            FileHandle.standardError.write("unknown module \(moduleID)\n".data(using: .utf8)!)
            exit(2)
        }
        // live 模式等待首次系统采样后再绘制。
        let delay: DispatchTime = live ? .now() + 4.0 : .now() + 0.3
        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
            guard let self else { exit(2) }
            let content: NSView
            switch moduleID {
            case "cpu":
                let module = self.modules.compactMap { $0 as? CPUModule }.first
                if !live { module?.loadDebugSnapshot() }
                content = module?.makePopupContentView() ?? NSView()
            case "ram":
                let module = self.modules.compactMap { $0 as? RAMModule }.first
                if !live { module?.loadDebugSnapshot() }
                content = module?.makePopupContentView() ?? NSView()
            case "net":
                let module = self.modules.compactMap { $0 as? NetModule }.first
                if !live { module?.loadDebugSnapshot() }
                content = module?.makePopupContentView() ?? NSView()
            default:
                let module = self.modules.compactMap { $0 as? DiskModule }.first
                if !live { module?.loadDebugSnapshot() }
                content = module?.makePopupContentView() ?? NSView()
            }
            let size = NSSize(width: 368, height: content.fittingSize.height)
            content.setFrameSize(size)
            switch moduleID {
            case "cpu": self.modules.compactMap { $0 as? CPUModule }.first?.applySnapshot()
            case "ram": self.modules.compactMap { $0 as? RAMModule }.first?.applySnapshot()
            case "net": self.modules.compactMap { $0 as? NetModule }.first?.applySnapshot()
            default: self.modules.compactMap { $0 as? DiskModule }.first?.applySnapshot()
            }
            content.layoutSubtreeIfNeeded()
            content.writeDebugPNG(to: URL(fileURLWithPath: outputPath))
            exit(0)
        }
    }

    private func renderPreferences(outputPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showPreferences()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = self?.preferencesWindowController?.window,
                      let contentView = window.contentView else {
                    FileHandle.standardError.write("preferences window missing\n".data(using: .utf8)!)
                    exit(2)
                }
                contentView.writeDebugPNG(to: URL(fileURLWithPath: outputPath))
                exit(0)
            }
        }
    }

    #if DEBUG
    private func runSamplerSmoke(outputPath: String) {
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            guard ticks >= 3 else { return }
            timer.invalidate()
            self.writeSamplerSmokeReport(outputPath: outputPath, ticks: ticks)
        }
    }

    private func writeSamplerSmokeReport(outputPath: String, ticks: Int) {
        let cpu = modules.compactMap { $0 as? CPUModule }.first
        let ram = modules.compactMap { $0 as? RAMModule }.first
        let net = modules.compactMap { $0 as? NetModule }.first
        let disk = modules.compactMap { $0 as? DiskModule }.first

        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(["name": name, "passed": passed, "detail": detail])
        }

        let cpuSnapshot = cpu?.debugSnapshot() ?? CPUModule.Snapshot()
        check(
            "cpu.totalPercent",
            cpuSnapshot.totalPercent >= 0 && cpuSnapshot.totalPercent <= 100,
            String(format: "%.1f%%", cpuSnapshot.totalPercent)
        )
        check("cpu.cores", cpuSnapshot.corePercents.count >= 1, "\(cpuSnapshot.corePercents.count) 核")

        let ramSnapshot = ram?.debugSnapshot() ?? RAMModule.Snapshot()
        check("ram.totalBytes", ramSnapshot.totalBytes > 0, Format.bytes(Double(ramSnapshot.totalBytes)))
        check(
            "ram.usedWithinRange",
            ramSnapshot.usedBytes > 0 && Double(ramSnapshot.usedBytes) <= Double(ramSnapshot.totalBytes) * 1.1,
            Format.bytes(Double(ramSnapshot.usedBytes))
        )

        let netSnapshot = net?.debugSnapshot() ?? NetModule.Snapshot()
        check(
            "net.rates",
            netSnapshot.downBytesPerSecond >= 0 && netSnapshot.upBytesPerSecond >= 0,
            "↓\(Format.bytes(netSnapshot.downBytesPerSecond, perSecond: true)) ↑\(Format.bytes(netSnapshot.upBytesPerSecond, perSecond: true))"
        )

        let diskSnapshot = disk?.debugSnapshot() ?? DiskModule.Snapshot()
        check(
            "disk.rootVolume",
            diskSnapshot.volumes.contains { $0.mountPath == "/" },
            diskSnapshot.volumes.map { $0.name }.joined(separator: ",")
        )
        check(
            "disk.throughput",
            diskSnapshot.readBytesPerSecond >= 0 && diskSnapshot.writeBytesPerSecond >= 0,
            "读\(Format.bytes(diskSnapshot.readBytesPerSecond, perSecond: true)) 写\(Format.bytes(diskSnapshot.writeBytesPerSecond, perSecond: true))"
        )

        let report: [String: Any] = [
            "ticks": ticks,
            "cpu": [
                "totalPercent": cpuSnapshot.totalPercent,
                "coreCount": cpuSnapshot.corePercents.count,
            ],
            "ram": [
                "totalBytes": ramSnapshot.totalBytes,
                "usedBytes": ramSnapshot.usedBytes,
            ],
            "net": [
                "downBytesPerSecond": netSnapshot.downBytesPerSecond,
                "upBytesPerSecond": netSnapshot.upBytesPerSecond,
            ],
            "disk": [
                "volumes": diskSnapshot.volumes.map { ["name": $0.name, "path": $0.mountPath] },
                "readBytesPerSecond": diskSnapshot.readBytesPerSecond,
                "writeBytesPerSecond": diskSnapshot.writeBytesPerSecond,
            ],
            "checks": checks,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write("sampler smoke: JSON 序列化失败\n".data(using: .utf8)!)
            exit(2)
        }
        try? data.write(to: URL(fileURLWithPath: outputPath))

        let failed = checks.filter { !($0["passed"] as? Bool ?? false) }
        if failed.isEmpty {
            NSLog("sampler smoke: 全部通过")
            exit(0)
        } else {
            NSLog("sampler smoke: \(failed.count) 项失败 \(failed.map { $0["name"] as? String ?? "" }.joined(separator: ","))")
            exit(1)
        }
    }
    #endif
    #endif
}
