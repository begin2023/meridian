import AppKit
import Combine
import ScreenshotLabKit

/// 截图与识字：编辑器、贴图、OCR、GIF 和历史都来自截图模块，本类只做状态与设置的桥接。
@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var gifRecording = false
    @Published private(set) var pinCount = 0

    @Published var copyImageAsFile = true
    @Published var quickSaveDirectory = ""
    @Published var screenshotScale = 1.0
    @Published var historyLimit = 10
    @Published var gifWidth = 960
    @Published var gifFPS = 10
    @Published var lastError: String?

    static let scaleOptions: [Double] = [1, 0.75, 0.5, 0.25]
    static let gifWidthOptions = [480, 640, 960, 1280]
    static let gifFPSOptions = [5, 10, 15, 20]

    private let module: ScreenshotLabModule

    init(suite: String) {
        module = Suites.withSuite(suite) {
            let module = ScreenshotLabModule(embedded: true)
            _ = module.settingsSnapshot()
            return module
        }
        module.onShowPreferences = { AppCoordinator.shared.openMain(.feature(.capture)) }
        loadSettings()
    }

    func start() {
        guard !running else { return }
        module.start()
        running = true
        refreshState()
    }

    func stop() {
        guard running else { return }
        module.stop()
        running = false
    }

    // MARK: 动作

    func capture() { guardRunning { $0.beginCapture() } }
    func captureOCR() { guardRunning { $0.beginOCRCapture() } }
    func capturePin() { guardRunning { $0.beginPinCapture() } }
    func captureFullScreen() { guardRunning { $0.captureFullScreen() } }
    func captureWindow() { guardRunning { $0.captureActiveWindow() } }
    func captureLastArea() { guardRunning { $0.captureLastArea() } }
    func captureDelayed(_ seconds: Double = 3) { guardRunning { $0.captureDelayed(seconds: seconds) } }

    func toggleGIF() {
        guardRunning { module in
            if module.isGIFRecording { module.stopGIF(save: true) } else { module.beginGIF() }
        }
    }

    func showHistory() { guardRunning { $0.showHistory() } }
    func openImage() { guardRunning { $0.openImagePanel() } }
    func showPins() { guardRunning { $0.showAllPins() } }
    func hidePins() { guardRunning { $0.hideAllPins() } }
    func closePins() { guardRunning { $0.closeAllPins() } }

    func requestPermission() {
        Permissions.request(.screenRecording)
        refreshState()
    }

    func refreshState() {
        permissionGranted = CGPreflightScreenCaptureAccess()
        gifRecording = running && module.isGIFRecording
        pinCount = running ? module.pinCount : 0
    }

    private func guardRunning(_ action: (ScreenshotLabModule) -> Void) {
        if !running { start() }
        action(module)
        // 截图会话异步展开，稍后同步 GIF/贴图计数
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshState() }
    }

    // MARK: 设置

    private func loadSettings() {
        let snapshot = module.settingsSnapshot()
        copyImageAsFile = snapshot["copyImageAsFile"] as? Bool ?? true
        quickSaveDirectory = snapshot["quickSaveDirectory"] as? String ?? ""
        screenshotScale = snapshot["screenshotScale"] as? Double ?? 1
        historyLimit = snapshot["screenshotHistoryLimit"] as? Int ?? 10
        gifWidth = snapshot["gifMaximumWidth"] as? Int ?? 960
        gifFPS = snapshot["gifFramesPerSecond"] as? Int ?? 10
    }

    func update(_ changes: [String: Any]) {
        let result = module.updateSettings(changes)
        if result["ok"] as? Bool != true {
            lastError = result["message"] as? String ?? result["error"] as? String ?? "设置未保存"
        } else {
            lastError = nil
        }
        loadSettings()
    }

    func chooseQuickSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: quickSaveDirectory)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update(["quickSaveDirectory": url.path])
    }
}
