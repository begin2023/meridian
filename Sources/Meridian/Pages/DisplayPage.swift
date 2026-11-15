import DisplayLabKit
import MeridianLocalization
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
                Text(L("未检测到显示器。", "No displays detected.")).foregroundStyle(.secondary)
            }
            ForEach(model.displays) { display in
                DisplaySection(model: model, display: display)
            }

            if model.displays.contains(where: { $0.supportsHDR && !$0.isBuiltIn }) {
                Group2(title: "HDR") {
                    Row(title: L("HDR 时关闭夜览和原彩显示", "Turn Off Night Shift and True Tone in HDR"),
                        detail: L("外接屏进入 HDR 时自动关闭，回到 SDR 时恢复；看 HDR 内容时颜色更准", "Turned off automatically when an external display enters HDR and restored in SDR, for more accurate HDR color")) {
                        Toggle("", isOn: $model.hdrDisablesNightShift).toggleStyle(.switch).labelsHidden()
                            .onChange(of: model.hdrDisablesNightShift) { _, _ in model.saveSettings() }
                    }
                }
            }

            Group2(title: L("虚拟屏幕", "Virtual Displays"), footer: L("虚拟屏是一块不存在的显示器，可用于录屏、远程桌面或扩展工作区；断开即消失，退出 Meridian 时自动移除。", "A virtual display is a display that doesn't physically exist, useful for screen recording, remote desktop, or extra workspace. It disappears when disconnected and is removed automatically when Meridian quits.")) {
                Row(title: L("HDR 虚拟屏", "HDR Virtual Display"), detail: L("新建的虚拟屏使用 Display P3 + PQ，镜像或录制到 HDR 屏时保留 HDR 内容", "New virtual displays use Display P3 + PQ, keeping HDR content when mirrored or recorded to an HDR display")) {
                    Toggle("", isOn: $model.virtualHDR).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.virtualHDR) { _, _ in model.saveSettings() }
                }
                Row(title: L("新建虚拟屏", "New Virtual Display")) {
                    Menu(L("选择尺寸", "Choose Size")) {
                        ForEach(DisplayEngine.virtualPresets, id: \.name) { spec in
                            Button(L("\(spec.name)（\(spec.pixelWidth)×\(spec.pixelHeight)）", "\(spec.name) (\(spec.pixelWidth)×\(spec.pixelHeight))")) { model.createVirtual(spec) }
                        }
                    }
                    .fixedSize()
                }
                ForEach(model.virtualScreens) { screen in
                    Row(title: screen.spec.name, detail: "\(screen.spec.pixelWidth)×\(screen.spec.pixelHeight) · \(Int(screen.spec.refreshRate))Hz\(screen.spec.hdr ? " · HDR" : "")") {
                        Button(L("断开", "Disconnect")) { model.disconnectVirtual(screen.id) }
                    }
                }
                Row(title: L("在列表中显示其他应用的虚拟屏", "Show Other Apps' Virtual Displays")) {
                    Toggle("", isOn: $model.showVirtualScreens).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.showVirtualScreens) { _, _ in model.saveSettings() }
                }
            }

            Group2(title: L("亮度调节", "Brightness")) {
                Row(title: L("平滑过渡", "Smooth Transitions"), detail: L("拖动滑块时按最新值合并写入，松手后平滑到位", "Coalesces writes while dragging and eases to the final value on release")) {
                    Toggle("", isOn: $model.smoothing).toggleStyle(.switch).labelsHidden()
                        .onChange(of: model.smoothing) { _, _ in model.saveSettings() }
                }
                SliderRow(title: L("过渡时长", "Transition Duration"), value: $model.smoothingMilliseconds, range: 80...2000, step: 10,
                          format: { "\(Int($0)) ms" }, onCommit: model.saveSettings)
                SliderRow(title: L("软件调暗起点", "Software Dimming Threshold"), value: $model.dimmingPoint, range: 0...0.6, step: 0.01,
                          format: { "\(Int($0 * 100))%" }, onCommit: model.saveSettings)
                Row(title: L("用 F1 / F2 调节外接屏亮度", "Use F1 / F2 for External Display Brightness"),
                    detail: !brightnessKeysAuthorized
                        ? L("需要输入监控和辅助功能权限", "Requires Input Monitoring and Accessibility permissions")
                        : model.brightnessKeys && !model.brightnessKeysActive
                        ? L("尚未生效：授权后重新打开 Meridian", "Not active yet: reopen Meridian after granting permission")
                        : L("接管键盘亮度键，同时作用于所有支持的显示器", "Takes over the keyboard brightness keys for all supported displays")) {
                    HStack {
                        if !brightnessKeysAuthorized {
                            Button(L("去授权", "Grant")) { requestBrightnessKeysPermission() }.controlSize(.small)
                            Button(L("系统设置", "System Settings")) { Permissions.open(missingBrightnessPermission) }
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
                    Text(L("F1 / F2 还没有生效", "F1 / F2 Not Active Yet")).font(.system(size: 12, weight: .semibold))
                    Text(permissionSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("请求授权", "Request Access")) { Permissions.request(missingPermission) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                if !permissions.isGranted(.inputMonitoring) {
                    Button(L("打开输入监控设置", "Open Input Monitoring Settings")) { Permissions.open(.inputMonitoring) }
                }
                if !permissions.isGranted(.accessibility) {
                    Button(L("打开辅助功能设置", "Open Accessibility Settings")) { Permissions.open(.accessibility) }
                }
                Button(L("重新打开 Meridian", "Reopen Meridian")) { Permissions.relaunch() }
                Spacer()
            }
            .buttonStyle(.link).font(.system(size: 10.5))
            Text(L("在系统设置里打开 Meridian 后，必须点“重新打开 Meridian”，再打开上方开关才会接管 F1/F2。如果列表里没有 Meridian，用“在访达中显示 Meridian”把它拖进去。", "After enabling Meridian in System Settings, click “Reopen Meridian”, then turn on the switch above to take over F1/F2. If Meridian isn't in the list, use “Show Meridian in Finder” and drag it in."))
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
            return L("需要“输入监控”（接收亮度键）和“辅助功能”（拦截系统默认处理）两项权限。", "Requires both “Input Monitoring” (to receive the brightness keys) and “Accessibility” (to block the default system handling).")
        }
        if !permissions.isGranted(.inputMonitoring) { return L("需要“输入监控”权限才能接收 F1 / F2。", "Requires “Input Monitoring” to receive F1 / F2.") }
        if !permissions.isGranted(.accessibility) { return L("需要“辅助功能”权限才能接管系统亮度键。", "Requires “Accessibility” to take over the system brightness keys.") }
        return L("权限已授予，但按键监听尚未生效；重新打开 Meridian 后再试。", "Permissions are granted, but key monitoring isn't active yet; reopen Meridian and try again.")
    }
}

private struct DisplaySection: View {
    @ObservedObject var model: DisplayModel
    let display: ScreenDisplay
    @Local private var brightness: Double = 1
    @Local private var boost: Double = 1
    @Local private var showAllModes = false

    var body: some View {
        Group2(title: display.name + (display.isBuiltIn ? L("（内建）", " (Built-in)") : "")) {
            Row(title: L("亮度", "Brightness"), detail: backendText) {
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
            if display.canBoost {
                Row(title: L("亮度提升", "Brightness Boost"),
                    detail: L("利用 HDR 余量把 SDR 画面提亮到 100% 以上（最高 \(Int((display.edrHeadroom * 100).rounded()))%）。会让 HDR 高光提前截断，看 HDR 视频时建议拉回 100%", "Uses HDR headroom to push SDR content above 100% (up to \(Int((display.edrHeadroom * 100).rounded()))%). HDR highlights clip earlier, so return to 100% for HDR video")) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                        Slider(value: $boost, in: 1...display.edrHeadroom).frame(width: 220)
                            .onChange(of: boost) { _, value in
                                if abs(value - display.boost) > 0.004 { model.setBoost(value, for: display.id) }
                            }
                        Image(systemName: "sun.max.trianglebadge.exclamationmark").foregroundStyle(.secondary)
                        Text("\(Int((boost * 100).rounded()))%").font(.system(size: 12, design: .rounded))
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Row(title: L("分辨率", "Resolution"), detail: resolutionDetail) {
                HStack {
                    if model.busy.contains(display.id) { ProgressView().controlSize(.small) }
                    Picker("", selection: Binding(get: { display.currentResolution?.id ?? "" }, commit: selectResolution)) {
                        ForEach(resolutionOptions) { option in
                            Text(verbatim: label(for: option)).tag(option.id)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                    if !display.isAtNativeSize {
                        Button(L("原生", "Native")) { model.restoreNative(display.id) }
                            .fixedSize()
                            .help(L("回到面板原生尺寸（有 HiDPI 档时用 HiDPI），保持当前刷新率", "Return to the panel's native size (HiDPI when available), keeping the current refresh rate"))
                    }
                }
            }
            Row(title: "HiDPI", detail: hiDPIDetail) {
                Toggle("", isOn: Binding(get: { display.isHiDPI }, commit: { model.setHiDPI($0, for: display.id) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(display.hiDPICounterpart == nil || model.busy.contains(display.id))
            }
            if display.refreshRates.count > 1 {
                Row(title: L("刷新率", "Refresh Rate"), detail: L("只切换刷新率，分辨率不变", "Changes only the refresh rate; resolution stays the same")) {
                    Picker("", selection: Binding(get: { display.currentResolution?.currentRefreshRate ?? 0 },
                                                  commit: { model.applyRefreshRate($0, to: display.id) })) {
                        ForEach(display.refreshRates, id: \.self) { Text(refreshLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    .disabled(model.busy.contains(display.id))
                }
            }
            Row(title: L("显示全部模式", "Show All Modes"), detail: L("默认每个同比例尺寸列一项，跟随 HiDPI 开关；打开后列出系统报告的全部模式", "By default, one entry per same-aspect size, following the HiDPI switch; turn on to list every mode the system reports")) {
                Toggle("", isOn: $showAllModes).toggleStyle(.switch).labelsHidden()
            }
            if !display.isBuiltIn && !display.isOwnVirtual {
                Row(title: L("HiDPI 档位", "HiDPI Modes"), detail: overrideDetail) {
                    HStack {
                        switch display.hiDPIOverride {
                        case .none:
                            Button(L("写入…", "Install…")) { model.installHiDPIOverride(display.id) }
                        case .outdated:
                            Button(L("更新…", "Update…")) { model.installHiDPIOverride(display.id) }
                            Button(L("移除", "Remove")) { model.removeHiDPIOverride(display.id) }
                        case .upToDate:
                            Button(L("移除", "Remove")) { model.removeHiDPIOverride(display.id) }
                        }
                    }
                    .disabled(model.busy.contains(display.id))
                }
            }
            if display.supportsHDR {
                Row(title: "HDR", detail: hdrDetail) {
                    Toggle("", isOn: Binding(get: { display.hdrEnabled ?? false }, commit: { model.setHDR($0, for: display.id) }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(model.busy.contains(display.id))
                }
            }
        }
        .onAppear {
            brightness = display.brightness
            boost = display.boost
        }
        .onChange(of: display.brightness) { _, value in
            if abs(value - brightness) > 0.01 { brightness = value }
        }
        .onChange(of: display.boost) { _, value in
            if abs(value - boost) > 0.01 { boost = value }
        }
    }

    private var resolutionOptions: [ResolutionOption] {
        showAllModes ? display.allResolutions : display.resolutions
    }

    private func label(for option: ResolutionOption) -> String {
        let text = option.fullLabel
        return display.isNativeSize(option) ? text + L("（原生）", " (Native)") : text
    }

    private func selectResolution(_ id: String) {
        guard let option = resolutionOptions.first(where: { $0.id == id }), !option.isCurrent else { return }
        model.applyResolution(option, to: display.id)
    }

    private var resolutionDetail: String {
        guard let current = display.currentResolution else { return "" }
        if current.hiDPI {
            return L("按 \(current.width * 2)×\(current.height * 2) 渲染后缩到 \(display.nativeWidth)×\(display.nativeHeight) 面板，文字清晰；不经过虚拟屏，HDR 与高刷都保留", "Rendered at \(current.width * 2)×\(current.height * 2) and scaled to the \(display.nativeWidth)×\(display.nativeHeight) panel for sharp text; no virtual display, so HDR and high refresh rates are kept")
        }
        return L("面板 \(display.nativeWidth)×\(display.nativeHeight)。普通模式按 1 倍像素渲染，文字不如 HiDPI 清晰", "Panel \(display.nativeWidth)×\(display.nativeHeight). Standard modes render at 1× pixels; text is less sharp than HiDPI")
    }

    private var hiDPIDetail: String {
        switch (display.isHiDPI, display.hiDPICounterpart != nil) {
        case (true, true): return L("已开启：按 2 倍像素渲染。关闭后同尺寸改用普通模式", "On: rendering at 2× pixels. Turn off to use the standard mode at the same size")
        case (false, true): return L("未开启：打开后同尺寸按 2 倍像素渲染，文字更清晰，刷新率不变", "Off: turn on to render at 2× pixels at the same size for sharper text; refresh rate unchanged")
        case (true, false): return L("已开启：这个尺寸只有 HiDPI 模式", "On: this size is only available in HiDPI")
        case (false, false): return L("这个尺寸没有 HiDPI 模式；可换一个分辨率，或在下方写入 HiDPI 档位", "No HiDPI mode at this size; choose another resolution or install HiDPI modes below")
        }
    }

    private var overrideDetail: String {
        switch display.hiDPIOverride {
        case .none:
            return L("为这台显示器写入一组同比例的 HiDPI 档（含原生尺寸），需要管理员授权；重新插拔显示线或注销后出现", "Installs a set of same-aspect HiDPI modes (including native size) for this display; requires administrator approval and appears after replugging the cable or logging out")
        case .outdated:
            return L("已写入的档位不全（旧版只有 2 档），更新后可在中间尺寸之间切换；重新插拔显示线或注销后生效", "Installed modes are incomplete (older versions had only 2); update to switch between intermediate sizes. Takes effect after replugging the cable or logging out")
        case .upToDate:
            return L("已写入全部 HiDPI 档位", "All HiDPI modes installed")
        }
    }

    private var hdrDetail: String? {
        guard display.hdrEnabled == true else { return L("打开后分辨率与刷新率保持不变", "Resolution and refresh rate stay the same when turned on") }
        return display.brightnessBackend == .hdrSDR
            ? L("亮度滑块调节的是 SDR 内容亮度（与控制中心的 HDR 亮度相同），HDR 内容不受影响", "The brightness slider adjusts SDR content brightness (same as HDR brightness in Control Center); HDR content is unaffected")
            : nil
    }

    private var backendText: String {
        switch display.brightnessBackend {
        case .ddc: return L("通过 DDC/CI 调节显示器背光，低于起点后叠加软件调暗", "Adjusts the backlight over DDC/CI, adding software dimming below the threshold")
        case .apple: return L("系统内建屏亮度", "Built-in display brightness")
        case .hdrSDR: return L("HDR 模式：调节 macOS 的 SDR 亮度，不再用 DDC 和软件调暗，避免截断 HDR 高光", "HDR mode: adjusts macOS SDR brightness instead of DDC and software dimming, so HDR highlights aren't clipped")
        case .gammaOnly: return L("此屏不支持硬件调光，使用软件调暗", "No hardware dimming on this display; using software dimming")
        case .unavailable: return L("此屏不支持亮度调节", "This display doesn't support brightness control")
        }
    }
}
