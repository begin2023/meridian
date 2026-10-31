import AppKit
import DisplayLabKit
import FanControlLabKit
import MonitoringLabKit
import SwiftUI

enum PanelRoute: Equatable {
    case home
    case cpu, memory, network, disk
    case thermal
}

@MainActor
final class PanelState: ObservableObject {
    @Published var route: PanelRoute = .home
    @Published var isPresented = false
}

/// 菜单栏弹出的控制中心：常用动作一步可达，细节一层下钻，完整设置在主窗口。
struct ControlCenterView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var preferences: Preferences
    let coordinator: AppCoordinator

    var body: some View {
        Group {
            // 关闭后卸载模型订阅，避免不可见的面板仍随采样重新布局。
            if state.isPresented { panelContent }
        }
        .frame(width: Metrics.panelWidth)
    }

    @ViewBuilder private var panelContent: some View {
        switch state.route {
        case .home: home
        case .cpu: DetailContainer(title: "CPU", state: state, coordinator: coordinator) { CPUDetail(model: coordinator.telemetry) }
        case .memory: DetailContainer(title: "内存", state: state, coordinator: coordinator) { MemoryDetail(model: coordinator.telemetry) }
        case .network: DetailContainer(title: "网络", state: state, coordinator: coordinator) { NetworkDetail(model: coordinator.telemetry) }
        case .disk: DetailContainer(title: "磁盘", state: state, coordinator: coordinator) { DiskDetail(model: coordinator.telemetry) }
        case .thermal: DetailContainer(title: "风扇与温度", state: state, coordinator: coordinator) { ThermalDetail(model: coordinator.thermal) }
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ConflictStrip(monitor: coordinator.conflicts)
                    if preferences.isEnabled(.capture) { CaptureCard(model: coordinator.capture, preferences: preferences) }
                    if preferences.isEnabled(.display) {
                        DisplayCard(model: coordinator.display, permissions: coordinator.permissions)
                    }
                    if preferences.isEnabled(.thermal) { ThermalCard(model: coordinator.thermal, state: state) }
                    if preferences.isEnabled(.pointer) { PointerCard(model: coordinator.pointer) }
                    if preferences.isEnabled(.telemetry) { TelemetryCard(model: coordinator.telemetry, state: state) }
                    if preferences.enabledFeatures.isEmpty {
                        Text("所有功能都已关闭。打开主窗口可以重新启用。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 640)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        PanelHeader(title: nil, state: state, coordinator: coordinator)
    }
}

/// 面板顶栏：首页显示“⊞ Meridian”，详情页显示“⊞ Meridian › 标题”，点击 ⊞ Meridian 回到首页。
private struct PanelHeader: View {
    let title: String?
    @ObservedObject var state: PanelState
    let coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Button { state.route = .home } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Meridian").font(.system(size: 15, weight: .bold))
                    if let title {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(title == nil)
            .help(title == nil ? "" : "回到控制中心")
            Spacer()
            circle("macwindow", "打开主窗口") { coordinator.openMain(.overview) }
            circle("gearshape", "设置") { coordinator.openMain(.overview) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func circle(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).help(help)
    }
}

private struct DetailContainer<Content: View>: View {
    let title: String
    @ObservedObject var state: PanelState
    let coordinator: AppCoordinator
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, state: state, coordinator: coordinator)
            ScrollView {
                content.padding(.horizontal, 14).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 600)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConflictStrip: View {
    @ObservedObject var monitor: ConflictMonitor

    var body: some View {
        if !monitor.running.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(monitor.running.map(\.name).joined(separator: "、")) 正在运行，可能与 Meridian 冲突")
                    .font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 0)
                Button("退出它们") { monitor.quitAll() }.controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - 截图

private struct CaptureCard: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        PanelCard {
            CardHeader(feature: .capture, subtitle: model.permissionGranted ? nil : "尚未获得屏幕录制权限") {
                if model.pinCount > 0 {
                    Menu {
                        Button("显示全部贴图") { model.showPins() }
                        Button("隐藏全部贴图") { model.hidePins() }
                        Button("关闭全部贴图") { model.closePins() }
                    } label: {
                        Label("\(model.pinCount)", systemImage: "pin.fill").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack(spacing: 8) {
                ActionTile(symbol: "viewfinder", title: "截图", caption: hint(.capture), tint: .blue) { run { model.capture() } }
                ActionTile(symbol: "text.viewfinder", title: "识字", caption: hint(.ocr), tint: .purple) { run { model.captureOCR() } }
                ActionTile(symbol: "pin", title: "贴图", caption: hint(.pin), tint: .pink) { run { model.capturePin() } }
                ActionTile(symbol: model.gifRecording ? "stop.fill" : "record.circle",
                           title: model.gifRecording ? "停止" : "GIF", caption: hint(.gif), tint: .red,
                           active: model.gifRecording) { run { model.toggleGIF() } }
            }
            HStack(spacing: 5) {
                ChipButton(symbol: "rectangle.inset.filled", title: "全屏") { run { model.captureFullScreen() } }
                ChipButton(symbol: "macwindow", title: "窗口") { run { model.captureWindow() } }
                ChipButton(symbol: "timer", title: "延时") { run { model.captureDelayed(3) } }
                Spacer(minLength: 0)
                ChipButton(symbol: "clock.arrow.circlepath", title: "历史") { run { model.showHistory() } }
                ChipButton(symbol: "photo", title: "打开") { run { model.openImage() } }
            }
            if !model.permissionGranted {
                PermissionBanner(permission: .screenRecording, granted: false) { model.requestPermission() }
            }
        }
        .onAppear { model.refreshState() }
    }

    private func hint(_ action: HotKeyAction) -> String? { preferences.hotKeys[action]?.displayString }

    /// 先收起面板再执行，截图里不会出现面板自身。
    private func run(_ body: @escaping () -> Void) {
        AppCoordinator.shared.closePanelThen(body)
    }
}

// MARK: - 显示器

private struct DisplayCard: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        PanelCard {
            CardHeader(feature: .display, subtitle: model.displays.isEmpty ? "未检测到显示器" : nil) {
                Button { AppCoordinator.shared.openMain(.feature(.display)) } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("更多显示器选项")
            }
            ForEach(model.displays) { display in
                DisplayRow(model: model, display: display)
                if display.id != model.displays.last?.id { Divider().opacity(0.5) }
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("F1 / F2 亮度键").font(.system(size: 12, weight: .medium))
                    Text(brightnessKeyStatus).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !permissions.isGranted(.inputMonitoring) || !permissions.isGranted(.accessibility) {
                    Button("去授权") { Permissions.request(missingBrightnessPermission) }.controlSize(.small)
                    Button("设置") { Permissions.open(missingBrightnessPermission) }.controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { model.brightnessKeys }, set: {
                        model.brightnessKeys = $0
                        model.saveSettings()
                    }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("用 F1 / F2 调节显示器亮度")
                }
            }
            .padding(.vertical, 2)
            if permissions.isGranted(.inputMonitoring), permissions.isGranted(.accessibility),
               model.brightnessKeys, !model.brightnessKeysActive {
                HStack {
                    Text("按键监听尚未生效，请重新打开应用。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新打开") { Permissions.relaunch() }.controlSize(.small)
                }
            }
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
        }
        .onAppear { model.refreshBrightnessKeysStateForUI() }
    }

    private var brightnessKeyStatus: String {
        if !permissions.isGranted(.inputMonitoring) && !permissions.isGranted(.accessibility) {
            return "需要输入监控和辅助功能权限"
        }
        if !permissions.isGranted(.inputMonitoring) { return "需要输入监控权限才能接收亮度键" }
        if !permissions.isGranted(.accessibility) { return "需要辅助功能权限才能接管按键" }
        if model.brightnessKeys && !model.brightnessKeysActive { return "已开启，等待按键监听生效" }
        return model.brightnessKeysActive ? "已接管外接显示器亮度键" : "开启后由 F1 / F2 调节支持的显示器"
    }

    private var missingBrightnessPermission: Permission {
        permissions.isGranted(.inputMonitoring) ? .accessibility : .inputMonitoring
    }
}

private struct DisplayRow: View {
    @ObservedObject var model: DisplayModel
    let display: ScreenDisplay
    @Local private var brightness: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").foregroundStyle(.secondary)
                Text(display.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if model.busy.contains(display.id) { ProgressView().controlSize(.mini) }
                Text(display.upsample == .off ? (display.currentMode?.shortLabel ?? "")
                     : display.upsample == .hiDPI ? "\(display.nativeWidth) × \(display.nativeHeight) · 5K 渲染" : "\(display.nativeWidth * 2) × \(display.nativeHeight * 2)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if display.brightnessBackend != .unavailable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 0...1) { _ in }
                        .controlSize(.small)
                        .onChange(of: brightness) { _, value in
                            if abs(value - display.brightness) > 0.004 { model.setBrightness(value, for: display.id) }
                        }
                    Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(Int((brightness * 100).rounded()))").font(.system(size: 11, design: .rounded))
                        .monospacedDigit().frame(width: 24, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Menu {
                    if canUpsample {
                        Section("5K 渲染") {
                            check("\(display.nativeWidth) × \(display.nativeHeight) HiDPI · 5K 渲染", display.upsample == .hiDPI) {
                                model.setUpsample(.hiDPI, for: display.id)
                            }
                            check("\(display.nativeWidth * 2) × \(display.nativeHeight * 2) · 更多空间", display.upsample == .moreSpace) {
                                model.setUpsample(.moreSpace, for: display.id)
                            }
                        }
                    }
                    Section("显示器模式") {
                        ForEach(display.quickModes, id: \.label) { mode in
                            check(mode.shortLabel, display.upsample == .off && mode.isCurrent) {
                                model.applyMode(mode, to: display)
                            }
                        }
                    }
                    Divider()
                    Button("恢复原生分辨率") { model.restoreNative(display.id) }
                } label: {
                    Label(resolutionTitle, systemImage: "rectangle.expand.vertical")
                }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()

                if display.supportsHDR {
                    Toggle("HDR", isOn: Binding(get: { display.hdrEnabled ?? false },
                                                commit: { model.setHDR($0, for: display.id) }))
                        .toggleStyle(.button).controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { brightness = display.brightness }
        .onChange(of: display.brightness) { _, value in
            if abs(value - brightness) > 0.01 { brightness = value }
        }
    }

    private var canUpsample: Bool { !display.isBuiltIn && !display.isOwnVirtual }

    private var resolutionTitle: String {
        switch display.upsample {
        case .hiDPI: return "5K HiDPI"
        case .moreSpace: return "5K 更多空间"
        case .off: return "分辨率"
        }
    }

    @ViewBuilder
    private func check(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: - 散热

private struct ThermalCard: View {
    @ObservedObject var model: ThermalModel
    @ObservedObject var state: PanelState

    var body: some View {
        PanelCard {
            CardHeader(feature: .thermal) {
                Button { state.route = .thermal } label: {
                    HStack(spacing: 2) { Text("详情"); Image(systemName: "chevron.right") }.font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach(model.fans) { fan in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(fan.currentRPM.rounded()))")
                            .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(model.fans.count > 1 ? "RPM · \(fan.name)" : "风扇 RPM").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let cpu = model.hottestCPU {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.temperature(cpu))
                            .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(cpu > 85 ? .red : cpu > 70 ? .orange : .primary)
                        Text("CPU 平均").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let gpu = model.reading?.gpuAverage {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.temperature(gpu))
                            .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("GPU 平均").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.reading == nil && model.running {
                Text("正在读取传感器…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("模式", selection: Binding(get: { model.overallPreset }, commit: { model.apply($0) })) {
                ForEach(ThermalModel.Preset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.overallPreset == .fixed, let fan = model.fans.first {
                FixedRPMSlider(model: model, fan: fan)
            }
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
        }
    }
}

/// 固定转速：拖动只改草稿，按“应用”后才下发。
struct FixedRPMSlider: View {
    @ObservedObject var model: ThermalModel
    let fan: ThermalFan
    @Local private var value: Double = 0

    private var applied: Double? {
        if case .constant(let rpm) = fan.mode { return Double(rpm) }
        return nil
    }

    private var upper: Double { max(fan.effectiveMaximumRPM, fan.minimumRPM + 100) }
    private var dirty: Bool { applied.map { abs(min($0, upper) - value) >= 25 } ?? true }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan").font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { value = ($0 / 50).rounded() * 50 }),
                   in: fan.minimumRPM...upper)
            .controlSize(.small)
            Text("\(Int(value)) RPM").font(.system(size: 11, design: .rounded)).monospacedDigit()
                .frame(width: 66, alignment: .trailing)
            ApplyButton(dirty: dirty) { model.setFixedRPM(value, for: fan.index) }
        }
        .onAppear(perform: sync)
        .onChange(of: fan.mode) { _, _ in sync() }
    }

    private func sync() {
        value = min(applied ?? fan.currentRPM, upper)
        value = (value / 50).rounded() * 50
    }
}

// MARK: - 滚动

private struct PointerCard: View {
    @ObservedObject var model: PointerModel

    var body: some View {
        PanelCard {
            CardHeader(feature: .pointer, subtitle: status) {
                Toggle("", isOn: Binding(get: { model.accessibilityGranted && model.enabled && !model.paused }, commit: { on in
                    if model.paused { model.togglePause() } else { model.set("enabled", on) }
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!model.accessibilityGranted)
            }
            HStack(spacing: 8) {
                ActionTile(symbol: "water.waves", title: "平滑滚动", tint: .teal,
                           active: model.accessibilityGranted && model.smooth) {
                    model.set("smooth", !model.smooth)
                }
                .disabled(!model.accessibilityGranted)
                ActionTile(symbol: "arrow.up.arrow.down", title: "反转方向", tint: .teal,
                           active: model.accessibilityGranted && model.reverse) {
                    model.set("reverse", !model.reverse)
                }
                .disabled(!model.accessibilityGranted)
                ActionTile(symbol: model.paused ? "play.fill" : "pause.fill",
                           title: model.paused ? "恢复" : "临时暂停", tint: .gray) {
                    model.togglePause()
                }
                .disabled(!model.accessibilityGranted)
            }
            if !model.accessibilityGranted {
                PermissionBanner(permission: .accessibility, granted: false) { model.requestPermission() }
            }
        }
        .onAppear { model.refresh() }
    }

    private var status: String {
        if !model.accessibilityGranted { return "尚未授权，设置已保存但尚未生效" }
        if model.paused { return "已临时暂停" }
        if !model.enabled { return "已关闭" }
        return model.tapActive ? "正在工作 · 仅作用于鼠标滚轮" : "正在启动…"
    }
}

// MARK: - 监控

private struct TelemetryCard: View {
    @ObservedObject var model: TelemetryModel
    @ObservedObject var state: PanelState

    var body: some View {
        PanelCard {
            CardHeader(feature: .telemetry)
            let s = model.snapshot
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    MetricTile(title: "CPU", value: Format.percent(s.cpuPercent), values: model.cpuHistory,
                               max: 100, color: .green) { state.route = .cpu }
                    MetricTile(title: "内存", value: Format.percent(s.memoryFraction * 100), values: model.memoryHistory,
                               max: 100, color: .blue) { state.route = .memory }
                }
                GridRow {
                    MetricTile(title: "网络", value: "↓\(Format.compactRate(s.netDownPerSecond)) ↑\(Format.compactRate(s.netUpPerSecond))",
                               values: model.downHistory, secondary: model.upHistory, color: .cyan) { state.route = .network }
                    MetricTile(title: "磁盘", value: "R \(Format.compactRate(s.diskReadPerSecond)) W \(Format.compactRate(s.diskWritePerSecond))",
                               values: model.readHistory, secondary: model.writeHistory, color: .indigo) { state.route = .disk }
                }
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let values: [Double]
    var secondary: [Double] = []
    var max: Double? = nil
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.7)
                Sparkline(values: values, secondary: secondary, maxValue: max, color: color)
                    .frame(height: 24)
            }
            .padding(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
