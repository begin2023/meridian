import SwiftUI

/// 概览：每个功能一张卡片——状态一眼可见，一键进入或启停；下方是需要处理的事项。
struct OverviewPage: View {
    let coordinator: AppCoordinator
    @ObservedObject var preferences: Preferences
    @ObservedObject var conflicts: ConflictMonitor
    @ObservedObject var permissions: PermissionMonitor
    @ObservedObject var display: DisplayModel
    @ObservedObject var thermal: ThermalModel
    @ObservedObject var pointer: PointerModel
    @ObservedObject var telemetry: TelemetryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meridian").font(.system(size: 28, weight: .bold))
                Text("截图、显示器、散热、滚动与监控合在一个应用里。点菜单栏 ⊞ 图标随时打开控制中心。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if !todo.isEmpty || !conflicts.running.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("需要处理").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(todo) { item in
                        PermissionBanner(permission: item, granted: false) { Permissions.request(item) }
                    }
                    ForEach(conflicts.running) { conflict in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(conflict.name) 正在运行").font(.system(size: 12, weight: .semibold))
                                Text(conflict.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("退出它") { conflicts.quit(conflict) }.controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Feature.allCases) { feature in
                    FeatureCard(feature: feature, status: status(feature), enabled: preferences.isEnabled(feature)) {
                        coordinator.navigation.page = .feature(feature)
                    } toggle: { on in
                        preferences.setEnabled(feature, on)
                    }
                }
            }
        }
    }

    /// 只列出已启用功能真正缺少的权限。
    private var todo: [Permission] {
        var list: [Permission] = []
        if preferences.isEnabled(.capture) && !permissions.isGranted(.screenRecording) { list.append(.screenRecording) }
        if preferences.isEnabled(.pointer) && !permissions.isGranted(.accessibility) { list.append(.accessibility) }
        return list
    }

    private func status(_ feature: Feature) -> String {
        guard preferences.isEnabled(feature) else { return "已关闭" }
        switch feature {
        case .capture:
            let key = preferences.hotKeys[.capture]?.displayString ?? "未设置快捷键"
            return permissions.isGranted(.screenRecording) ? "就绪 · \(key)" : "等待屏幕录制权限"
        case .display:
            let list = display.displays
            guard let first = list.first else { return "未检测到显示器" }
            let brightness = first.brightnessBackend == .unavailable ? "" : " · 亮度 \(Int(first.brightness * 100))%"
            return "\(list.count) 台显示器\(brightness)"
        case .thermal:
            let fans = thermal.fans
            let rpm = fans.first.map { "\(Int($0.currentRPM)) RPM" } ?? "读取中"
            let temp = thermal.hottestCPU.map { " · CPU \(thermal.temperature($0))" } ?? ""
            return "\(thermal.overallPreset.title) · \(rpm)\(temp)"
        case .pointer:
            let model = pointer
            if !model.accessibilityGranted { return "等待辅助功能权限" }
            if model.paused { return "已临时暂停" }
            var parts: [String] = []
            if model.smooth { parts.append("平滑") }
            if model.reverse { parts.append("反向") }
            return model.enabled ? (parts.isEmpty ? "已启用" : parts.joined(separator: " + ")) : "增强已关闭"
        case .telemetry:
            let s = telemetry.snapshot
            return "CPU \(Format.percent(s.cpuPercent)) · 内存 \(Format.percent(s.memoryFraction * 100))"
        }
    }
}

private struct FeatureCard: View {
    let feature: Feature
    let status: String
    let enabled: Bool
    let open: () -> Void
    let toggle: (Bool) -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    FeatureBadge(feature: feature, size: 34)
                    Spacer()
                    Toggle("", isOn: Binding(get: { enabled }, commit: toggle))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                Text(feature.title).font(.system(size: 15, weight: .semibold))
                Text(feature.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusDot(on: enabled)
                    Text(status).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .opacity(enabled ? 1 : 0.7)
    }
}
