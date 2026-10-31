import DisplayLabKit
import SwiftUI

struct DisplayPage: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
            if model.displays.isEmpty {
                Text("未检测到显示器。").foregroundStyle(.secondary)
            }
            ForEach(model.displays) { display in
                DisplaySection(model: model, display: display)
            }

            Group2(title: "虚拟屏幕", footer: "虚拟屏是一块不存在的显示器，可用于录屏、远程桌面或扩展工作区；断开即消失，退出 Meridian 时自动移除。") {
                Row(title: "新建虚拟屏") {
                    Menu("选择尺寸") {
                        ForEach(DisplayEngine.virtualPresets, id: \.name) { spec in
                            Button("\(spec.name)（\(spec.pixelWidth)×\(spec.pixelHeight)）") { model.createVirtual(spec) }
                        }
                    }
                    .fixedSize()
                }
                ForEach(model.virtualScreens) { screen in
                    Row(title: screen.spec.name, detail: "\(screen.spec.pixelWidth)×\(screen.spec.pixelHeight) · \(Int(screen.spec.refreshRate))Hz") {
                        Button("断开") { model.disconnectVirtual(screen.id) }
                    }
                }
                Row(title: "在列表中显示其他应用的虚拟屏") {
                    Toggle("", isOn: $model.showVirtualScreens).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.showVirtualScreens) { _, _ in model.saveSettings() }
                }
            }

            Group2(title: "亮度调节") {
                Row(title: "平滑过渡", detail: "拖动滑块时按最新值合并写入，松手后平滑到位") {
                    Toggle("", isOn: $model.smoothing).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.smoothing) { _, _ in model.saveSettings() }
                }
                SliderRow(title: "过渡时长", value: $model.smoothingMilliseconds, range: 80...2000, step: 10,
                          format: { "\(Int($0)) ms" }, onCommit: model.saveSettings)
                SliderRow(title: "软件调暗起点", value: $model.dimmingPoint, range: 0...0.6, step: 0.01,
                          format: { "\(Int($0 * 100))%" }, onCommit: model.saveSettings)
                Row(title: "用 F1 / F2 调节外接屏亮度",
                    detail: !brightnessKeysAuthorized
                        ? "需要输入监控和辅助功能权限"
                        : model.brightnessKeys && !model.brightnessKeysActive
                        ? "尚未生效：授权后重新打开 Meridian"
                        : "接管键盘亮度键，同时作用于所有支持的显示器") {
                    HStack {
                        if !brightnessKeysAuthorized {
                            Button("去授权") { requestBrightnessKeysPermission() }.controlSize(.small)
                            Button("系统设置") { Permissions.open(missingBrightnessPermission) }
                                .controlSize(.small)
                        } else {
                            Toggle("", isOn: $model.brightnessKeys).toggleStyle(.switch).labelsHidden()
                                .onChange(of: model.brightnessKeys) { _, _ in model.saveSettings() }
                        }
                    }
                }
            }
            if !brightnessKeysAuthorized || (model.brightnessKeys && !model.brightnessKeysActive) {
                BrightnessKeyPermissionNotice(model: model, permissions: permissions)
            }
        }
    }

    private var brightnessKeysAuthorized: Bool {
        permissions.isGranted(.inputMonitoring) && permissions.isGranted(.accessibility)
    }

    private var missingBrightnessPermission: Permission {
        permissions.isGranted(.inputMonitoring) ? .accessibility : .inputMonitoring
    }

    private func requestBrightnessKeysPermission() {
        Permissions.request(missingBrightnessPermission)
    }
}

/// F1/F2 接管失败的提示：两个权限都可能需要，且授权后必须重启应用。
private struct BrightnessKeyPermissionNotice: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("F1 / F2 还没有生效").font(.system(size: 12, weight: .semibold))
                    Text(permissionSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("请求授权") { Permissions.request(missingPermission) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                if !permissions.isGranted(.inputMonitoring) {
                    Button("打开输入监控设置") { Permissions.open(.inputMonitoring) }
                }
                if !permissions.isGranted(.accessibility) {
                    Button("打开辅助功能设置") { Permissions.open(.accessibility) }
                }
                Button("重新打开 Meridian") { Permissions.relaunch() }
                Spacer()
            }
            .buttonStyle(.link).font(.system(size: 10.5))
            Text("在系统设置里打开 Meridian 后，必须点“重新打开 Meridian”，再打开上方开关才会接管 F1/F2。如果列表里没有 Meridian，用“在访达中显示 Meridian”把它拖进去。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var missingPermission: Permission {
        permissions.isGranted(.inputMonitoring) ? .accessibility : .inputMonitoring
    }

    private var permissionSummary: String {
        if !permissions.isGranted(.inputMonitoring) && !permissions.isGranted(.accessibility) {
            return "需要“输入监控”（接收亮度键）和“辅助功能”（拦截系统默认处理）两项权限。"
        }
        if !permissions.isGranted(.inputMonitoring) { return "需要“输入监控”权限才能接收 F1 / F2。" }
        if !permissions.isGranted(.accessibility) { return "需要“辅助功能”权限才能接管系统亮度键。" }
        return "权限已授予，但按键监听尚未生效；重新打开 Meridian 后再试。"
    }
}

