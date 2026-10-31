import AppKit
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

            Group2(title: "控制服务", footer: "手动/温控模式由一个 root 后台服务写入风扇控制寄存器。Meridian 退出、崩溃或服务失联约 10 秒后，风扇自动交还系统控制。") {
                Row(title: "风扇控制服务", detail: model.daemonInstalled ? "已安装并运行" : "未安装：切换到非自动模式时会请求管理员授权安装") {
                    HStack {
                        StatusDot(on: model.daemonInstalled)
                        Button(model.daemonInstalled ? "重新安装" : "安装…") { model.installDaemon() }
                        if model.daemonInstalled {
                            Button("移除") { model.uninstallDaemon() }
                        }
                    }
                }
            }

            Group2(title: "偏好") {
                SliderRow(title: "刷新间隔", value: $model.refreshInterval, range: 1...5, step: 0.5,
                          format: { String(format: "%.1f 秒", $0) }, onCommit: model.saveSettings)
                SliderRow(title: "最高转速上限", value: $model.maxFraction, range: 0.5...1, step: 0.05,
                          format: { "\(Int($0 * 100))%" }, onCommit: model.saveSettings)
                SliderRow(title: "温控默认起点", value: $model.defaultIncreaseAt, range: 40...90, step: 1,
                          format: { "\(Int($0))°C" }, onCommit: model.saveSettings)
                SliderRow(title: "温控默认满速", value: $model.defaultMaxAt, range: 60...105, step: 1,
                          format: { "\(Int($0))°C" }, onCommit: model.saveSettings)
                Row(title: "使用华氏度") {
                    Toggle("", isOn: $model.fahrenheit).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.fahrenheit) { _, _ in model.saveSettings() }
                }
            }
            MenuWidgetToggles(preferences: preferences, widgets: [.temperature, .fan])
        }
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

            Group2(title: "状态") {
                Row(title: "滚动增强", detail: statusText) {
                    HStack {
                        Button(model.paused ? "恢复" : "临时暂停") { model.togglePause() }
                            .disabled(!model.enabled)
                        Toggle("", isOn: Binding(get: { model.enabled }, commit: { model.set("enabled", $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: HotKeyAction.toggleScroll.title, detail: "例如玩游戏时快速切回系统原生滚动") {
                    HotKeyRecorder(action: .toggleScroll, preferences: preferences)
                }
            }

            Group2(title: "平滑滚动", footer: "只作用于鼠标滚轮；触控板和已经平滑的事件原样放行。") {
                Row(title: "启用平滑") {
                    Toggle("", isOn: Binding(get: { model.accessibilityGranted && model.smooth }, commit: { model.set("smooth", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted)
                }
                Row(title: "方向") {
                    HStack {
                        Toggle("垂直", isOn: Binding(get: { model.smoothVertical }, commit: { model.set("smoothVertical", $0) }))
                        Toggle("水平", isOn: Binding(get: { model.smoothHorizontal }, commit: { model.set("smoothHorizontal", $0) }))
                    }
                    .disabled(!model.accessibilityGranted || !model.smooth)
                }
                Row(title: "模拟触控板", detail: "让应用按触控板惯性处理，部分应用里更顺滑") {
                    Toggle("", isOn: Binding(get: { model.simulateTrackpad }, commit: { model.set("smoothSimTrackpad", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted || !model.smooth)
                }
                SliderRow(title: "步长", value: $step, range: 1...200, step: 0.1, format: { String(format: "%.1f", $0) }) {
                    model.set("step", step)
                }
                SliderRow(title: "速度", value: $speed, range: 0.1...10, step: 0.1, format: { String(format: "%.1f×", $0) }) {
                    model.set("speed", speed)
                }
                SliderRow(title: "过渡", value: $duration, range: 0.1...5, step: 0.05, format: { String(format: "%.2f", $0) }) {
                    model.set("duration", duration)
                }
                Row(title: "恢复默认手感") {
                    Button("恢复") {
                        step = 33.6; speed = 2.7; duration = 4.35
                        model.set("step", step); model.set("speed", speed); model.set("duration", duration)
                    }
                }
            }

            Group2(title: "反转方向", footer: "让鼠标滚轮与触控板“自然滚动”方向相反，两者各用各的习惯。") {
                Row(title: "反转滚轮方向") {
                    Toggle("", isOn: Binding(get: { model.accessibilityGranted && model.reverse }, commit: { model.set("reverse", $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.accessibilityGranted)
                }
                Row(title: "方向") {
                    HStack {
                        Toggle("垂直", isOn: Binding(get: { model.reverseVertical }, commit: { model.set("reverseVertical", $0) }))
                        Toggle("水平", isOn: Binding(get: { model.reverseHorizontal }, commit: { model.set("reverseHorizontal", $0) }))
                    }
                    .disabled(!model.accessibilityGranted || !model.reverse)
                }
            }

            Group2(title: "应用例外", footer: model.allowlist
                   ? "只在下列应用中启用增强；勾选“自定义”可单独设置平滑和反向。"
                   : "下列应用使用单独设置；关闭“平滑”与“反向”即完全不处理该应用。") {
                Row(title: "规则模式") {
                    Picker("", selection: Binding(get: { model.allowlist }, commit: { model.set("allowlist", $0) })) {
                        Text("排除列表中的应用").tag(false)
                        Text("仅列表中的应用").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                ForEach(model.exceptions) { entry in
                    ExceptionRow(model: model, entry: entry)
                }
                Row(title: model.exceptions.isEmpty ? "还没有例外应用" : "添加更多应用") {
                    Button("添加应用…") { model.addException() }
                }
            }
        }
        .onAppear {
            step = model.step; speed = model.speed; duration = model.duration
            model.refresh()
        }
    }

    private var statusText: String {
        if !model.accessibilityGranted { return "等待辅助功能权限，授权后自动生效" }
        if !model.enabled { return "已关闭" }
        if model.paused { return "已临时暂停（不改变设置）" }
        return model.tapActive ? "正在工作" : "正在启动…"
    }
}

private struct ExceptionRow: View {
    @ObservedObject var model: PointerModel
    let entry: ScrollException

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon).resizable().frame(width: 22, height: 22)
            Text(entry.name).font(.system(size: 13))
            Spacer()
            Toggle("自定义", isOn: binding(\.inherit, inverted: true)).controlSize(.small)
            Toggle("平滑", isOn: binding(\.smooth, requiresAccessibility: true)).controlSize(.small)
                .disabled(!model.accessibilityGranted || entry.inherit)
            Toggle("反向", isOn: binding(\.reverse, requiresAccessibility: true)).controlSize(.small)
                .disabled(!model.accessibilityGranted || entry.inherit)
            Button {
                model.removeException(entry.id)
            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("移除")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ScrollException, Bool>, inverted: Bool = false,
                         requiresAccessibility: Bool = false) -> Binding<Bool> {
        Binding(get: {
            let value = requiresAccessibility && !model.accessibilityGranted ? false : entry[keyPath: keyPath]
            return inverted ? !value : value
        }, commit: { value in
            guard !requiresAccessibility || model.accessibilityGranted else { return }
            var copy = entry
            copy[keyPath: keyPath] = inverted ? !value : value
            model.updateException(copy)
        })
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
                    Text("内存").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    MemoryDetail(model: model)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("网络").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    NetworkDetail(model: model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("磁盘").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    DiskDetail(model: model)
                }
            }
            Group2(title: "采样") {
                SliderRow(title: "后台采样间隔", value: $preferences.telemetryInterval, range: 1...10, step: 1,
                          format: { "\(Int($0)) 秒" })
            }
            MenuWidgetToggles(preferences: preferences, widgets: [.cpu, .memory, .network, .disk])
        }
    }
}

struct MenuWidgetToggles: View {
    @ObservedObject var preferences: Preferences
    let widgets: [MenuWidget]

    var body: some View {
        Group2(title: "菜单栏小组件", footer: "常驻在菜单栏显示实时数值，点击直接打开对应详情。按住 ⌘ 拖动可以调整位置。") {
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
            Text("通用").font(.system(size: 22, weight: .bold))

            Group2(title: "外观与启动") {
                Row(title: "外观", detail: "选择“跟随系统”可随 macOS 自动切换深色与浅色。") {
                    Picker("外观", selection: $preferences.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                Row(title: "登录时启动", detail: loginError ?? (preferences.launchAtLoginNeedsApproval ? "需要在“系统设置 › 通用 › 登录项”中允许" : nil)) {
                    Toggle("", isOn: Binding(get: { preferences.launchAtLogin }, commit: { loginError = preferences.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            Group2(title: "功能", footer: "关闭的功能会停止全部后台活动（事件监听、采样、硬件控制），并从菜单栏面板中隐藏。") {
                ForEach(Feature.allCases) { feature in
                    Row(title: feature.title, detail: feature.summary) {
                        Toggle("", isOn: Binding(get: { preferences.isEnabled(feature) }, commit: { preferences.setEnabled(feature, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }

            Group2(title: "全局快捷键") {
                ForEach(HotKeyAction.allCases) { action in
                    Row(title: action.title, detail: HotKeyCenter.shared.conflicts.contains(action) ? "⚠︎ 已被其他应用占用，请换一个" : action.detail) {
                        HotKeyRecorder(action: action, preferences: preferences)
                    }
                }
            }

            MenuWidgetToggles(preferences: preferences, widgets: MenuWidget.allCases)

            Group2(title: "系统权限",
                   footer: "权限按 Meridian 这个应用授予，重新构建或更新后不需要再次授权。\n点“请求权限”让系统弹出授权提示；如果权限列表里没有 Meridian，点“显示 App”，把 Meridian.app 拖进列表或点 + 选择它。屏幕录制授权后可能需要重新打开 Meridian。") {
                ForEach(Permission.allCases) { permission in
                    Row(title: permission.title, detail: permission.purpose) {
                        HStack {
                            StatusDot(on: permissions.isGranted(permission))
                            Text(permissions.isGranted(permission) ? "已授权" : "未授权").font(.system(size: 12)).foregroundStyle(.secondary)
                            if !permissions.isGranted(permission) {
                                Button("请求权限") { Permissions.request(permission) }.controlSize(.small)
                                Button("系统设置") { Permissions.open(permission) }.controlSize(.small)
                                Button("显示 App") { Permissions.revealApp() }.controlSize(.small)
                            }
                        }
                    }
                }
                if permissions.isGranted(.screenRecording) {
                    Row(title: "重新打开 Meridian", detail: "屏幕录制权限刚授予、截图仍失败时使用") {
                        Button("重新打开") { Permissions.relaunch() }.controlSize(.small)
                    }
                }
            }

            Group2(title: "关于") {
                Row(title: "Meridian", detail: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")") {
                    Button("退出 Meridian") { NSApp.terminate(nil) }
                }
            }
        }
    }
}
