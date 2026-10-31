import AppKit
import Combine

enum Page: Hashable {
    case overview
    case feature(Feature)
    case general
}

/// 主窗口当前页面；控制中心、快捷菜单和各模块的“设置”入口都通过它定位。
@MainActor
final class Navigation: ObservableObject {
    @Published var page: Page = .overview
}

/// 应用唯一的协调者：拥有五个功能模型、菜单栏、主窗口和全局快捷键。
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    static let shared = AppCoordinator()

    let preferences = Preferences.shared
    let navigation = Navigation()
    private(set) var capture: CaptureModel!
    private(set) var pointer: PointerModel!
    private(set) var telemetry: TelemetryModel!
    private(set) var display: DisplayModel!
    private(set) var thermal: ThermalModel!
    let conflicts = ConflictMonitor()
    let permissions = PermissionMonitor()

    private var menuBar: MenuBarController!
    private var brightnessHUD: BrightnessHUDController!
    private var mainWindow: MainWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        preferences.applyAppearance()
        installMainMenu()

        capture = CaptureModel(suite: Suites.capture)
        pointer = PointerModel(suite: Suites.pointer)
        telemetry = TelemetryModel()
        display = DisplayModel(suite: Suites.display)
        brightnessHUD = BrightnessHUDController()
        display.onBrightnessHUD = { [weak self] values in
            self?.brightnessHUD.show(values)
        }
        thermal = ThermalModel(suite: Suites.thermal)

        for feature in Feature.allCases where preferences.isEnabled(feature) {
            start(feature)
        }

        menuBar = MenuBarController(coordinator: self)
        HotKeyCenter.shared.handler = { [weak self] action in self?.perform(action) }
        applyHotKeys()

        preferences.$enabledFeatures
            .dropFirst()
            .sink { [weak self] enabled in self?.reconcile(enabled) }
            .store(in: &cancellables)
        preferences.$hotKeys
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyHotKeys() } }
            .store(in: &cancellables)
        permissions.$granted
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.capture.refreshState()
                    self?.pointer.refresh()
                }
            }
            .store(in: &cancellables)
        preferences.$telemetryInterval
            .dropFirst()
            .sink { [weak self] value in self?.telemetry.setInterval(value) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // 截图编辑器等窗口关闭后，模块会把应用切回 accessory；主窗口仍开着时需要恢复 Dock 图标
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self?.reassertActivationPolicy() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permissions.refresh()
                self?.pointer.refresh()
                self?.display.refreshBrightnessKeysStateForUI()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.display.engine.refresh()
                self?.capture.refreshState()
            }
        }
        conflicts.start()

        if preferences.isFirstLaunch {
            preferences.markOnboarded()
            openMain(.overview)
        }
    }

    /// meridian://panel[/cpu|memory|network|disk|thermal] · meridian://open/<overview|capture|display|thermal|pointer|telemetry|general>
    /// · meridian://capture|ocr|pin|gif — 供启动器、快捷指令和脚本调用。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meridian" {
            let host = url.host ?? ""
            let arg = url.pathComponents.dropFirst().first ?? ""
            switch host {
            case "panel":
                let route: PanelRoute
                switch arg {
                case "cpu": route = .cpu
                case "memory": route = .memory
                case "network": route = .network
                case "disk": route = .disk
                case "thermal": route = .thermal
                default: route = .home
                }
                // 等 open 命令把焦点交回后再弹出，避免立即被当作外部点击收起
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.menuBar.toggleControlCenter(route: route)
                }
            case "open":
                if let feature = Feature(rawValue: arg) {
                    openMain(.feature(feature))
                } else {
                    openMain(arg == "general" ? .general : .overview)
                }
            case "fan":
                let presets: [String: ThermalModel.Preset] = ["auto": .automatic, "curve": .curve, "fixed": .fixed, "full": .full]
                if let preset = presets[arg] { thermal.apply(preset) }
            case "resolution":
                // 作用于第一块可上采样的外接屏
                guard let target = display.displays.first(where: { !$0.isBuiltIn && !$0.isOwnVirtual }) else { break }
                switch arg {
                case "5k": display.setUpsample(.hiDPI, for: target.id)
                case "space": display.setUpsample(.moreSpace, for: target.id)
                case "native": display.restoreNative(target.id)
                default: break
                }
            case "brightness":
                if let value = Double(arg) { display.setAllBrightness(min(max(value, 0), 100) / 100) }
            case "close":
                mainWindow?.close()
                menuBar.closeControlCenter()
            case "capture": perform(.capture)
            case "ocr": perform(.ocr)
            case "pin": perform(.pin)
            case "gif": perform(.gif)
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain(navigation.page)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        // 硬件状态先还原：风扇交还系统、撤销上采样与虚拟屏、恢复 gamma
        thermal?.stop()
        display?.stop()
        pointer?.stop()
        capture?.stop()
        telemetry?.stop()
        return .terminateNow
    }

    // MARK: 功能启停

    func isRunning(_ feature: Feature) -> Bool {
        switch feature {
        case .capture: return capture.running
        case .display: return display.running
        case .thermal: return thermal.running
        case .pointer: return pointer.running
        case .telemetry: return telemetry.running
        }
    }

    private func start(_ feature: Feature) {
        switch feature {
        case .capture: capture.start()
        case .display: display.start()
        case .thermal: thermal.start()
        case .pointer: pointer.start()
        case .telemetry: telemetry.start(interval: preferences.telemetryInterval)
        }
    }

    private func stop(_ feature: Feature) {
        switch feature {
        case .capture: capture.stop()
        case .display: display.stop()
        case .thermal: thermal.stop()
        case .pointer: pointer.stop()
        case .telemetry: telemetry.stop()
        }
    }

    private func reconcile(_ enabled: Set<Feature>) {
        for feature in Feature.allCases {
            let shouldRun = enabled.contains(feature)
            if shouldRun && !isRunning(feature) { start(feature) }
            if !shouldRun && isRunning(feature) { stop(feature) }
        }
        applyHotKeys()
        menuBar.rebuildWidgets()
    }

    // MARK: 快捷键

    func applyHotKeys() {
        HotKeyCenter.shared.apply(preferences.hotKeys) { [preferences] action in
            guard let feature = action.feature else { return true }
            return preferences.isEnabled(feature)
        }
        objectWillChangeHotKeys.send()
    }

    /// 快捷键注册结果变化（冲突提示用）。
    let objectWillChangeHotKeys = PassthroughSubject<Void, Never>()

    func perform(_ action: HotKeyAction) {
        switch action {
        case .capture: capture.capture()
        case .ocr: capture.captureOCR()
        case .pin: capture.capturePin()
        case .gif: capture.toggleGIF()
        case .toggleScroll: pointer.togglePause()
        case .controlCenter: menuBar.toggleControlCenter(route: .home)
        }
    }

    // MARK: 窗口

    func openMain(_ page: Page) {
        navigation.page = page
        menuBar?.closeControlCenter()
        if mainWindow == nil {
            mainWindow = MainWindowController(coordinator: self)
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 有可见的普通窗口就显示 Dock 图标，否则只留菜单栏。
    func reassertActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled)
                && window.level == .normal
        }
        let desired: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desired { NSApp.setActivationPolicy(desired) }
    }

    /// 截图类动作先收起控制中心，避免面板出现在截图里。
    func closePanelThen(_ body: @escaping () -> Void) {
        guard menuBar?.isShown == true else { return body() }
        menuBar.closeControlCenter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { body() }
    }

    @objc func showSettings() { openMain(.overview) }
    @objc func showMainWindow() { openMain(navigation.page) }

    // MARK: 单实例

    private func activateExistingInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard let other = others.first else { return false }
        other.activate()
        return true
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Meridian")
        appMenu.addItem(withTitle: "关于 Meridian", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Meridian", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Meridian", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

/// 预留给宿主级冲突提示；不硬编码第三方应用标识，避免误杀用户程序。
@MainActor
final class ConflictMonitor: ObservableObject {
    struct Conflict: Identifiable, Equatable {
        let id: String
        let name: String
        let reason: String
    }

    static let known: [(id: String, name: String, reason: String)] = []

    @Published private(set) var running: [Conflict] = []

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        running = Self.known.filter { ids.contains($0.id) }.map { Conflict(id: $0.id, name: $0.name, reason: $0.reason) }
    }

    func quit(_ conflict: Conflict) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: conflict.id) {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func quitAll() { running.forEach(quit) }
}
