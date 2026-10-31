import AppKit
import Combine
import ScrollLabKit

/// 一条按应用的滚动例外，与滚动模块的 AppException 字段一一对应。
struct ScrollException: Identifiable, Equatable {
    var id: String
    var name: String
    var bundlePath: String
    var executablePath: String
    var inherit: Bool
    var reverse: Bool
    var smooth: Bool
    var step: Double
    var speed: Double
    var duration: Double

    init(dictionary: [String: Any]) {
        id = dictionary["id"] as? String ?? UUID().uuidString
        name = dictionary["name"] as? String ?? ""
        bundlePath = dictionary["bundlePath"] as? String ?? ""
        executablePath = dictionary["executablePath"] as? String ?? ""
        inherit = dictionary["inherit"] as? Bool ?? true
        reverse = dictionary["reverse"] as? Bool ?? false
        smooth = dictionary["smooth"] as? Bool ?? true
        step = dictionary["step"] as? Double ?? 33.6
        speed = dictionary["speed"] as? Double ?? 2.7
        duration = dictionary["duration"] as? Double ?? 4.35
    }

    var dictionary: [String: Any] {
        [
            "id": id, "name": name, "bundlePath": bundlePath, "executablePath": executablePath,
            "inherit": inherit, "reverse": reverse, "reverseVertical": true, "reverseHorizontal": true,
            "smooth": smooth, "smoothVertical": true, "smoothHorizontal": true,
            "step": step, "speed": speed, "duration": duration,
        ]
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: bundlePath) }
}

/// 鼠标滚动：事件 tap 与平滑动画在滚动模块里运行，本类桥接设置与状态。
@MainActor
final class PointerModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var tapActive = false
    @Published private(set) var paused = false

    @Published private(set) var enabled = true
    @Published private(set) var reverse = false
    @Published private(set) var reverseVertical = true
    @Published private(set) var reverseHorizontal = true
    @Published private(set) var smooth = true
    @Published private(set) var smoothVertical = true
    @Published private(set) var smoothHorizontal = true
    @Published private(set) var simulateTrackpad = false
    @Published private(set) var step = 33.6
    @Published private(set) var speed = 2.7
    @Published private(set) var duration = 4.35
    @Published private(set) var allowlist = false
    @Published private(set) var exceptions: [ScrollException] = []
    @Published var lastError: String?

    private let module: ScrollLabModule
    private var poll: Timer?

    init(suite: String) {
        module = Suites.withSuite(suite) {
            let module = ScrollLabModule(embedded: true)
            _ = module.settingsSnapshot()
            return module
        }
        module.onShowPreferences = { AppCoordinator.shared.openMain(.feature(.pointer)) }
        load()
    }

    func start() {
        guard !running else { return }
        module.start()
        running = true
        // 滚动模块在启动时会把激活策略设为 accessory，由协调器重新确定
        AppCoordinator.shared.reassertActivationPolicy()
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        poll?.tolerance = 0.5
    }

    func stop() {
        guard running else { return }
        poll?.invalidate()
        poll = nil
        module.stop()
        running = false
        refresh()
    }

    func refresh() {
        let summary = module.summary()
        let granted = summary["accessibilityGranted"] as? Bool ?? AXIsProcessTrusted()
        let active = running && (summary["eventTapActive"] as? Bool ?? false)
        let isPaused = summary["temporarilyPaused"] as? Bool ?? false
        if accessibilityGranted != granted { accessibilityGranted = granted }
        if tapActive != active { tapActive = active }
        if paused != isPaused { paused = isPaused }
    }

    private func load() {
        let s = module.settingsSnapshot()
        enabled = s["enabled"] as? Bool ?? true
        reverse = s["reverse"] as? Bool ?? false
        reverseVertical = s["reverseVertical"] as? Bool ?? true
        reverseHorizontal = s["reverseHorizontal"] as? Bool ?? true
        smooth = s["smooth"] as? Bool ?? true
        smoothVertical = s["smoothVertical"] as? Bool ?? true
        smoothHorizontal = s["smoothHorizontal"] as? Bool ?? true
        simulateTrackpad = s["smoothSimTrackpad"] as? Bool ?? false
        step = s["step"] as? Double ?? 33.6
        speed = s["speed"] as? Double ?? 2.7
        duration = s["duration"] as? Double ?? 4.35
        allowlist = s["allowlist"] as? Bool ?? false
        exceptions = (s["exceptions"] as? [[String: Any]] ?? []).map(ScrollException.init(dictionary:))
    }

    func set(_ key: String, _ value: Any) {
        let result = module.updateSettings([key: value])
        lastError = result["ok"] as? Bool == true ? nil : (result["message"] as? String ?? "设置未保存")
        load()
        refresh()
    }

    func togglePause() {
        _ = module.execute(command: paused ? "resume" : "pause", payload: [:])
        refresh()
    }

    func requestPermission() {
        _ = module.execute(command: "requestPermission", payload: [:])
        Permissions.open(.accessibility)
        refresh()
    }

    // MARK: 应用例外

    func addException() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var list = exceptions
        for url in panel.urls where !list.contains(where: { $0.bundlePath == url.path }) {
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            var entry = ScrollException(dictionary: [:])
            entry.name = name
            entry.bundlePath = url.path
            entry.executablePath = bundle?.executableURL?.path ?? ""
            entry.step = step
            entry.speed = speed
            entry.duration = duration
            list.append(entry)
        }
        saveExceptions(list)
    }

    func updateException(_ entry: ScrollException) {
        var list = exceptions
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return }
        list[index] = entry
        saveExceptions(list)
    }

    func removeException(_ id: String) {
        saveExceptions(exceptions.filter { $0.id != id })
    }

    private func saveExceptions(_ list: [ScrollException]) {
        set("exceptions", list.map(\.dictionary))
    }
}
