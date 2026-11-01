import AppKit
import Combine
import FanControlLabKit
import MonitoringLabKit
import SwiftUI

/// 菜单栏：一个主图标（左键控制中心、右键快捷菜单）+ 可选的数据小组件。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private unowned let coordinator: AppCoordinator
    private let mainItem: NSStatusItem
    private var widgetItems: [MenuWidget: NSStatusItem] = [:]
    private var widgetContents: [MenuWidget: WidgetRenderer.Content] = [:]
    private let popover = NSPopover()
    private let panelState = PanelState()
    private var cancellables: Set<AnyCancellable> = []
    private weak var anchorButton: NSStatusBarButton?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        mainItem.autosaveName = "meridian.main"
        if let button = mainItem.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Meridian")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(mainClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }

        popover.behavior = .transient
        // 状态栏点击应立即响应；系统开场动画会额外占用约半秒。
        popover.animates = false
        popover.delegate = self
        let root = ControlCenterView(state: panelState, preferences: coordinator.preferences, coordinator: coordinator)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        coordinator.preferences.$appearance
            .sink { [weak self] mode in self?.popover.appearance = mode.appKitAppearance }
            .store(in: &cancellables)

        coordinator.preferences.$menuWidgets
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuildWidgets() } }
            .store(in: &cancellables)
        coordinator.telemetry.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
            self.renderWidgets(only: [.cpu, .memory, .network, .disk], snapshot: snapshot,
                                   reading: self.coordinator.thermal.reading)
            }
            .store(in: &cancellables)
        coordinator.thermal.$reading
            .sink { [weak self] reading in
                guard let self else { return }
                self.renderWidgets(only: [.temperature, .fan], snapshot: self.coordinator.telemetry.snapshot,
                                   reading: reading)
            }
            .store(in: &cancellables)
    }

    // MARK: 控制中心

    @objc private func mainClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu(includeQuit: true)
        } else {
            toggleControlCenter(route: .home, from: sender)
        }
    }

    func toggleControlCenter(route: PanelRoute, from button: NSStatusBarButton? = nil) {
        let anchor = button ?? mainItem.button
        if popover.isShown {
            if anchor === anchorButton {
                // 同一个入口再点一次是收起；从面板内其他路由切换则原地换页
                if panelState.route == route { popover.performClose(nil) } else { panelState.route = route }
                return
            }
            popover.close()
        }
        guard let anchor else { return }
        panelState.route = route
        panelState.isPresented = true
        anchorButton = anchor
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closeControlCenter() {
        if popover.isShown { popover.performClose(nil) }
    }

    var isShown: Bool { popover.isShown }

    func popoverDidClose(_ notification: Notification) {
        // 换锚点时会先关后开，关闭回调可能晚到；面板仍显示时不要重置页面
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.panelState.isPresented = false
            self.panelState.route = .home
        }
    }

    private func showQuickMenu(includeQuit: Bool = true) {
        let menu = NSMenu()
        let prefs = coordinator.preferences
        func add(_ title: String, _ symbol: String, _ key: HotKeyAction? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let key, let combo = prefs.hotKeys[key] {
                item.title = "\(title)    \(combo.displayString)"
            }
            menu.addItem(item)
        }
        if prefs.isEnabled(.capture) {
            add("截图", "viewfinder", .capture) { [weak self] in self?.coordinator.capture.capture() }
            add("截图识字", "text.viewfinder", .ocr) { [weak self] in self?.coordinator.capture.captureOCR() }
            add("截图并贴图", "pin", .pin) { [weak self] in self?.coordinator.capture.capturePin() }
            add(coordinator.capture.gifRecording ? "停止 GIF 录制" : "录制 GIF", "record.circle", .gif) { [weak self] in
                self?.coordinator.capture.toggleGIF()
            }
            add("截图历史", "clock.arrow.circlepath") { [weak self] in self?.coordinator.capture.showHistory() }
            menu.addItem(.separator())
        }
        if prefs.isEnabled(.pointer) {
            add(coordinator.pointer.paused ? "恢复滚动增强" : "暂停滚动增强", "computermouse", .toggleScroll) { [weak self] in
                self?.coordinator.pointer.togglePause()
            }
            menu.addItem(.separator())
        }
        add("打开 Meridian", "macwindow") { [weak self] in self?.coordinator.openMain(.overview) }
        add("设置…", "gearshape") { [weak self] in self?.coordinator.openMain(.overview) }
        if includeQuit {
            menu.addItem(.separator())
            add("退出 Meridian", "power") { NSApp.terminate(nil) }
        }
        mainItem.menu = menu
        mainItem.button?.performClick(nil)
        mainItem.menu = nil
    }

    // MARK: 小组件

    func rebuildWidgets() {
        let prefs = coordinator.preferences
        let wanted = prefs.menuWidgets.filter { prefs.isEnabled($0.feature) }
        for (widget, item) in widgetItems where !wanted.contains(widget) {
            NSStatusBar.system.removeStatusItem(item)
            widgetItems.removeValue(forKey: widget)
            widgetContents.removeValue(forKey: widget)
        }
        // 倒序创建：新建的状态项出现在最左侧，最终顺序与设置中一致
        for widget in wanted.reversed() where widgetItems[widget] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "meridian.widget.\(widget.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(widgetClicked(_:))
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
            item.button?.identifier = NSUserInterfaceItemIdentifier(widget.rawValue)
            item.button?.imagePosition = .imageOnly
            widgetItems[widget] = item
        }
        renderWidgets(only: MenuWidget.allCases, snapshot: coordinator.telemetry.snapshot,
                      reading: coordinator.thermal.reading)
    }

    @objc private func widgetClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let widget = MenuWidget(rawValue: raw) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu(includeQuit: false)
            return
        }
        let route: PanelRoute
        switch widget {
        case .cpu: route = .cpu
        case .memory: route = .memory
        case .network: route = .network
        case .disk: route = .disk
        case .temperature, .fan: route = .thermal
        }
        toggleControlCenter(route: route, from: sender)
    }

    private func renderWidgets(only widgets: [MenuWidget], snapshot: SystemSnapshot, reading: ThermalReading?) {
        for widget in widgets {
            guard let button = widgetItems[widget]?.button else { continue }
            let content = WidgetRenderer.content(for: widget, snapshot: snapshot, reading: reading)
            guard widgetContents[widget] != content else { continue }
            widgetContents[widget] = content
            button.image = WidgetRenderer.image(for: content)
        }
    }
}

