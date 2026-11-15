import AppKit
import MeridianLocalization
import SwiftUI

// MARK: - 风扇与温度

struct ThermalPage: View {
    @ObservedObject var model: ThermalModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
            HStack(spacing: 10) {
                ForEach(ThermalModel.Preset.allCases) { preset in
                    ActionTile(symbol: preset.symbol, title: preset.title, tint: .orange,
                               active: model.overallPreset == preset) { model.apply(preset) }
                }
            }
            ThermalDetail(model: model, showsSensorsLimit: nil)

            Group2(title: L("控制服务", "Control Service"), footer: L("手动/温控模式由一个 root 后台服务写入风扇控制寄存器。Meridian 退出、崩溃或服务失联约 5 秒后，风扇自动交还系统控制。", "Manual and curve modes are applied by a root background service that writes the fan control registers. If Meridian quits, crashes, or loses the service for about 5 seconds, fans return to system control automatically.")) {
                Row(title: L("风扇控制服务", "Fan Control Service"), detail: daemonDetail) {
                    HStack {
                        if model.helperBusy { ProgressView().controlSize(.mini) }
                        StatusDot(on: model.daemonInstalled)
                        Button(model.daemonNeedsUpdate ? L("更新…", "Update…") : model.daemonInstalled ? L("重新安装", "Reinstall") : L("安装…", "Install…")) { model.installDaemon() }
                            .disabled(model.helperBusy)
                        if model.daemonInstalled {
                            Button(L("移除", "Remove")) { model.uninstallDaemon() }
                                .disabled(model.helperBusy)
                        }
                    }
                }
            }

            Group2(title: L("偏好", "Preferences")) {
                SliderRow(title: L("刷新间隔", "Refresh Interval"), value: $model.refreshInterval, range: 1...5, step: 0.5,
                          format: { String(format: L("%.1f 秒", "%.1f s"), $0) }, onCommit: model.saveSettings)
                SliderRow(title: L("最高转速上限", "Maximum Speed Limit"), value: $model.maxFraction, range: 0.5...1, step: 0.05,
                          format: { "\(Int($0 * 100))%" }, onCommit: model.saveSettings)
                SliderRow(title: L("温控默认起点", "Default Curve Start"), value: $model.defaultIncreaseAt, range: 40...90, step: 1,
                          format: { "\(Int($0))°C" }, onCommit: model.saveSettings)
                SliderRow(title: L("温控默认满速", "Default Curve Full Speed"), value: $model.defaultMaxAt, range: 60...105, step: 1,
                          format: { "\(Int($0))°C" }, onCommit: model.saveSettings)
                Row(title: L("使用华氏度", "Use Fahrenheit")) {
                    Toggle("", isOn: $model.fahrenheit).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.fahrenheit) { _, _ in model.saveSettings() }
                }
            }
            MenuWidgetToggles(preferences: preferences, widgets: [.temperature, .fan])
        }
    }

    private var daemonDetail: String {
        if !model.daemonInstalled { return L("未安装：切换到非自动模式时会请求管理员授权安装", "Not installed: you'll be asked for administrator approval when switching away from System Auto") }
        if model.daemonNeedsUpdate { return L("已安装，但与当前版本不一致；点“更新…”后才能使用新的控制逻辑", "Installed, but out of date; click “Update…” to use the new control logic") }
        return L("已安装并运行", "Installed and running")
    }
}

// MARK: - 鼠标滚动

struct PointerPage: View {
    @ObservedObject var model: PointerModel
    @ObservedObject var preferences: Preferences
    @Local private var step = 33.6
    @Local private var speed = 2.7
    @Local private var duration = 4.35

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PermissionBanner(permission: .accessibility, granted: model.accessibilityGranted) { model.requestPermission() }
            if let error = model.lastError {
                InlineMessage(text: error) { model.lastError = nil }
            }

