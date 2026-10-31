import AppKit
import SwiftUI

@MainActor
private final class MainWindowState: ObservableObject {
    @Published var isPresented = false
}

private struct MainWindowContent: View {
    @ObservedObject var state: MainWindowState
    let coordinator: AppCoordinator

    var body: some View {
        Group {
            if state.isPresented {
                MainView(coordinator: coordinator, navigation: coordinator.navigation, preferences: coordinator.preferences)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let state = MainWindowState()

    init(coordinator: AppCoordinator) {
        let root = MainWindowContent(state: state, coordinator: coordinator)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Meridian"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 940, height: 660))
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MeridianMainWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        state.isPresented = true
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        // 卸载详情页后 onDisappear 会停止进程排行，窗口本身仍保留位置和大小。
        state.isPresented = false
        // 关闭主窗口只回到菜单栏，所有功能继续运行
        DispatchQueue.main.async { AppCoordinator.shared.reassertActivationPolicy() }
    }
}

struct MainView: View {
    let coordinator: AppCoordinator
    @ObservedObject var navigation: Navigation
    @ObservedObject var preferences: Preferences

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(navigation.page) }, commit: { if let page = $0 { navigation.page = page } })) {
                Label("概览", systemImage: "square.grid.2x2").tag(Page.overview)
                Section("功能") {
                    ForEach(Feature.allCases) { feature in
                        HStack(spacing: 8) {
                            FeatureBadge(feature: feature, size: 20)
                            Text(feature.title)
                            Spacer()
                            if !preferences.isEnabled(feature) {
                                Text("已关闭").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(Page.feature(feature))
                    }
                }
                Section {
                    Label("通用", systemImage: "gearshape").tag(Page.general)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                page
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder private var page: some View {
        switch navigation.page {
        case .overview:
            OverviewPage(coordinator: coordinator, preferences: preferences, conflicts: coordinator.conflicts,
                         permissions: coordinator.permissions, display: coordinator.display, thermal: coordinator.thermal,
                         pointer: coordinator.pointer, telemetry: coordinator.telemetry)
        case .feature(let feature):
            FeaturePage(feature: feature, preferences: preferences) {
                switch feature {
                case .capture: CapturePage(model: coordinator.capture, preferences: preferences)
                case .display: DisplayPage(model: coordinator.display, permissions: coordinator.permissions)
                case .thermal: ThermalPage(model: coordinator.thermal, preferences: preferences)
                case .pointer: PointerPage(model: coordinator.pointer, preferences: preferences)
                case .telemetry: TelemetryPage(model: coordinator.telemetry, preferences: preferences)
                }
            }
        case .general:
            GeneralPage(coordinator: coordinator, preferences: preferences, permissions: coordinator.permissions)
        }
    }
}

/// 每个功能页的统一页头：图标、用途、总开关。关闭后只显示说明，不展示失效的控件。
struct FeaturePage<Content: View>: View {
    let feature: Feature
    @ObservedObject var preferences: Preferences
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                FeatureBadge(feature: feature, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title).font(.system(size: 22, weight: .bold))
                    Text(feature.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: Binding(get: { preferences.isEnabled(feature) },
                                            commit: { preferences.setEnabled(feature, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(preferences.isEnabled(feature) ? "关闭此功能（停止其后台活动）" : "启用此功能")
            }
            if preferences.isEnabled(feature) {
                content
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "power").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("\(feature.title)已关闭").font(.headline)
                    Text("关闭后不再占用后台资源，也不会出现在菜单栏面板里。").font(.callout).foregroundStyle(.secondary)
                    Button("启用") { preferences.setEnabled(feature, true) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
    }
}

/// 主窗口里的分组：标题 + 圆角内容块，行之间带分隔线。
struct Group2<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index].padding(.vertical, 10)
                        if index < subviews.count - 1 { Divider() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

/// 标准设置行：左标题（可带说明），右控件。
struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 24)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var onCommit: () -> Void = {}

    var body: some View {
        Row(title: title) {
            HStack(spacing: 10) {
                // 不用 Slider 的 step 参数：macOS 26 会为每一档画刻度，改为在绑定里取整
                Slider(value: Binding(get: { value }, set: { raw in
                    guard let step else { value = raw; return }
                    value = (raw / step).rounded() * step
                }), in: range) { editing in if !editing { onCommit() } }
                .frame(width: 220)
                Text(format(value)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                    .frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}