/// 两行紧凑文字的菜单栏小组件；模板图像，自动适配菜单栏深浅色。
enum WidgetRenderer {
    enum Content: Equatable {
        case twoLine(top: String, bottom: String, width: CGFloat)
        case stacked(lines: [String], width: CGFloat)
    }

    static func content(for widget: MenuWidget, snapshot s: SystemSnapshot, reading: ThermalReading?) -> Content {
        switch widget {
        case .cpu:
            return .twoLine(top: "CPU", bottom: Format.percent(s.cpuPercent), width: 30)
        case .memory:
            return .twoLine(top: "内存", bottom: Format.percent(s.memoryFraction * 100), width: 30)
        case .network:
            return .stacked(lines: ["↑ " + Format.compactRate(s.netUpPerSecond) + "/s",
                                   "↓ " + Format.compactRate(s.netDownPerSecond) + "/s"], width: 54)
        case .disk:
            let root = s.volumes.first { $0.mountPath == "/" } ?? s.volumes.first
            let used = root.map { Format.percent($0.usedFraction * 100) } ?? "--"
            return .twoLine(top: "磁盘", bottom: used, width: 30)
        case .temperature:
            let value = reading?.cpuAverage.map { "\(Int($0.rounded()))°" } ?? "--"
            return .twoLine(top: "温度", bottom: value, width: 30)
        case .fan:
            let rpm = reading?.fans.first.map { "\(Int($0.currentRPM.rounded()))" } ?? "--"
            return .twoLine(top: "风扇", bottom: rpm, width: 34)
        }
    }

    static func image(for content: Content) -> NSImage {
        switch content {
        case .twoLine(let top, let bottom, let width): return twoLine(top: top, bottom: bottom, width: width)
        case .stacked(let lines, let width): return stacked(lines: lines, width: width)
        }
    }

    private static func twoLine(top: String, bottom: String, width: CGFloat) -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let topAttr: [NSAttributedString.Key: Any] = [.font: topFont, .foregroundColor: NSColor.black]
        let bottomAttr: [NSAttributedString.Key: Any] = [.font: bottomFont, .foregroundColor: NSColor.black]
        let topSize = (top as NSString).size(withAttributes: topAttr)
        let bottomSize = (bottom as NSString).size(withAttributes: bottomAttr)
        let w = max(width, ceil(max(topSize.width, bottomSize.width)) + 2)
        let image = NSImage(size: NSSize(width: w, height: 22), flipped: true) { _ in
            (top as NSString).draw(at: NSPoint(x: (w - topSize.width) / 2, y: 0.5), withAttributes: topAttr)
            (bottom as NSString).draw(at: NSPoint(x: (w - bottomSize.width) / 2, y: 8.5), withAttributes: bottomAttr)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func stacked(lines: [String], width: CGFloat) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let w = max(width, lines.map { ceil(($0 as NSString).size(withAttributes: attr).width) }.max() ?? width)
        let image = NSImage(size: NSSize(width: w, height: 22), flipped: true) { _ in
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 0, y: 0.5 + CGFloat(index) * 10.5), withAttributes: attr)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