            Group2(title: L("状态", "Status")) {
                Row(title: L("滚动增强", "Scroll Enhancement"), detail: statusText) {
                    HStack {
                        Button(model.paused ? L("恢复", "Resume") : L("临时暂停", "Pause")) { model.togglePause() }
                            .disabled(!model.enabled)
                        Toggle("", isOn: Binding(get: { model.enabled }, commit: { model.set("enabled", $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: HotKeyAction.toggleScroll.title, detail: L("例如玩游戏时快速切回系统原生滚动", "For example, quickly switch back to native scrolling while gaming")) {
                    HotKeyRecorder(action: .toggleScroll, preferences: preferences)
                }
            }

            Group2(title: L("平滑滚动", "Smooth Scrolling"), footer: L("只作用于鼠标滚轮；触控板和已经平滑的事件原样放行。", "Applies to mouse wheels only; trackpad and already-smooth events pass through unchanged.")) {
                Row(title: L("启用平滑", "Enable Smoothing")) {
                    Toggle("", isOn: Binding(get: { model.accessibilityGranted && model.smooth }, commit: { model.set("smooth", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted)
                }
                Row(title: L("方向", "Direction")) {
                    HStack {
                        Toggle(L("垂直", "Vertical"), isOn: Binding(get: { model.smoothVertical }, commit: { model.set("smoothVertical", $0) }))
                        Toggle(L("水平", "Horizontal"), isOn: Binding(get: { model.smoothHorizontal }, commit: { model.set("smoothHorizontal", $0) }))
                    }
                    .disabled(!model.accessibilityGranted || !model.smooth)
                }
                Row(title: L("模拟触控板", "Simulate Trackpad"), detail: L("让应用按触控板惯性处理，部分应用里更顺滑", "Lets apps apply trackpad momentum; smoother in some apps")) {
                    Toggle("", isOn: Binding(get: { model.simulateTrackpad }, commit: { model.set("smoothSimTrackpad", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted || !model.smooth)
                }
                SliderRow(title: L("步长", "Step Size"), value: $step, range: 1...200, step: 0.1, format: { String(format: "%.1f", $0) }) {
                    model.set("step", step)
                }
                SliderRow(title: L("速度", "Speed"), value: $speed, range: 0.1...10, step: 0.1, format: { String(format: "%.1f×", $0) }) {
                    model.set("speed", speed)
                }
                SliderRow(title: L("过渡", "Duration"), value: $duration, range: 0.1...5, step: 0.05, format: { String(format: "%.2f", $0) }) {
                    model.set("duration", duration)
                }
                Row(title: L("恢复默认手感", "Restore Default Feel")) {
                    Button(L("恢复", "Restore")) {
                        step = 33.6; speed = 2.7; duration = 4.35
                        model.set("step", step); model.set("speed", speed); model.set("duration", duration)
                    }
                }
            }

            Group2(title: L("反转方向", "Reverse Direction"), footer: L("让鼠标滚轮与触控板“自然滚动”方向相反，两者各用各的习惯。", "Makes the mouse wheel scroll opposite to the trackpad's “natural scrolling”, so each keeps its own habit.")) {
                Row(title: L("反转滚轮方向", "Reverse Wheel Direction")) {
                    Toggle("", isOn: Binding(get: { model.accessibilityGranted && model.reverse }, commit: { model.set("reverse", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted)
                }
                Row(title: L("方向", "Direction")) {
                    HStack {
                        Toggle(L("垂直", "Vertical"), isOn: Binding(get: { model.reverseVertical }, commit: { model.set("reverseVertical", $0) }))
                        Toggle(L("水平", "Horizontal"), isOn: Binding(get: { model.reverseHorizontal }, commit: { model.set("reverseHorizontal", $0) }))
                    }
                    .disabled(!model.accessibilityGranted || !model.reverse)
                }
            }

            Group2(title: L("按应用设置", "Per-App Settings"), footer: model.allowlist
                   ? L("只在下列应用中处理滚轮。每个应用的平滑与反向可以跟随全局，也可以单独开关。", "Only the apps below are handled. Smoothing and reversing can follow the global settings or be switched on or off per app.")
                   : L("平滑与反向可以按应用单独开关，不受上面全局开关影响；选“跟随全局”则沿用全局设置。两项都设为“关”即完全不处理该应用。", "Smoothing and reversing can be switched on or off per app, independent of the global switches above; “Global” follows them. Set both to Off to leave an app untouched.")) {
                Row(title: L("规则模式", "Rule Mode")) {
                    Picker("", selection: Binding(get: { model.allowlist }, commit: { model.set("allowlist", $0) })) {
                        Text(L("排除列表中的应用", "Exclude Listed Apps")).tag(false)
                        Text(L("仅列表中的应用", "Only Listed Apps")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                ForEach(model.exceptions) { entry in
                    ExceptionRow(model: model, entry: entry)
                }
                Row(title: model.exceptions.isEmpty ? L("还没有单独设置的应用", "No per-app settings yet") : L("添加更多应用", "Add More Apps")) {
                    Button(L("添加应用…", "Add App…")) { model.addException() }
                }
            }
        }
        .onAppear {
            step = model.step; speed = model.speed; duration = model.duration
            model.refresh()
        }
    }

    private var statusText: String {
        if !model.accessibilityGranted { return L("等待辅助功能权限，授权后自动生效", "Waiting for Accessibility permission; takes effect once granted") }
        if !model.enabled { return L("已关闭", "Off") }
        if model.paused { return L("已临时暂停（不改变设置）", "Paused (settings unchanged)") }
        return model.tapActive ? L("正在工作", "Active") : L("正在启动…", "Starting…")
    }
}

private struct ExceptionRow: View {
    @ObservedObject var model: PointerModel
    let entry: ScrollException
    @Local private var expanded = false
    @Local private var step = 33.6
    @Local private var speed = 2.7
    @Local private var duration = 4.35

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: entry.icon).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.system(size: 13))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(entry.inherit ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain).help(L("手感参数", "Feel Settings"))
                Button {
                    model.removeException(entry.id)
                } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help(L("移除", "Remove"))
            }
            HStack(spacing: 18) {
                modePicker(L("平滑", "Smooth"), \.smoothMode)
                modePicker(L("反向", "Reverse"), \.reverseMode)
                Spacer(minLength: 0)
            }
            .padding(.leading, 32)
            .disabled(!model.accessibilityGranted)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("使用单独的步长、速度和过渡", "Use custom step, speed and duration"),
                           isOn: Binding(get: { !entry.inherit }, commit: { custom in
                               var copy = entry
                               copy.inherit = !custom
                               if custom { copy.step = model.step; copy.speed = model.speed; copy.duration = model.duration }
                               model.updateException(copy)
                               step = copy.step; speed = copy.speed; duration = copy.duration
                           }))
                    .controlSize(.small)
                    if !entry.inherit {
                        SliderRow(title: L("步长", "Step Size"), value: $step, range: 1...200, step: 0.1,
                                  format: { String(format: "%.1f", $0) }) { commit { $0.step = step } }
                        SliderRow(title: L("速度", "Speed"), value: $speed, range: 0.1...10, step: 0.1,
                                  format: { String(format: "%.1f×", $0) }) { commit { $0.speed = speed } }
                        SliderRow(title: L("过渡", "Duration"), value: $duration, range: 0.1...5, step: 0.05,
                                  format: { String(format: "%.2f", $0) }) { commit { $0.duration = duration } }
                    }
                }
                .padding(.leading, 32)
                .transition(.opacity)
            }
        }
        .onAppear { step = entry.step; speed = entry.speed; duration = entry.duration }
    }

    /// 一眼看出这个应用最终的效果（已把“跟随全局”解析成当前全局值）。
    private var summary: String {
        let smooth = resolved(entry.smoothMode, global: model.smooth)
        let reverse = resolved(entry.reverseMode, global: model.reverse)
        let parts = [
            smooth ? L("平滑", "Smooth") : L("不平滑", "No smoothing"),
            reverse ? L("反向", "Reversed") : L("原方向", "Normal direction"),
        ]
        var text = parts.joined(separator: " · ")
        if !entry.inherit { text += L(" · 自定义手感", " · Custom feel") }
        return text
    }

    private func resolved(_ mode: ScrollOverrideMode, global: Bool) -> Bool {
        switch mode {
        case .global: return global
        case .on: return true
        case .off: return false
        }
    }

    private func modePicker(_ title: String, _ keyPath: WritableKeyPath<ScrollException, ScrollOverrideMode>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { entry[keyPath: keyPath] }, commit: { mode in
                var copy = entry
                copy[keyPath: keyPath] = mode
                model.updateException(copy)
            })) {
                ForEach(ScrollOverrideMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
    }

    private func commit(_ change: (inout ScrollException) -> Void) {
        var copy = entry
        change(&copy)
        model.updateException(copy)
    }
}

// MARK: - 系统监控

struct TelemetryPage: View {
    @ObservedObject var model: TelemetryModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CPU").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    CPUDetail(model: model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("内存", "Memory")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    MemoryDetail(model: model)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("网络", "Network")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    NetworkDetail(model: model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("磁盘", "Disk")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    DiskDetail(model: model)
                }
            }
            if model.snapshot.gpu.available {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GPU").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        GPUDetail(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 单独一行时保持与上面两列同宽。
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            Group2(title: L("采样", "Sampling")) {
                SliderRow(title: L("后台采样间隔", "Background Sampling Interval"), value: $preferences.telemetryInterval, range: 1...10, step: 1,
                          format: { L("\(Int($0)) 秒", "\(Int($0)) s") })
                Row(title: L("查询出口公网 IP", "Look Up Public IP"),
                    detail: L("开启后会把本机出口 IP 发送给 ipinfo.io 与 freeipapi.com；关闭时不会联网，已获取的结果会被清除。", "When on, your public IP is sent to ipinfo.io and freeipapi.com; when off, nothing is fetched and any cached result is cleared.")) {
                    Toggle("", isOn: Binding(get: { model.publicIPLookupEnabled },
                                            set: { model.setPublicIPLookupEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            MenuWidgetToggles(preferences: preferences, widgets: [.cpu, .memory, .network, .disk, .gpu])
        }
    }
}

struct MenuWidgetToggles: View {
    @ObservedObject var preferences: Preferences
    let widgets: [MenuWidget]

    var body: some View {
        Group2(title: L("菜单栏小组件", "Menu Bar Widgets"), footer: L("常驻在菜单栏显示实时数值，点击直接打开对应详情。按住 ⌘ 拖动可以调整位置。", "Show live values in the menu bar; click one to open its details. Hold ⌘ and drag to rearrange.")) {
            ForEach(widgets) { widget in
                Row(title: widget.title) {
                    Toggle("", isOn: Binding(get: { preferences.menuWidgets.contains(widget) },
                                             commit: { preferences.toggleWidget(widget, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

// MARK: - 通用

struct GeneralPage: View {
    let coordinator: AppCoordinator
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: PermissionMonitor
    @Local private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("通用", "General")).font(.system(size: 22, weight: .bold))

            Group2(title: L("外观与启动", "Appearance & Startup")) {
                Row(title: L("外观", "Appearance"), detail: L("选择“跟随系统”可随 macOS 自动切换深色与浅色。", "Choose “System” to follow macOS between dark and light.")) {
                    Picker(L("外观", "Appearance"), selection: $preferences.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                Row(title: L("语言", "Language"),
                    detail: L("切换后界面立即更新；已打开的截图编辑、贴图等窗口在下次打开时生效。",
                              "Takes effect right away; open editor and pin windows update the next time they open.")) {
                    Picker(L("语言", "Language"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                Row(title: L("登录时启动", "Launch at Login"), detail: loginError ?? (preferences.launchAtLoginNeedsApproval ? L("需要在“系统设置 › 通用 › 登录项”中允许", "Needs approval in System Settings › General › Login Items") : nil)) {
                    Toggle("", isOn: Binding(get: { preferences.launchAtLogin }, commit: { loginError = preferences.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            Group2(title: L("功能", "Features"), footer: L("关闭的功能会停止全部后台活动（事件监听、采样、硬件控制），并从菜单栏面板中隐藏。", "Disabled features stop all background activity (event taps, sampling, hardware control) and are hidden from the menu bar panel.")) {
                ForEach(Feature.allCases) { feature in
                    Row(title: feature.title, detail: feature.summary) {
                        Toggle("", isOn: Binding(get: { preferences.isEnabled(feature) }, commit: { preferences.setEnabled(feature, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }

            Group2(title: L("外部链接", "External Links"),
                   footer: L("meridian:// 链接可以由网页、脚本或其它应用打开。关闭确认后，任何能打开该链接的程序都能直接切换分辨率、HDR、风扇或截图。", "meridian:// links can be opened by web pages, scripts, or other apps. Without confirmation, anything that can open such a link can change resolution, HDR, or fans, or take screenshots.")) {
                Row(title: L("外部链接操作前先确认", "Confirm External Link Actions"),
                    detail: L("对会改动硬件或抓取屏幕的操作弹窗确认；只切换页面的链接不需要确认。", "Ask before actions that change hardware or capture the screen; links that only switch pages don't ask.")) {
                    Toggle("", isOn: Binding(get: { preferences.confirmURLActions },
                                            commit: { preferences.confirmURLActions = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            Group2(title: L("全局快捷键", "Global Shortcuts")) {
                ForEach(HotKeyAction.allCases) { action in
                    Row(title: action.title, detail: HotKeyCenter.shared.conflicts.contains(action) ? L("⚠︎ 已被其他应用占用，请换一个", "⚠︎ Already used by another app; choose a different one") : action.detail) {
                        HotKeyRecorder(action: action, preferences: preferences)
                    }
                }
            }

            MenuWidgetToggles(preferences: preferences, widgets: MenuWidget.allCases)

            Group2(title: L("系统权限", "System Permissions"),
                   footer: L("权限按 Meridian 这个应用授予，重新构建或更新后不需要再次授权。\n点“请求权限”让系统弹出授权提示；如果权限列表里没有 Meridian，点“显示 App”，把 Meridian.app 拖进列表或点 + 选择它。屏幕录制授权后可能需要重新打开 Meridian。", "Permissions are granted to the Meridian app itself and survive rebuilds and updates.\nClick “Request” to have the system prompt you; if Meridian isn't in the permission list, click “Show App” and drag Meridian.app into the list, or click + to choose it. After granting Screen Recording you may need to reopen Meridian.")) {
                ForEach(Permission.allCases) { permission in
                    Row(title: permission.title, detail: permission.purpose) {
                        HStack {
                            StatusDot(on: permissions.isGranted(permission))
                            Text(permissions.isGranted(permission) ? L("已授权", "Granted") : L("未授权", "Not Granted")).font(.system(size: 12)).foregroundStyle(.secondary)
                            if !permissions.isGranted(permission) {
                                Button(L("请求权限", "Request")) { Permissions.request(permission) }.controlSize(.small)
                                Button(L("系统设置", "System Settings")) { Permissions.open(permission) }.controlSize(.small)
                                Button(L("显示 App", "Show App")) { Permissions.revealApp() }.controlSize(.small)
                            }
                        }
                    }
                }
                if permissions.isGranted(.screenRecording) {
                    Row(title: L("重新打开 Meridian", "Reopen Meridian"), detail: L("屏幕录制权限刚授予、截图仍失败时使用", "Use this if screenshots still fail right after granting Screen Recording")) {
                        Button(L("重新打开", "Reopen")) { Permissions.relaunch() }.controlSize(.small)
                    }
                }
            }

            Group2(title: L("关于", "About")) {
                Row(title: "Meridian", detail: appVersionText) {
                    Button(L("退出 Meridian", "Quit Meridian")) { NSApp.terminate(nil) }
                }
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版", "Development")
        return L("版本 \(version)", "Version \(version)")
    }
}
