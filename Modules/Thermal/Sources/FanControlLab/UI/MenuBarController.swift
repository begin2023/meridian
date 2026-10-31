import AppKit

/// 菜单栏常驻入口：转速/温度标题 + 只读传感器与中央设置入口。
/// 菜单对象全生命周期只创建一次：结构重建只发生在 menuNeedsUpdate（即将打开），
/// 打开期间仅原位更新动态条目标题——否则跟踪中的菜单被整体替换会抛 AppKit 异常。
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var latestUpdate: MonitorUpdate?

    /// 动态条目：菜单打开期间原位刷新标题用。
    private var dynamicItems: [(item: NSMenuItem, text: (MonitorUpdate?) -> String)] = []

    var openPreferencesHandler: (() -> Void)?
    var openMainWindowHandler: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.image = Self.makeFanIcon()
        }
        configureTitle()
    }

    func apply(_ update: MonitorUpdate) {
        latestUpdate = update
        configureTitle(with: update)
        refreshDynamicTitles()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - 标题（单行：[扇形图标] RPM · 温度）

    private func configureTitle(with update: MonitorUpdate? = nil) {
        guard let button = statusItem.button else { return }
        let snapshot = update ?? latestUpdate
        var rpmText = "— RPM"
        var temperature: String?
        if let fan = snapshot?.fans.first {
            rpmText = String(format: "%.0f RPM", fan.currentRPM)
            if AppSettings.shared.menuBarShowsTemperature {
                let settings = AppSettings.shared
                if let cpu = MonitorUpdate.groupAverage(of: snapshot?.sensors ?? [], kind: .cpu) {
                    temperature = settings.formattedTemperature(cpu)
                }
            }
        }
        statusItem.length = NSStatusItem.variableLength
        button.attributedTitle = NSAttributedString()
        if let temperature {
            button.title = "\(rpmText) · \(temperature)"
        } else {
            button.title = rpmText
        }
        button.font = AppTheme.font(ofSize: 12, weight: .medium)
    }

    /// 菜单栏风扇图标（SF Symbol 多级回退）。
    private static func makeFanIcon() -> NSImage? {
        for name in ["fan", "fanblades", "fan.ceiling", "fan.floor"] {
            if let base = NSImage(systemSymbolName: name, accessibilityDescription: "风扇"),
               let configured = base.withSymbolConfiguration(
                   NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
               ) {
                return configured
            }
        }
        return nil
    }

    private func refreshDynamicTitles() {
        for (item, text) in dynamicItems {
            item.title = text(latestUpdate)
        }
    }

    // MARK: - 菜单构建

    private func rebuildMenu() {
        menu.removeAllItems()
        dynamicItems.removeAll()

        let snapshot = latestUpdate

        if let fans = snapshot?.fans, !fans.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.headerItem("风扇列表："))
            for fan in fans {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                dynamicItems.append((item: item, text: { update in
                    guard let fan = update?.fans.first(where: { $0.index == fan.index }) else {
                        return String(format: "%@　%.0f RPM", fan.name, fan.currentRPM)
                    }
                    return String(
                        format: "%@　%.0f RPM（%.0f–%.0f）｜系统自动控制",
                        fan.name, fan.currentRPM, fan.minimumRPM, fan.maximumRPM
                    )
                }))
                item.title = dynamicItems.last!.text(snapshot)
                menu.addItem(item)
            }

            menu.addItem(.separator())
            menu.addItem(Self.headerItem("只读监控 · 风扇写入未启用"))
        }

        menu.addItem(.separator())

        let mainWindow = NSMenuItem(
            title: "传感器详情…",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        )
        mainWindow.target = self
        mainWindow.isEnabled = true
        menu.addItem(mainWindow)

        let preferences = NSMenuItem(title: "设置…", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        preferences.isEnabled = true
        menu.addItem(preferences)

        let quit = NSMenuItem(title: "退出 FanControlLab", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private static func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 动作

    @objc private func openPreferences() {
        openPreferencesHandler?()
    }

    @objc private func openMainWindow() {
        openMainWindowHandler?()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
