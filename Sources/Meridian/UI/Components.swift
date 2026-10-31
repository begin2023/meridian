import AppKit
import SwiftUI

// MARK: - 布局常量

enum Metrics {
    static let panelWidth: CGFloat = 372
    static let cardRadius: CGFloat = 16
    static let tileRadius: CGFloat = 14
}

extension Feature {
    var color: Color { Color(nsColor: tint) }
}

// MARK: - 卡片与分区

/// 控制中心里的分组底板：弹出面板本身已是 Liquid Glass，这里只用淡填充分层，避免玻璃叠玻璃。
struct PanelCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct CardHeader<Accessory: View>: View {
    let feature: Feature
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            FeatureBadge(feature: feature, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? feature.title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(feature: Feature, title: String? = nil, subtitle: String? = nil) {
        self.init(feature: feature, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct FeatureBadge: View {
    let feature: Feature
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: feature.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(feature.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

// MARK: - 动作磁贴

/// 控制中心的大按钮：原生玻璃按钮样式，按下有系统交互反馈。
struct ActionTile: View {
    let symbol: String
    let title: String
    var caption: String? = nil
    var tint: Color = .accentColor
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.white : tint)
                    .frame(height: 22)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(active ? Color.white : Color.primary)
                if let caption {
                    Text(caption).font(.system(size: 9.5, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: caption == nil ? 52 : 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(tint.opacity(0.75)).interactive() : .regular.interactive(),
                     in: RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
    }
}

/// 小号胶囊按钮（次要动作）。
struct ChipButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

// MARK: - 图表

struct Sparkline: View {
    let values: [Double]
    var secondary: [Double] = []
    var maxValue: Double? = nil
    var color: Color = .accentColor
    var secondaryColor: Color = .orange
    var fill = true
    var capacity = TelemetryModel.historyLength

    var body: some View {
        GeometryReader { geometry in
            let top = maxValue ?? max((values + secondary).max() ?? 1, 1)
            ZStack {
                if fill {
                    area(values, top: top, in: geometry.size)
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                }
                line(values, top: top, in: geometry.size)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if !secondary.isEmpty {
                    line(secondary, top: top, in: geometry.size)
                        .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(_ data: [Double], top: Double, in size: CGSize) -> [CGPoint] {
        guard !data.isEmpty else { return [] }
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let offset = CGFloat(capacity - data.count) * step
        return data.enumerated().map { index, value in
            CGPoint(x: offset + CGFloat(index) * step,
                    y: size.height - CGFloat(min(value / top, 1)) * (size.height - 1.5) - 0.75)
        }
    }

    private func line(_ data: [Double], top: Double, in size: CGSize) -> Path {
        Path { path in
            let pts = points(data, top: top, in: size)
            guard let first = pts.first else { return }
            path.move(to: first)
            pts.dropFirst().forEach { path.addLine(to: $0) }
        }
    }

    private func area(_ data: [Double], top: Double, in size: CGSize) -> Path {
        Path { path in
            let pts = points(data, top: top, in: size)
            guard let first = pts.first, let last = pts.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            pts.forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

struct MeterBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    init(fraction: Double, color: Color, height: CGFloat = 6) {
        segments = [Segment(fraction: fraction, color: color)]
        self.height = height
    }

    init(segments: [Segment], height: CGFloat = 8) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.color)
                            .frame(width: max(0, min(1, segment.fraction)) * geometry.size.width)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

/// 数值 + 小标题的紧凑统计块。
struct StatValue: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

// MARK: - 权限与提示

struct PermissionBanner: View {
    let permission: Permission
    let granted: Bool
    let request: () -> Void

    var body: some View {
        if !granted {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("需要“\(permission.title)”权限").font(.system(size: 12, weight: .semibold))
                        Text(permission.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("请求权限", action: request).controlSize(.small).buttonStyle(.borderedProminent)
                        .help("由系统弹出授权提示，Meridian 会自动出现在权限列表中")
                }
                HStack(spacing: 14) {
                    Button("打开\(permission.settingsTitle)") { Permissions.open(permission) }
                    Button("在访达中显示 Meridian") { Permissions.revealApp() }
                    Spacer()
                }
                .buttonStyle(.link).font(.system(size: 10.5))
                Text(hint)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 系统权限列表只在“应用请求过”之后才会出现 Meridian；提示里给出列表缺项时的兜底办法。
    private var hint: String {
        let drag = "如果列表里没有 Meridian，点“在访达中显示 Meridian”，把 Meridian.app 拖进列表（或点 + 选择它）。"
        switch permission {
        case .screenRecording:
            return "允许后可能需要退出并重新打开 Meridian 才会生效。" + drag
        case .accessibility:
            return "macOS 27 将此页显示为“设备控制和数据访问”；打开 Meridian 后通常无需重启，回到应用即可刷新状态。" + drag
        case .inputMonitoring:
            return "在“输入监控”里打开 Meridian 即可。" + drag
        }
    }
}

struct InlineMessage: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
    }
}

// MARK: - 快捷键录制

struct HotKeyRecorder: View {
    let action: HotKeyAction
    @ObservedObject var preferences: Preferences
    @Local private var recording = false
    @Local private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : begin()
            } label: {
                Text(recording ? "请按下快捷键…" : (preferences.hotKeys[action]?.displayString ?? "未设置"))
                    .font(.system(size: 12, design: .rounded))
                    .frame(width: 112)
                    .foregroundStyle(recording ? Color.accentColor : (preferences.hotKeys[action] == nil ? .secondary : .primary))
            }
            .buttonStyle(.bordered)
            Button {
                preferences.setHotKey(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preferences.hotKeys[action] == nil || recording)
            .opacity(preferences.hotKeys[action] == nil || recording ? 0.25 : 1)
            .help("清除快捷键")
            .frame(width: 18)
        }
        .onDisappear { stop() }
    }

    private func begin() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc 取消
            if let combo = KeyCombo(event: event) {
                // 同一组合只保留在最新的动作上
                for (other, existing) in preferences.hotKeys where existing == combo && other != action {
                    preferences.setHotKey(nil, for: other)
                }
                preferences.setHotKey(combo, for: action)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            AppCoordinator.shared.applyHotKeys()
        }
    }
}

/// Binding 辅助：从只读发布属性 + 写入闭包构造。
extension Binding {
    init(get: @escaping () -> Value, commit: @escaping (Value) -> Void) {
        self.init(get: get, set: commit)
    }
}

/// 视图本地状态。命令行工具链缺少 SwiftUI 的 @Local 宏插件，这里直接包装 State 类型。
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
