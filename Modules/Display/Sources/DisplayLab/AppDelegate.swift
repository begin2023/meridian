import AppKit
import DisplayCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let embedded: Bool
    private var started = false
    var onShowPreferences: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let windowPresence = WindowPresenceController()
    private let displayManager = DisplayManager()
    let virtualDisplayController = VirtualDisplayController()
    private let overrideService = OverrideService()
    let brightnessKeyController = BrightnessKeyController()
    private let menuBuilder = MenuBuilder()

    private var preferencesController: PreferencesWindowController?

    private static let testEntryArguments: Set<String> = [
        "--display-report",
        "--brightness-test",
        "--mode-test",
        "--virtual-test",
        "--mirror-test",
        "--self-test",
        "--preferences",
        "--menu-report",
    ]

    var isTestSession: Bool {
        !Set(CommandLine.arguments).isDisjoint(with: Self.testEntryArguments)
            || CommandLine.arguments.contains("--test-instance")
    }

    var isEmbedded: Bool { embedded }

    init(embedded: Bool) {
        self.embedded = embedded
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start(handleTestArguments: true)
    }

    func start(handleTestArguments: Bool) {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        menuBuilder.displayManager = displayManager
        menuBuilder.appDelegate = self
        if !embedded {
            configureStatusItem()
        }
        displayManager.startMonitoringDisplayChanges()
        displayManager.refreshBrightnessCache()
        configureDisplayChangeHandling()
        if !embedded {
            configureBrightnessKeys()
        }
        if handleTestArguments {
            dispatchTestEntryPoints()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    func stop() {
        guard started else { return }
        started = false
        brightnessKeyController.stop()
        displayManager.onDisplaysChanged = nil
        displayManager.stopMonitoringDisplayChanges()
        // Restore the display arrangement before the virtual screen is
        // destroyed: detach the mirror, then drop the screen. If the process
        // dies without this, WindowServer still collapses the mirror set
        // when the virtual display disappears.
        try? virtualDisplayController.teardownMirroredUpsample()
        SoftwareDimming.shared.restoreAllSynchronously()
        virtualDisplayController.disconnectAll()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        preferencesController?.close()
        preferencesController = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowPresence.bringForward()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "preferences":
                showPreferences()
            default:
                break
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }

    // MARK: - Status item

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = AppTheme.symbol("display", size: 16, weight: .semibold)
            button.image?.isTemplate = true
            button.toolTip = "DisplayLab"
        }
        menuBuilder.displayManager = displayManager
        menuBuilder.appDelegate = self
        statusItem?.menu = menuBuilder.buildMenu()
    }

    func rebuildMenu() {
        statusItem?.menu = menuBuilder.buildMenu()
    }

    func makeMenu() -> NSMenu {
        menuBuilder.displayManager = displayManager
        menuBuilder.appDelegate = self
        return menuBuilder.buildMenu()
    }

    func showMenu() {
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func settingsDidChange() {
        if !embedded {
            brightnessKeyController.start()
        }
        refreshStatusItem()
    }

    func refreshDisplays() {
        displayManager.refresh()
    }

    func summary() -> [String: Any] {
        let displays = displayManager.displays.map { display -> [String: Any] in
            var value: [String: Any] = [
                "id": display.identifier,
                "name": display.name,
                "isBuiltIn": display.isBuiltIn,
                "isVirtual": display.isVirtual,
                "pixelWidth": display.pixelWidth,
                "pixelHeight": display.pixelHeight,
                "scale": display.scale,
                "modeCount": display.modes.count,
                "hidpiModeCount": display.hidpiModes.count,
            ]
            if let mode = display.currentMode {
                value["currentMode"] = [
                    "label": mode.label,
                    "pixelWidth": mode.pixelWidth,
                    "pixelHeight": mode.pixelHeight,
                    "refreshRate": mode.refreshRate,
                    "isHiDPI": mode.isHiDPI,
                ]
            }
            if let controller = displayManager.brightnessController(for: display.identifier) {
                value["brightnessBackend"] = String(describing: controller.backendKind)
                value["cachedBrightness"] = displayManager.cachedBrightness(for: display.identifier)
            }
            return value
        }
        return [
            "embedded": embedded,
            "displayCount": displays.count,
            "displays": displays,
            "activeVirtualDisplayCount": virtualDisplayController.activeSpecs.count,
            "mirrorUpsampleActive": virtualDisplayController.activeMirrorSession != nil,
        ]
    }

    // MARK: - Actions

    @objc func showPreferences() {
        if embedded {
            onShowPreferences?()
            return
        }
        if preferencesController == nil {
            let controller = PreferencesWindowController()
            controller.windowPresence = windowPresence
            preferencesController = controller
        }
        preferencesController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func writeDisplayReport() {
        let report = DisplayReportBuilder.build(manager: displayManager, probeDDC: true)
        writeJSON(report, to: "/tmp/displaylab-display-report.json")
    }

    @objc func switchMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModeSelection else { return }
        // 借位模式（同刷新率下没有同比例的真实链路时序）会把画面压进别的分辨率。
        // 菜单本身已过滤，这里再挡一层，防止其它入口绕过。
        if let info = displayManager.display(with: selection.displayIdentifier),
           !ModeValidation.isRenderable(selection.mode, in: info.modes) {
            let alert = NSAlert()
            alert.messageText = "切换分辨率失败"
            alert.informativeText = DisplayBridgeError.unsupportedMode(selection.mode).localizedDescription
            alert.runModal()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ModeService.apply(mode: selection.mode, to: selection.displayIdentifier)
                DispatchQueue.main.async {
                    self?.displayManager.refresh()
                    self?.refreshStatusItem()
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "切换分辨率失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Switches the display back to its native pixel dimensions at the
    /// highest advertised refresh rate. Tears down an active upsample mirror
    /// first — a mirrored panel is not directly switchable.
    @objc func restoreNativeMode(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? CGDirectDisplayID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let session = self.virtualDisplayController.activeMirrorSession,
               session.physicalDisplayID == identifier {
                try? self.virtualDisplayController.teardownMirroredUpsample()
                self.displayManager.refresh()
                self.refreshStatusItem()
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let mode = try self.nativeMode(for: identifier)
                    try ModeService.apply(mode: mode, to: identifier)
                    DispatchQueue.main.async {
                        self.displayManager.refresh()
                        self.refreshStatusItem()
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "恢复原生分辨率失败"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }
    }

    // MARK: - Software HiDPI upsample (virtual screen mirror)

    /// Single user-initiated attempt; on any failure the virtual screen is
    /// dropped and the physical display is left as it was.
    @objc func enableUpsample(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? UpsampleSelection,
              let display = displayManager.display(with: selection.displayIdentifier) else { return }
        // Virtual display creation and mirror configuration run on the main
        // thread (the creation recipe pumps the main run loop).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let info = CoreDisplayBridge.createInfoDictionary(for: selection.displayIdentifier)
                let nativeWidth = info?["kCGDisplayPixelWidth"] as? Int ?? display.pixelWidth
                let nativeHeight = info?["kCGDisplayPixelHeight"] as? Int ?? display.pixelHeight
                let refresh = display.currentMode?.refreshRate ?? 60
                let spec = VirtualDisplayController.Spec(
                    name: selection.hiDPI ? "DisplayLab 上采样 HiDPI" : "DisplayLab 上采样",
                    pixelWidth: nativeWidth * 2,
                    pixelHeight: nativeHeight * 2,
                    refreshRate: refresh,
                    hiDPI: selection.hiDPI
                )
                let session = try self.virtualDisplayController.createMirroredUpsample(for: selection.displayIdentifier, spec: spec)
                self.displayManager.refresh()
                self.refreshStatusItem()
                let alert = NSAlert()
                alert.messageText = "上采样已开启"
                let effect = selection.hiDPI
                    ? "桌面布局大小不变，但按 2× 渲染再缩到面板，窗口文字更细腻。"
                    : "桌面变成 \(session.spec.pixelWidth)×\(session.spec.pixelHeight) 逻辑像素（4 倍工作区），UI 明显变小，系统将高分辨率画面缩放到物理屏幕。"
                alert.informativeText = """
                \(effect)

                随时可在菜单里关闭，退出 DisplayLab 也会自动还原。
                注意：切换后个别应用的状态栏图标可能显示异常（macOS 已知表现），重启对应应用即恢复。
                """
                alert.runModal()
            } catch {
                self.displayManager.refresh()
                self.refreshStatusItem()
                let alert = NSAlert()
                alert.messageText = "开启上采样失败"
                alert.informativeText = "\(error.localizedDescription)\n\n显示器未被改动。"
                alert.runModal()
            }
        }
    }

    @objc func disableUpsample(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                try self.virtualDisplayController.teardownMirroredUpsample()
            } catch {
                let alert = NSAlert()
                alert.messageText = "关闭上采样失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
            self.displayManager.refresh()
            self.refreshStatusItem()
        }
    }

    private func nativeMode(for identifier: CGDirectDisplayID) throws -> DisplayModeInfo {
        guard let display = displayManager.display(with: identifier) else {
            throw ModeServiceError.configurationFailed("找不到该显示器。")
        }
        let info = CoreDisplayBridge.createInfoDictionary(for: identifier)
        let nativeWidth = info?["kCGDisplayPixelWidth"] as? Int ?? 0
        let nativeHeight = info?["kCGDisplayPixelHeight"] as? Int ?? 0
        guard nativeWidth > 0, nativeHeight > 0 else {
            throw ModeServiceError.configurationFailed("无法确定原生分辨率。")
        }
        guard let best = display.sortedModes
            .filter({ $0.pixelWidth == nativeWidth && $0.pixelHeight == nativeHeight })
            .max(by: { $0.refreshRate < $1.refreshRate }) else {
            throw ModeServiceError.configurationFailed("模式列表里没有原生分辨率（\(nativeWidth)×\(nativeHeight)）。")
        }
        return best
    }

    /// Mode changes reconfigure the whole display stack; rebuild the menu and
    /// force the status item to redraw so the icon never stays stale.
    func refreshStatusItem() {
        statusItem?.menu = menuBuilder.buildMenu()
        if let button = statusItem?.button {
            button.image = AppTheme.symbol("display", size: 16, weight: .semibold)
            button.image?.isTemplate = true
            button.needsDisplay = true
        }
    }

    @objc func brightnessSliderChanged(_ sender: NSSlider) {
        guard let row = sender.superview as? BrightnessSliderRow else { return }
        row.refreshValueLabel()
        let fraction = row.currentFraction
        guard let controller = displayManager.brightnessController(for: row.displayIdentifier) else { return }
        displayManager.updateCachedBrightness(fraction, for: row.displayIdentifier)
        controller.setTarget(fraction, smooth: false)
    }

    @objc func createVirtualScreen(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? VirtualDisplayController.Spec else { return }
        DispatchQueue.main.async { [weak self] in
            do {
                _ = try self?.virtualDisplayController.create(spec: spec)
                self?.displayManager.refresh()
            } catch {
                let alert = NSAlert()
                alert.messageText = "创建虚拟屏幕失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func disconnectVirtualScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        virtualDisplayController.disconnect(id: id)
        displayManager.refresh()
    }

    @objc func disconnectAllVirtualScreens() {
        virtualDisplayController.disconnectAll()
        displayManager.refresh()
    }

    @objc func enableDisplayOverride(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? CGDirectDisplayID,
              let display = displayManager.display(with: identifier) else { return }
        runOverrideFlow { [weak self] in
            guard let self else { return nil }
            if !self.overrideService.isInstalled {
                try self.overrideService.install()
            }
            return try await self.overrideService.installOverride(for: display)
        }
    }

    @objc func removeDisplayOverride(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? CGDirectDisplayID,
              let display = displayManager.display(with: identifier) else { return }
        runOverrideFlow { [weak self] in
            guard let self else { return nil }
            if !self.overrideService.isInstalled {
                throw OverrideService.OverrideError.daemonNotInstalled
            }
            return try await self.overrideService.removeOverride(for: display)
        }
    }

    /// Shared plumbing for the override flows: helper registration, XPC call,
    /// result alert. All dialog work happens on the main queue.
    private func runOverrideFlow(_ operation: @escaping () async throws -> String?) {
        Task { @MainActor in
            do {
                if let message = try await operation() {
                    let alert = NSAlert()
                    alert.messageText = "显示器覆盖"
                    alert.informativeText = message
                    alert.runModal()
                }
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "显示器覆盖操作失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func configureDisplayChangeHandling() {
        displayManager.onDisplaysChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshStatusItem()
                // A mode change swaps the backing scale; WindowServer settles
                // the status item layout slightly later, so re-render the
                // icon once more after things have landed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self?.refreshStatusItem()
                }
            }
        }
    }

    private func configureBrightnessKeys() {
        brightnessKeyController.displayManager = displayManager
        brightnessKeyController.onPermissionMissing = { [weak self] in
            self?.showBrightnessKeyPermissionHint()
        }
        brightnessKeyController.start()
    }

    private func showBrightnessKeyPermissionHint() {
        guard AppSettings.shared.takeOverBrightnessKeys, !brightnessKeyController.permissionAvailable else { return }
        NSLog("DisplayLab: F1/F2 takeover needs Input Monitoring permission (grant in System Settings, then toggle the preference).")
    }

    @objc func toggleHDR(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? CGDirectDisplayID else { return }
        let target = !(HDRService.isEnabled(identifier) ?? false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let applied = HDRService.setEnabled(target, for: identifier)
            DispatchQueue.main.async {
                self?.displayManager.refresh()
                if applied != target {
                    let alert = NSAlert()
                    alert.messageText = "HDR 未能切换"
                    alert.informativeText = target
                        ? "开启 HDR 未生效，请改用 系统设置 → 显示器 → HDR。"
                        : "关闭 HDR 未生效，请改用 系统设置 → 显示器 → HDR。"
                    alert.runModal()
                }
            }
        }
    }

    @objc func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Test entry points

    private func dispatchTestEntryPoints() {
        let arguments = CommandLine.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if arguments.contains("--display-report") {
                self.writeDisplayReport()
                exit(0)
            }
            if arguments.contains("--brightness-test") {
                BrightnessTest.run(displayManager: self.displayManager)
            }
            if arguments.contains("--mode-test") {
                ModeTest.run(displayManager: self.displayManager)
            }
            if arguments.contains("--virtual-test") {
                VirtualTest.run()
            }
            if arguments.contains("--mirror-test") {
                MirrorTest.run()
            }
            if arguments.contains("--self-test") {
                SelfTest.run()
            }
            if arguments.contains("--preferences") {
                runPreferencesSnapshot()
            }
            if arguments.contains("--menu-report") {
                writeMenuReport()
                exit(0)
            }
        }
    }

    /// Offscreen preference window snapshot for the UI smoke test.
    private func runPreferencesSnapshot() {
        let controller = PreferencesWindowController()
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.writeDebugPNG(to: "/tmp/displaylab-preferences.png")
        exit(0)
    }

    private func writeMenuReport() {
        guard let menu = statusItem?.menu else {
            NSLog("DisplayLab menu report: status menu missing")
            exit(1)
        }
        // Force a population pass with the live display list.
        if let delegate = menu.delegate as? MenuBuilder {
            delegate.menuWillOpen(menu)
        }
        writeJSON(MenuReportBuilder.build(menu: menu), to: "/tmp/displaylab-menu-report.json")
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("DisplayLab failed to write \(path): \(error.localizedDescription)")
        }
    }
}