private struct DisplaySection: View {
    @ObservedObject var model: DisplayModel
    let display: ScreenDisplay
    @Local private var brightness: Double = 1
    @Local private var showAllModes = false

    var body: some View {
        Group2(title: display.name + (display.isBuiltIn ? "（内建）" : "")) {
            Row(title: "亮度", detail: backendText) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 0...1).frame(width: 220)
                        .onChange(of: brightness) { _, value in
                            if abs(value - display.brightness) > 0.004 { model.setBrightness(value, for: display.id) }
                        }
                        .disabled(display.brightnessBackend == .unavailable)
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                    Text("\(Int((brightness * 100).rounded()))%").font(.system(size: 12, design: .rounded))
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Row(title: "分辨率", detail: resolutionDetail) {
                HStack {
                    if model.busy.contains(display.id) { ProgressView().controlSize(.small) }
                    Picker("", selection: Binding(get: { selection }, commit: select)) {
                        if canUpsample {
                            Section("5K 渲染") {
                                Text(verbatim: "\(display.nativeWidth) × \(display.nativeHeight) HiDPI · 5K 渲染").tag(Self.upHiDPI)
                                Text(verbatim: "\(display.nativeWidth * 2) × \(display.nativeHeight * 2) · 更多空间").tag(Self.upMore)
                            }
                        }
                        Section("显示器模式") {
                            ForEach(modes, id: \.label) { Text($0.shortLabel).tag($0.label) }
                        }
                    }
                    .labelsHidden().frame(width: 250)
                    if !display.isAtNativeMode || display.upsample != .off {
                        Button("原生") { model.restoreNative(display.id) }
                            .fixedSize()
                            .help("切回面板原生分辨率与最高刷新率")
                    }
                }
            }
            if canUpsample {
                Row(title: "5K 渲染刷新率",
                    detail: model.upsampleKeepsRefresh
                        ? "跟随显示器刷新率（例如 144Hz）；如果画面闪烁，请关掉此开关"
                        : "固定 60Hz，画面最稳定；需要更高刷新率时打开此开关") {
                    Toggle("", isOn: $model.upsampleKeepsRefresh).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.upsampleKeepsRefresh) { _, _ in model.saveSettings() }
                }
            }
            Row(title: "显示全部模式", detail: "默认只列出有用的分辨率；打开后列出系统报告的全部模式") {
                Toggle("", isOn: $showAllModes).toggleStyle(.switch).labelsHidden()
            }
            if canUpsample {
                Row(title: "HiDPI 覆盖", detail: model.hasOverride(display.id)
                    ? "已安装：系统“显示器”设置里会出现 HiDPI 缩放档（重插显示线或注销后生效）"
                    : "为这台显示器写入系统级 HiDPI 模式表，需要管理员授权一次") {
                    Button(model.hasOverride(display.id) ? "移除" : "安装…") { model.toggleOverride(display.id) }
                        .disabled(model.busy.contains(display.id))
                }
            }
            if display.supportsHDR {
                Row(title: "HDR") {
                    Toggle("", isOn: Binding(get: { display.hdrEnabled ?? false }, commit: { model.setHDR($0, for: display.id) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onAppear { brightness = display.brightness }
        .onChange(of: display.brightness) { _, value in
            if abs(value - brightness) > 0.01 { brightness = value }
        }
    }

    static let upHiDPI = "meridian.upsample.hidpi"
    static let upMore = "meridian.upsample.more"

    private var canUpsample: Bool { !display.isBuiltIn && !display.isOwnVirtual }

    private var selection: String {
        switch display.upsample {
        case .hiDPI: return Self.upHiDPI
        case .moreSpace: return Self.upMore
        case .off: return display.currentMode?.label ?? ""
        }
    }

    private func select(_ tag: String) {
        switch tag {
        case Self.upHiDPI: model.setUpsample(.hiDPI, for: display.id)
        case Self.upMore: model.setUpsample(.moreSpace, for: display.id)
        default:
            if let mode = modes.first(where: { $0.label == tag }) { model.applyMode(mode, to: display) }
        }
    }

    private var resolutionDetail: String {
        switch display.upsample {
        case .hiDPI:
            return "桌面大小与 \(display.nativeWidth)×\(display.nativeHeight) 相同，按 5K 渲染后缩到面板，文字更锐利"
        case .moreSpace:
            return "桌面扩大到 \(display.nativeWidth * 2)×\(display.nativeHeight * 2)，界面元素会变小"
        case .off:
            return "面板 \(display.nativeWidth)×\(display.nativeHeight)。HiDPI 项显示的是桌面“看起来像”的大小"
        }
    }

    private var modes: [DisplayModeInfo] {
        var list = showAllModes ? model.allModes(for: display.id) : display.quickModes
        if let current = display.currentMode, !list.contains(where: { $0.label == current.label }) {
            list.insert(current, at: 0)
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.label).inserted }
    }

    private var backendText: String {
        switch display.brightnessBackend {
        case .ddc: return "通过 DDC/CI 调节显示器背光，低于起点后叠加软件调暗"
        case .apple: return "系统内建屏亮度"
        case .gammaOnly: return "此屏不支持硬件调光，使用软件调暗"
        case .unavailable: return "此屏不支持亮度调节"
        }
    }
}
