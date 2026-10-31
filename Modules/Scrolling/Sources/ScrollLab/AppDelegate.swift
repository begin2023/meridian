import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let tapController = ScrollTapController()
    private let embedded: Bool
    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    private var permissionMonitorTimer: Timer?
    private var started = false
    private var temporarilyPaused = false
    var onShowPreferences: (() -> Void)?

    init(embedded: Bool) {
        self.embedded = embedded
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start(promptForAccessibility: true, handleTestArguments: true)
    }

    func start(promptForAccessibility: Bool, handleTestArguments: Bool) {
        guard !started else { return }
        started = true
        temporarilyPaused = false
        NSApp.setActivationPolicy(.accessory)
        settings.onChange = { [weak self] in
            self?.refreshEngineState()
        }
        tapController.scrollHandler = { event in
            ScrollEngine.handle(event)
        }
        tapController.clickHandler = {
            ScrollAnimator.shared.brake()
        }
        if !embedded {
            configureStatusItem()
        }
        refreshEngineState()
        startPermissionMonitor()

        // 无权限时立即触发系统授权引导（macOS 对辅助功能从不主动弹窗）
        if promptForAccessibility, !tapController.isAccessible {
            ScrollTapController.promptAccessibility()
        }

        guard handleTestArguments else { return }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else if CommandLine.arguments.contains("--preferences") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPreferences()
            }
        } else if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runUISmokeTest()
            }
        } else if CommandLine.arguments.contains("--tap-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                TapSmokeProbe.run()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    func stop() {
        guard started else { return }
        started = false
        temporarilyPaused = false
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = nil
        tapController.disable()
        tapController.scrollHandler = nil
        tapController.clickHandler = nil
        settings.onChange = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        preferencesWindowController?.close()
        preferencesWindowController = nil
    }

    // MARK: - 引擎状态

    func refreshEngineState() {
        if !temporarilyPaused, settings.enabled {
            tapController.enable()
        } else {
            tapController.disable()
        }
        statusItem?.isVisible = !settings.hideStatusItem
        writeDiagnostics()
        refreshMenuState()
    }

    func pauseTemporarily() {
        temporarilyPaused = true
        refreshEngineState()
    }

    func resumeAfterTemporaryPause() {
        temporarilyPaused = false
        refreshEngineState()
    }

    func clearTemporaryPauseForSettingsChange() {
        temporarilyPaused = false
    }

    /// 诊断状态落盘，供 `defaults read app.meridian.scroll` 与脚本核实。
    private func writeDiagnostics() {
        guard !embedded else { return }
        let defaults = UserDefaults.standard
        defaults.set(tapController.isAccessible, forKey: "diagnosticAccessible")
        defaults.set(tapController.isActive, forKey: "diagnosticTapInstalled")
    }

    private func startPermissionMonitor() {
        guard permissionMonitorTimer == nil else { return }
        // 无权限时轮询等待授权，拿到权限自动安装 tap
        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.temporarilyPaused,
               self.settings.enabled,
               !self.tapController.isActive,
               self.tapController.isAccessible {
                self.tapController.enable()
            }
            self.writeDiagnostics()
            self.refreshMenuState()
        }
    }

    /// 引导用户授权：触发系统弹窗 + 打开系统设置辅助功能面板。
    @objc private func openAccessibilitySettings() {
        ScrollTapController.promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 菜单栏

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppTheme.symbol("computermouse", size: 15, weight: .medium)
        item.button?.image?.isTemplate = true
        let menu = NSMenu()

        // 引擎状态（不可点击的说明行）
        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let toggle = NSMenuItem(title: "启用 ScrollLab", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.enabled ? .on : .off
        menu.addItem(toggle)

        let reverse = NSMenuItem(title: "反向滚轮", action: #selector(toggleReverse), keyEquivalent: "")
        reverse.target = self
        reverse.state = settings.reverse ? .on : .off
        menu.addItem(reverse)

        menu.addItem(.separator())

        // 授权引导入口（未授权时可见）
        let permission = NSMenuItem(title: "辅助功能权限设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        let preferences = NSMenuItem(title: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ScrollLab", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    private func refreshMenuState() {
        guard let menu = statusItem?.menu else { return }
        let items = menu.items
        let granted = tapController.isAccessible
        // 状态行固定在菜单第 0 项
        if items.indices.contains(0) {
            let active = tapController.isActive
            if !granted {
                items[0].title = "⚠︎ 等待辅助功能授权"
                items[0].state = .off
            } else if temporarilyPaused {
                items[0].title = "已临时暂停"
                items[0].state = .off
            } else if active {
                items[0].title = "事件拦截运行中"
                items[0].state = .on
            } else {
                items[0].title = settings.enabled ? "事件拦截未生效" : "已停用"
                items[0].state = .off
            }
        }
        // "辅助功能权限设置…" 仅在未授权时显示
        if items.indices.contains(4) {
            items[4].isHidden = tapController.isAccessible
        }
        if items.indices.contains(1) {
            items[1].state = settings.enabled ? .on : .off
        }
        if items.indices.contains(2) {
            items[2].isEnabled = granted
            items[2].state = granted && settings.reverse ? .on : .off
        }
    }

    @objc private func toggleEnabled() {
        settings.setEnabled(!settings.enabled)
        refreshMenuState()
    }

    @objc private func toggleReverse() {
        guard tapController.isAccessible else { return }
        settings.setReverse(!settings.reverse)
        refreshMenuState()
    }

    @objc func showPreferences() {
        if embedded {
            onShowPreferences?()
            return
        }
        let controller: PreferencesWindowController
        if let existing = preferencesWindowController {
            controller = existing
        } else {
            controller = PreferencesWindowController()
            preferencesWindowController = controller
        }
        controller.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 自检

    private func runUISmokeTest() {
        showPreferences()
        guard let controller = preferencesWindowController else {
            print("UISMOKE-DONE missing-controller")
            fflush(stdout)
            return
        }
        // 三个分区分别离屏截图，供脚本逐一检查
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for section in PreferencesWindowController.Section.allCases {
                controller.selectSectionForTest(section)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                let name = "/tmp/scrolllab-prefs-\(section.rawValue).png"
                controller.window?.contentView?.writeDebugPNG(to: URL(fileURLWithPath: name))
            }
            print("UISMOKE-DONE")
            fflush(stdout)
        }
    }

    func summary() -> [String: Any] {
        [
            "enabled": settings.enabled,
            "reverse": settings.reverse,
            "smooth": settings.smooth,
            "accessibilityGranted": tapController.isAccessible,
            "eventTapActive": tapController.isActive,
            "temporarilyPaused": temporarilyPaused,
            "embedded": embedded,
        ]
    }
}

extension NSView {
    /// 用于界面验证的离屏渲染快照。
    @discardableResult
    func writeDebugPNG(to url: URL) -> Bool {
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            NSLog("ScrollLab: debug PNG written to \(url.path)")
            return true
        } catch {
            NSLog("ScrollLab: debug PNG write failed: \(error)")
            return false
        }
    }
}
