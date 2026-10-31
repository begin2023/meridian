import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

private enum LocalImageOpenError: LocalizedError {
    case unreadable
    case unsupportedType
    case fileTooLarge
    case invalidDimensions
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取所选图片文件。"
        case .unsupportedType:
            return "所选文件不是受支持的图片格式。"
        case .fileTooLarge:
            return "所选图片超过 128 MiB 限制。"
        case .invalidDimensions:
            return "图片尺寸为空、超过 16384 像素或总像素超过 6400 万。"
        case .decodeFailed:
            return "无法解码所选图片。"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let embedded: Bool
    var onShowPreferences: (() -> Void)?
    private(set) var isStarted = false
    private let settings = AppSettings.shared
    private let captureController = CaptureController()
    private let pinManager = PinManager()
    private let toastPresenter = ToastPresenter()
    private let windowPresence = WindowPresenceController()
    private var editorControllers: [EditorWindowController] = []
    private var captureHotKeyManager: HotKeyManager?
    private var gifHotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private weak var captureMenuItem: NSMenuItem?
    private var ocrWindowController: OCRResultWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var lastExternalActivePID: pid_t?
    private var gifRecorder: GIFRecorder?
    private var gifRecordingHUD: GIFRecordingHUDController?
    private var gifRecordingStarting = false
    private var gifStartTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private weak var gifMenuItem: NSMenuItem?
    private weak var recentSavedMenuItem: NSMenuItem?
    private var savedFileControllers: [SavedFileWindowController] = []
    private let screenshotHistoryStore = ScreenshotHistoryStore()
    private var screenshotHistoryWindowController: ScreenshotHistoryWindowController?
    private var e2eGIFCaptureCallbacks = 0
    private(set) var lastError: String?

    init(embedded: Bool) {
        self.embedded = embedded
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if !embedded {
            configureMainMenu()
        }

        if !embedded {
            NSApp.setActivationPolicy(.accessory)
            configureStatusItem()
            configureHotKey()
        }
        configureCaptureController()
        configurePinManager()
        configureScreenshotHistory()
        observeActiveApplications()

        if !embedded {
            runLaunchActions()
        }
    }

    private func runLaunchActions() {
        if CommandLine.arguments.contains("--editor-interaction-test") {
            EditorInteractionTest.run(presence: windowPresence)
        } else if CommandLine.arguments.contains("--pin-interaction-test") {
            PinInteractionTest.run()
        } else if CommandLine.arguments.contains("--history-test") {
            HistoryTest.run()
        } else if CommandLine.arguments.contains("--gif-motion-test") {
            GIFMotionTest.run()
        } else if CommandLine.arguments.contains("--e2e") {
            runEndToEndTest()
        } else if CommandLine.arguments.contains("--capture-probe") {
            runCaptureProbe()
        } else if CommandLine.arguments.contains("--capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.captureController.beginCapture()
            }
        } else if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.captureController.beginDemoCapture()
            }
        } else if CommandLine.arguments.contains("--demo-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openEditor(with: DebugFixtures.makeSampleImage())
            }
        } else if CommandLine.arguments.contains("--demo-crop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else {
                    return
                }
                let snapshot = DebugFixtures.makeSnapshot()
                let selection = CGRect(
                    x: 92,
                    y: 130,
                    width: min(980, snapshot.screenFrame.width - 184),
                    height: min(620, snapshot.screenFrame.height - 260)
                )
                if let cropped = ImageCropper.crop(
                    snapshot: snapshot,
                    localSelection: selection
                ) {
                    try? ImageOutput.writePNG(
                        cropped,
                        to: URL(fileURLWithPath: "/tmp/screenshotlab-demo-crop.png")
                    )
                    self.openEditor(with: cropped)
                }
            }
        } else if CommandLine.arguments.contains("--demo-pin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pinManager.add(image: DebugFixtures.makeSampleImage())
            }
        } else if CommandLine.arguments.contains("--demo-ocr") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.performOCR(on: DebugFixtures.makeSampleImage())
            }
        } else if CommandLine.arguments.contains("--preferences") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPreferences()
            }
        } else if CommandLine.arguments.contains("--output-smoke") {
            runOutputSmokeTest()
        } else if CommandLine.arguments.contains("--gif-smoke") {
            runGIFSmokeTest()
        } else if CommandLine.arguments.contains("--demo-gif-hud") {
            let hud = GIFRecordingHUDController()
            gifRecordingHUD = hud
            hud.show(on: ScreenCaptureService.screenAtMouse())
            hud.update(elapsed: 12.4, frames: 124)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak hud] in
                hud?.window?.contentView?.writeDebugPNG(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-gif-hud.png")
                )
            }
        } else if CommandLine.arguments.contains("--demo-saved-file") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenshotLab-demo-saved.png")
            try? ImageOutput.writePNG(DebugFixtures.makeSampleImage(), to: url)
            showSavedFile(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showApplicationWindows()
        return false
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let productName = embedded ? "Meridian 截图" : "ScreenshotLab"
        let appMenu = NSMenu(title: productName)
        appMenu.addItem(menuItem(title: "偏好设置…", action: #selector(showPreferences), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏\(productName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        if !embedded {
            appMenu.addItem(.separator())
            appMenu.addItem(menuItem(title: "退出 ScreenshotLab", action: #selector(quit), key: "q"))
        }

        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(menuItem(title: "新建截图", action: #selector(startCapture), key: "n"))
        fileMenu.addItem(menuItem(title: "保存图片…", action: #selector(saveEditorImage), key: "s"))
        let quick = menuItem(title: "快速保存到默认目录", action: #selector(quickSaveEditorImage), key: "s")
        quick.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(quick)
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem(title: "截图历史…", action: #selector(showScreenshotHistory), key: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: #selector(AnnotationCanvasView.undo(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: #selector(AnnotationCanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(title: "清空所有标注…", action: #selector(clearEditorAnnotations), key: ""))

        let windowsMenu = NSMenu(title: "窗口")
        windowsMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowsMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowsMenu.addItem(.separator())
        windowsMenu.addItem(menuItem(title: "显示所有窗口", action: #selector(showApplicationWindows), key: ""))
        for submenu in [appMenu, fileMenu, editMenu, windowsMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowsMenu
    }

    @objc func showApplicationWindows() {
        if windowPresence.hasWindows {
            windowPresence.bringForward()
        } else {
            showPreferences()
        }
    }

    private var keyEditor: EditorWindowController? {
        editorControllers.first { $0.window === NSApp.keyWindow }
    }

    @objc private func saveEditorImage() { keyEditor?.performAction(.save) }
    @objc private func quickSaveEditorImage() { keyEditor?.performAction(.quickSave) }
    @objc private func clearEditorAnnotations() { keyEditor?.confirmClearAll() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveEditorImage) || menuItem.action == #selector(quickSaveEditorImage) {
            return keyEditor != nil
        }
        if menuItem.action == #selector(clearEditorAnnotations) { return keyEditor?.canvas.hasAnnotations == true }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenURLs(urls)
    }

    func handleOpenURLs(_ urls: [URL]) {
        for url in urls where url.scheme == "screenshotlab" {
            switch url.host {
            case "capture":
                captureController.beginCapture()
            case "last":
                captureController.beginCapture(usingLastSelection: true)
            case "preferences":
                showPreferences()
            case "demo":
                captureController.beginDemoCapture()
            case "editor":
                openEditor(with: DebugFixtures.makeSampleImage())
            case "pin":
                pinManager.add(image: DebugFixtures.makeSampleImage())
            case "ocr":
                performOCR(on: DebugFixtures.makeSampleImage())
            case "gif":
                beginGIFSelection()
            default:
                break
            }
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = AppTheme.symbol("viewfinder", size: 16, weight: .semibold)
            button.image?.isTemplate = true
            button.toolTip = "ScreenshotLab"
        }

        let menu = NSMenu()
        let captureItem = menuItem(
            title: "截图    \(settings.captureHotKey.name)",
            action: #selector(startCapture),
            key: ""
        )
        captureMenuItem = captureItem
        menu.addItem(captureItem)
        menu.addItem(menuItem(
            title: "截取当前屏幕",
            action: #selector(captureFullScreen),
            key: ""
        ))
        menu.addItem(menuItem(
            title: "截取活动窗口",
            action: #selector(captureActiveWindow),
            key: ""
        ))
        menu.addItem(menuItem(
            title: "延时 3 秒截图",
            action: #selector(captureDelayedAction),
            key: ""
        ))
        let gifItem = menuItem(
            title: "录制 GIF…",
            action: #selector(beginGIFSelection),
            key: ""
        )
        gifMenuItem = gifItem
        menu.addItem(gifItem)
        let recentItem = menuItem(
            title: "打开最近保存",
            action: #selector(openRecentSavedFile),
            key: ""
        )
        recentSavedMenuItem = recentItem
        recentItem.isEnabled = settings.recentSavedFile.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        menu.addItem(recentItem)
        menu.addItem(menuItem(
            title: "截图历史…",
            action: #selector(showScreenshotHistory),
            key: ""
        ))
        menu.addItem(menuItem(
            title: "截取上一次区域",
            action: #selector(captureLastArea),
            key: ""
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "显示全部钉图",
            action: #selector(showAllPins),
            key: ""
        ))
        menu.addItem(menuItem(
            title: "隐藏全部钉图",
            action: #selector(hideAllPins),
            key: ""
        ))
        menu.addItem(menuItem(
            title: "关闭全部钉图",
            action: #selector(closeAllPins),
            key: ""
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "显示所有窗口", action: #selector(showApplicationWindows), key: ""))
        menu.addItem(menuItem(
            title: "偏好设置…",
            action: #selector(showPreferences),
            key: ","
        ))
        menu.addItem(menuItem(
            title: "屏幕录制权限…",
            action: #selector(showScreenPermissionHelp),
            key: ""
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "退出 ScreenshotLab",
            action: #selector(quit),
            key: "q"
        ))
        statusItem?.menu = menu
    }

    private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func configureHotKey() {
        captureHotKeyManager = HotKeyManager(identifier: 1) { [weak self] in
            self?.captureController.beginCapture()
        }
        gifHotKeyManager = HotKeyManager(identifier: 2) { [weak self] in
            self?.beginGIFSelection()
        }
        applyHotKeys()
    }

    @discardableResult
    func applyHotKeys() -> Bool {
        guard !embedded else { return false }
        let captureRegistered = captureHotKeyManager?.register(
            settings.captureHotKey
        ) ?? false
        let gifRegistered = gifHotKeyManager?.register(settings.gifHotKey) ?? false
        captureMenuItem?.title = "截图    \(settings.captureHotKey.name)"
        gifMenuItem?.title = "录制 GIF…    \(settings.gifHotKey.name)"

        if !captureRegistered || !gifRegistered {
            showTemporaryMessage(
                "快捷键已被其他应用占用，请换一个",
                duration: 4
            )
        }
        return captureRegistered && gifRegistered
    }

    private func configureCaptureController() {
        captureController.onCopy = { [weak self] image in
            self?.copyImage(image)
        }
        captureController.onSave = { [weak self] image in
            self?.saveImage(image)
        }
        captureController.onQuickSave = { [weak self] image in
            self?.quickSaveImage(image)
        }
        captureController.onPin = { [weak self] image, screenRect in
            self?.recordHistoryImage(image)
            self?.pinManager.add(image: image, anchor: screenRect)
        }
        captureController.onEdit = { [weak self] image in
            self?.openEditor(with: image)
        }
        captureController.onOCR = { [weak self] image, screenRect in
            self?.performOCR(
                on: image,
                sourceFrame: screenRect,
                pinImage: true
            )
        }
        captureController.onGIF = { [weak self] region in
            self?.startGIFRecording(region: region)
        }
        captureController.onError = { [weak self] error in
            self?.showError(error)
        }
    }

    private func configurePinManager() {
        pinManager.onCopy = { [weak self] image in
            self?.copyImage(image)
        }
        pinManager.onSave = { [weak self] image in
            self?.saveImage(image)
        }
        pinManager.onQuickSave = { [weak self] image in
            self?.quickSaveImage(image)
        }
        pinManager.onOCR = { [weak self] image, sourceFrame in
            self?.performOCR(on: image, sourceFrame: sourceFrame)
        }
        pinManager.onEdit = { [weak self] image in
            self?.openEditor(with: image)
        }
    }

    private func observeActiveApplications() {
        lastExternalActivePID = currentExternalPID()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func startCapture() {
        beginCapture()
    }

    func beginCapture() {
        lastError = nil
        captureController.beginCapture()
    }

    func beginOCRCapture() {
        lastError = nil
        captureController.beginCapture(autoAction: .ocr)
    }

    func beginPinCapture() {
        lastError = nil
        captureController.beginCapture(autoAction: .pin)
    }

    func openImage(at url: URL) {
        openSelectedImage(at: url)
    }

    @objc func captureLastArea() {
        lastError = nil
        captureController.beginCapture(usingLastSelection: true)
    }

    @objc func captureFullScreen() {
        lastError = nil
        captureController.beginFullScreenCapture()
    }

    @objc func captureActiveWindow() {
        do {
            try captureActiveWindowForAPI()
        } catch {
            showError(error)
        }
    }

    func captureActiveWindowForAPI() throws {
        guard let pid = currentExternalPID() else {
            throw ScreenCaptureError.windowNotFound
        }
        lastError = nil
        captureController.beginWindowCapture(ownerPID: pid)
    }

    @objc func captureDelayedAction() {
        captureDelayed(seconds: 3)
    }

    func captureDelayed(seconds: TimeInterval) {
        lastError = nil
        captureController.beginDelayedCapture(seconds: seconds)
        showTemporaryMessage("\(Int(seconds.rounded())) 秒后截图")
    }

    @objc func beginGIFSelection() {
        guard gifRecorder == nil, !gifRecordingStarting else {
            NSSound.beep()
            return
        }
        captureController.beginCapture(forGIF: true)
    }

    @objc private func stopGIFRecordingAction() {
        stopGIFRecording(save: true)
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication else {
            return
        }
        if application.processIdentifier != getpid() {
            lastExternalActivePID = application.processIdentifier
        }
    }

    private func currentExternalPID() -> pid_t? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != getpid() {
            return frontmost.processIdentifier
        }
        return lastExternalActivePID
    }

    var isGIFRecording: Bool { gifRecorder != nil || gifRecordingStarting }

    var pinCount: Int { pinManager.count }

    @objc func showAllPins() {
        pinManager.showAll()
    }

    @objc func hideAllPins() {
        pinManager.hideAll()
    }

    @objc func closeAllPins() {
        pinManager.closeAll()
    }

    @objc func showScreenshotHistory() {
        if screenshotHistoryWindowController == nil {
            let controller = ScreenshotHistoryWindowController(store: screenshotHistoryStore)
            controller.onEdit = { [weak self] image in
                self?.openEditor(with: image)
            }
            controller.onCopy = { [weak self] image in
                // Re-outputting a history entry is not a new capture; do not
                // record it again.
                self?.copyImage(image, recordInHistory: false)
            }
            controller.onLimitChanged = { [weak self] limit in
                self?.settings.screenshotHistoryLimit = limit
            }
            screenshotHistoryWindowController = controller
        }
        windowPresence.register(screenshotHistoryWindowController?.window)
        screenshotHistoryWindowController?.show()
    }

    private func configureScreenshotHistory() {
        // The preferences value is the source of truth for retention; the
        // store keeps the same limit in its index so pruning survives
        // relaunches.
        let limit = settings.screenshotHistoryLimit
        guard screenshotHistoryStore.limit != limit else { return }
        screenshotHistoryStore.setLimit(limit)
    }

    @objc func showPreferences() {
        if embedded {
            onShowPreferences?()
            return
        }
        if preferencesWindowController == nil {
            let controller = PreferencesWindowController(
                appDisplayName: ScreenshotLabIdentity.displayName,
                allowsLaunchAtLogin: !embedded
            )
            controller.onHotKeysChanged = { [weak self] in
                self?.applyHotKeys() ?? false
            }
            controller.onOpenHistory = { [weak self] in
                self?.showScreenshotHistory()
            }
            controller.onError = { [weak self] error in
                self?.showError(error)
            }
            preferencesWindowController = controller
        }
        windowPresence.register(preferencesWindowController?.window)
        preferencesWindowController?.show()
    }

    @objc private func showScreenPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "屏幕录制权限"
        alert.informativeText = ScreenCaptureError.permissionDenied.localizedDescription
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        guard !embedded else { return }
        NSApp.terminate(nil)
    }

    func refreshSettingsAfterExternalUpdate() {
        configureScreenshotHistory()
        if !embedded {
            _ = applyHotKeys()
        }
    }

    @discardableResult
    func refreshHotKeys() -> Bool {
        guard !embedded else { return false }
        return applyHotKeys()
    }

    func summary(embedded: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "moduleID": ScreenshotLabModule.moduleID,
            "protocolMajor": ScreenshotLabModule.protocolMajor,
            "settingsSchemaVersion": ScreenshotLabModule.settingsSchemaVersion,
            "buildVersion": ScreenshotLabIdentity.buildVersion,
            "capabilities": ScreenshotLabModule.capabilities,
            "settingsRevision": settings.revision,
            "embedded": embedded,
            "started": isStarted,
            "screenPermissionAuthorized": CGPreflightScreenCaptureAccess(),
            "capturing": captureController.isCapturing,
            "pinCount": pinManager.count,
            "editorCount": editorControllers.count,
            "ocrWindowOpen": ocrWindowController?.window?.isVisible == true,
            "historyWindowOpen": screenshotHistoryWindowController?.window?.isVisible == true,
            "preferencesWindowOpen": preferencesWindowController?.window?.isVisible == true,
            "gifRecording": gifRecorder != nil,
            "gifStarting": gifRecordingStarting,
            "lastError": lastError ?? "",
            "hotKeysManagedByShell": embedded,
            "workWindowMenuAvailable": NSApp.mainMenu?.item(withTitle: "文件")?.submenu?.items.contains {
                $0.keyEquivalent == "w" && $0.action == #selector(NSWindow.performClose(_:))
            } == true,
            "captureHotKey": settings.captureHotKey.name,
            "gifHotKey": settings.gifHotKey.name,
            "settingsSuite": settings.suiteName ?? "standard",
        ]
        if !embedded {
            result["statusItemRegistered"] = statusItem != nil
        }
        return result
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        captureHotKeyManager?.unregister()
        gifHotKeyManager?.unregister()
        captureController.cancel()

        if let gifRecorder {
            gifRecorder.stop(
                saveTo: settings.quickSaveDirectory,
                save: false
            )
        }
        gifStartTask?.cancel()
        gifStartTask = nil
        gifRecorder = nil
        gifRecordingHUD?.hide()
        gifRecordingHUD = nil
        gifRecordingStarting = false

        pinManager.closeAll()
        ocrTask?.cancel()
        ocrTask = nil
        ocrWindowController?.window?.close()
        ocrWindowController = nil
        preferencesWindowController?.window?.close()
        preferencesWindowController = nil
        screenshotHistoryWindowController?.window?.close()
        screenshotHistoryWindowController = nil
        editorControllers.forEach { $0.window?.close() }
        editorControllers.removeAll()
        savedFileControllers.forEach { $0.window?.close() }
        savedFileControllers.removeAll()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func beginOpenImagePanel() {
        lastError = nil
        let panel = NSOpenPanel()
        panel.title = "打开图片"
        panel.prompt = "打开"
        panel.message = "选择 PNG、JPEG、TIFF、HEIC、GIF 或 BMP 图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [
            .png, .jpeg, .tiff, .heic, .gif, .bmp,
        ]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.openSelectedImage(at: url)
        }
    }

    private func openSelectedImage(at url: URL) {
        lastError = nil
        do {
            let image = try Self.loadBoundedImage(at: url)
            openEditor(with: image)
        } catch {
            showError(error)
        }
    }

    private static func loadBoundedImage(at url: URL) throws -> CGImage {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isReadableKey,
        ])
        guard values.isRegularFile == true, values.isReadable == true else {
            throw LocalImageOpenError.unreadable
        }
        guard let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 128 * 1_024 * 1_024 else {
            throw LocalImageOpenError.fileTooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw LocalImageOpenError.decodeFailed
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            throw LocalImageOpenError.unsupportedType
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw LocalImageOpenError.invalidDimensions
        }
        let width = rawWidth.intValue
        let height = rawHeight.intValue
        let maximumDimension = 16_384
        let maximumPixels = 64_000_000
        guard width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixels / height else {
            throw LocalImageOpenError.invalidDimensions
        }
        let options = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            options
        ) else {
            throw LocalImageOpenError.decodeFailed
        }
        return image
    }

    /// Screenshot history keeps the images the user chose to keep — the
    /// outputs of copy, save, quick save and pin. Demo and smoke-test entry
    /// points must never write into the user's real history.
    private func recordHistoryImage(_ image: CGImage) {
        guard !Self.isTestSession else { return }
        screenshotHistoryStore.add(image: image)
    }

    private static let historySuppressingArguments: Set<String> = [
        "--e2e", "--capture-probe", "--editor-interaction-test",
        "--pin-interaction-test", "--gif-motion-test", "--history-test",
        "--output-smoke", "--gif-smoke", "--test-instance", "--demo",
        "--demo-editor", "--demo-crop", "--demo-pin", "--demo-ocr",
        "--demo-saved-file", "--demo-gif-hud",
    ]

    private static var isTestSession: Bool {
        CommandLine.arguments.contains { historySuppressingArguments.contains($0) }
    }

    private func copyImage(_ image: CGImage, recordInHistory: Bool = true) {
        do {
            try ImageActions.copyToPasteboard(
                image,
                includeFile: settings.copyImageAsFile
            )
            if recordInHistory {
                recordHistoryImage(image)
            }
            showTemporaryMessage("已复制到剪贴板")
        } catch {
            showError(error)
        }
    }

    private func saveImage(_ image: CGImage, recordInHistory: Bool = true) {
        ImageActions.saveWithPanel(image) { [weak self] result in
            switch result {
            case .success(let url):
                if recordInHistory {
                    self?.recordHistoryImage(image)
                }
                self?.showSavedFile(url)
            case .failure(let error):
                self?.showError(error)
            }
        }
    }

    private func quickSaveImage(_ image: CGImage, recordInHistory: Bool = true) {
        do {
            let url = try ImageActions.quickSave(
                image,
                to: settings.quickSaveDirectory
            )
            if recordInHistory {
                recordHistoryImage(image)
            }
            showSavedFile(url)
        } catch {
            showError(error)
        }
    }

    private func startGIFRecording(region: GIFCaptureRegion) {
        guard gifRecorder == nil else {
            NSSound.beep()
            return
        }

        let recorder = GIFRecorder()
        let hud = GIFRecordingHUDController()
        gifRecorder = recorder
        gifRecordingHUD = hud
        gifRecordingStarting = true
        configureGIFMenu(recording: false, starting: true)
        statusItem?.button?.contentTintColor = .systemRed

        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return CGDirectDisplayID(number?.uint32Value ?? 0) == region.displayID
        } ?? ScreenCaptureService.screenAtMouse()

        hud.onStop = { [weak self] in
            self?.stopGIFRecording(save: true)
        }
        hud.onCancel = { [weak self] in
            self?.stopGIFRecording(save: false)
        }
        hud.update(elapsed: 0, frames: 0)

        recorder.onProgress = { [weak hud] elapsed, frames, capturedFrames in
            hud?.update(elapsed: elapsed, frames: frames, capturedFrames: capturedFrames)
        }
        recorder.onFinishing = { [weak hud] saving in
            hud?.showFinishing(saving: saving)
        }
        recorder.onFinish = { [weak self] result in
            self?.finishGIFRecording(result)
        }

        let startTask = Task { @MainActor [weak self] in
            do {
                try await recorder.start(region: region)
                guard let self, self.isStarted, !Task.isCancelled else {
                    recorder.stop(
                        saveTo: self?.settings.quickSaveDirectory
                            ?? FileManager.default.temporaryDirectory,
                        save: false
                    )
                    return
                }
                self.gifStartTask = nil
                self.gifRecordingStarting = false
                self.configureGIFMenu(recording: true, starting: false)
                hud.show(on: screen)
                self.showTemporaryMessage("GIF 录制中，点击菜单栏或 HUD 停止")
            } catch {
                guard let self, self.isStarted else {
                    hud.hide()
                    return
                }
                self.gifStartTask = nil
                self.gifRecordingStarting = false
                self.gifRecorder = nil
                self.gifRecordingHUD = nil
                hud.hide()
                self.configureGIFMenu(recording: false, starting: false)
                self.statusItem?.button?.contentTintColor = nil
                self.showError(error)
            }
        }
        gifStartTask = startTask
    }

    func stopGIFRecording(save: Bool) {
        guard !gifRecordingStarting else {
            showTemporaryMessage("GIF 录制正在启动")
            return
        }
        guard let gifRecorder else {
            return
        }
        gifRecorder.stop(
            saveTo: settings.quickSaveDirectory,
            save: save
        )
    }

    private func finishGIFRecording(_ result: Result<URL, Error>) {
        gifRecordingHUD?.hide()
        gifRecordingHUD = nil
        gifRecorder = nil
        gifStartTask = nil
        gifRecordingStarting = false
        configureGIFMenu(recording: false, starting: false)
        statusItem?.button?.contentTintColor = nil

        switch result {
        case .success(let url):
            showSavedFile(url)
        case .failure(let error):
            if error is CancellationError {
                showTemporaryMessage("已取消 GIF 录制")
            } else {
                showError(error)
            }
        }
    }

    private func configureGIFMenu(recording: Bool, starting: Bool) {
        if starting {
            gifMenuItem?.title = "正在启动 GIF 录制…"
            gifMenuItem?.action = #selector(gifStartInProgress)
        } else {
            gifMenuItem?.title = recording ? "停止并保存 GIF" : "录制 GIF…"
            gifMenuItem?.action = recording
                ? #selector(stopGIFRecordingAction)
                : #selector(beginGIFSelection)
        }
    }

    private func showSavedFile(_ url: URL) {
        settings.recentSavedFile = url
        recentSavedMenuItem?.isEnabled = true
        let controller = SavedFileWindowController(fileURL: url)
        windowPresence.register(controller.window)
        controller.show()
        savedFileControllers.append(controller)
        controller.window?.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        savedFileControllers.removeAll { $0.window === window }
    }

    @objc private func openRecentSavedFile() {
        guard let url = settings.recentSavedFile,
              FileManager.default.fileExists(atPath: url.path) else {
            recentSavedMenuItem?.isEnabled = false
            return
        }
        showSavedFile(url)
    }

    @objc private func gifStartInProgress() {
        showTemporaryMessage("GIF 录制正在启动")
    }

    private func performOCR(
        on image: CGImage,
        sourceFrame: CGRect? = nil,
        pinImage: Bool = false
    ) {
        var anchorFrame = sourceFrame
        if pinImage, let sourceFrame {
            // Keep the screenshot visible at the selected region; the OCR panel
            // opens next to it.
            anchorFrame = pinManager.add(image: image, anchor: sourceFrame)
                ?? sourceFrame
        }

        ocrTask?.cancel()
        ocrWindowController?.window?.close()
        let controller = OCRResultWindowController()
        ocrWindowController = controller
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.ocrWindowController === controller else { return }
            self.ocrTask?.cancel(); self.ocrTask = nil
        }
        windowPresence.register(controller.window)
        controller.showLoading(sourceFrame: anchorFrame)

        ocrTask = Task {
            do {
                let result = try await OCRService.recognize(image: image)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    controller.show(result: result)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    controller.show(error: error)
                }
            }
        }
    }

    private func openEditor(with image: CGImage) {
        let controller = EditorWindowController(image: image)
        controller.onAction = { [weak self, weak controller] action, editedImage in
            guard let self else {
                return
            }
            switch action {
            case .copy:
                self.copyImage(editedImage)
            case .save:
                self.saveImage(editedImage)
            case .quickSave:
                self.quickSaveImage(editedImage)
            case .pin:
                self.recordHistoryImage(editedImage)
                self.pinManager.add(image: editedImage)
            case .ocr:
                self.performOCR(
                    on: editedImage,
                    sourceFrame: controller?.window?.frame
                )
            }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.editorControllers.removeAll { $0 === controller }
        }
        editorControllers.append(controller)
        windowPresence.register(controller.window)
        controller.show()
    }

    private func showTemporaryMessage(
        _ message: String,
        duration: TimeInterval = 1.7
    ) {
        toastPresenter.show(message, duration: duration)
    }

    private func runOutputSmokeTest() {
        let directory = URL(
            fileURLWithPath: "/tmp/ScreenshotLabOutputSmoke",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let image = DebugFixtures.makeSampleImage(width: 800, height: 500)
            try ImageOutput.write(
                image,
                to: directory.appendingPathComponent("output.png")
            )
            try ImageOutput.write(
                image,
                to: directory.appendingPathComponent("output.jpg")
            )
            let smokePasteboard = NSPasteboard(
                name: NSPasteboard.Name("ScreenshotLabSmoke")
            )
            try ImageActions.copyToPasteboard(
                image,
                includeFile: true,
                pasteboard: smokePasteboard
            )
            let smokeTypes = smokePasteboard.types ?? []
            guard smokeTypes.contains(.fileURL),
                  smokeTypes.contains(.tiff) || smokeTypes.contains(.png) else {
                throw ImageOutputError.encodeFailed
            }
            let quickURL = try ImageActions.quickSave(
                image,
                to: directory.appendingPathComponent("quick", isDirectory: true)
            )
            print("OUTPUT_SMOKE_PASS \(quickURL.path)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            print("OUTPUT_SMOKE_FAIL \(error.localizedDescription)")
            fflush(stderr)
            exit(1)
        }
    }

    /// Unattended end-to-end check of the real capture pipeline. Writes a
    /// PASS/FAIL report to /tmp/screenshotlab-e2e.txt and exits.
    private func runEndToEndTest() {
        let reportURL = URL(fileURLWithPath: "/tmp/screenshotlab-e2e.txt")
        // Placement checks expect the dock-beside rule, not a parked panel.
        AppSettings.shared.ocrPanelOrigin = nil
        Task { @MainActor in
            var lines: [String] = []
            var failures = 0

            func writeReport() {
                let body = lines.joined(separator: "\n") + "\n"
                try? body.write(to: reportURL, atomically: true, encoding: .utf8)
            }

            func record(_ name: String, _ passed: Bool, _ detail: String = "") {
                let suffix = detail.isEmpty ? "" : " \(detail)"
                lines.append("\(passed ? "PASS" : "FAIL") \(name)\(suffix)")
                if !passed {
                    failures += 1
                }
                writeReport()
            }

            record("permission", CGPreflightScreenCaptureAccess())
            record("statusItem", statusItem?.button?.image != nil)
            record("menu", (statusItem?.menu?.items.count ?? 0) >= 10, "items=\(statusItem?.menu?.items.count ?? 0)")
            record("appIcon", NSApp.applicationIconImage != nil)
            let captureHotKeyOK = captureHotKeyManager?.register(
                settings.captureHotKey
            ) ?? false
            let gifHotKeyOK = gifHotKeyManager?.register(settings.gifHotKey) ?? false
            record(
                "hotkey",
                captureHotKeyOK && gifHotKeyOK,
                "\(settings.captureHotKey.name) / \(settings.gifHotKey.name)"
            )

            // Route a real kEventHotKeyPressed through the app's event handlers.
            Self.sendHotKeyEvent(identifier: 1)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            record("hotkey.capture", captureController.isCapturing)
            captureController.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)

            Self.sendHotKeyEvent(identifier: 2)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            record("hotkey.gif", captureController.isCapturing)
            captureController.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let workingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ScreenshotLabE2E-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )

            do {
                let snapshot = try await ScreenCaptureService.capture()
                // CGDisplayPixelsWide reports the logical mode size on HiDPI
                // (2560 for a 5K panel); the backing store is points * scale.
                let expectedWidth = Int(
                    (snapshot.screen.frame.width * snapshot.screen.backingScaleFactor).rounded()
                )
                let expectedHeight = Int(
                    (snapshot.screen.frame.height * snapshot.screen.backingScaleFactor).rounded()
                )
                record(
                    "capture.size",
                    snapshot.image.width == expectedWidth
                        && snapshot.image.height == expectedHeight,
                    "\(snapshot.image.width)x\(snapshot.image.height) expected \(expectedWidth)x\(expectedHeight)"
                )
                record("capture.scale", snapshot.scale >= 1.99, "scale=\(snapshot.scale)")

                let selection = CGRect(x: 120, y: 160, width: 280, height: 180)
                if let cropped = ImageCropper.crop(
                    snapshot: snapshot,
                    localSelection: selection
                ) {
                    let expectedCropWidth = Int((selection.width * snapshot.scale).rounded())
                    let expectedCropHeight = Int((selection.height * snapshot.scale).rounded())
                    record(
                        "crop.size",
                        abs(cropped.width - expectedCropWidth) <= 2
                            && abs(cropped.height - expectedCropHeight) <= 2,
                        "\(cropped.width)x\(cropped.height) expected \(expectedCropWidth)x\(expectedCropHeight)"
                    )
                    runImageOutputChecks(
                        image: cropped,
                        directory: workingDirectory,
                        record: record
                    )
                    runClipboardChecks(image: cropped, record: record)
                } else {
                    record("crop.size", false, "nil")
                }
            } catch {
                record("capture", false, error.localizedDescription)
            }

            do {
                let recognized = try await OCRService.recognize(
                    image: DebugFixtures.makeSampleImage()
                )
                let requiredText = [
                    "ScreenshotLab",
                    "中文文字识别测试",
                    "Clipboard: Hello, 2026!",
                ]
                let missing = requiredText.filter { !recognized.content.contains($0) }
                record(
                    "ocr.text",
                    missing.isEmpty,
                    "lines=\(recognized.lineCount) chars=\(recognized.characterCount) "
                        + "ms=\(Int(recognized.elapsedMilliseconds.rounded())) missing=\(missing)"
                )
            } catch {
                record("ocr.text", false, error.localizedDescription)
            }

            performOCR(on: DebugFixtures.makeSampleImage())
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            record("ocr.window", ocrWindowController?.window != nil)
            ocrWindowController?.window?.close()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let pinImage = DebugFixtures.makeSampleImage()
            pinManager.add(image: pinImage)
            pinManager.add(image: pinImage)
            try? await Task.sleep(nanoseconds: 400_000_000)
            record("pin.add", pinManager.count == 2, "count=\(pinManager.count)")

            if let pinWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "ScreenshotLabPin" && $0.isVisible
            }) {
                let pixelScale = max(
                    1,
                    ScreenCaptureService.screenAtMouse().backingScaleFactor
                )
                let expectedWidth = CGFloat(pinImage.width) / pixelScale
                let expectedHeight = CGFloat(pinImage.height) / pixelScale
                record(
                    "pin.size",
                    abs(pinWindow.frame.width - expectedWidth) <= 2
                        && abs(pinWindow.frame.height - expectedHeight) <= 2,
                    "\(Int(pinWindow.frame.width))x\(Int(pinWindow.frame.height)) expected \(Int(expectedWidth))x\(Int(expectedHeight))"
                )

                if let controller = pinWindow.delegate as? PinWindowController {
                    let before = pinWindow.frame.width
                    let center = CGPoint(
                        x: pinWindow.frame.width / 2,
                        y: pinWindow.frame.height / 2
                    )
                    controller.zoom(by: 1.25, anchorInWindow: center)
                    let zoomed = pinWindow.frame.width
                    record(
                        "pin.zoom",
                        abs(zoomed - before * 1.25) <= 2,
                        "\(Int(before)) -> \(Int(zoomed))"
                    )
                    controller.zoom(by: 0.8, anchorInWindow: center)
                } else {
                    record("pin.zoom", false, "delegate missing")
                }
            } else {
                record("pin.size", false, "window missing")
            }

            let anchor = CGRect(x: 240, y: 620, width: 300, height: 200)
            pinManager.add(
                image: DebugFixtures.makeSampleImage(width: 600, height: 400),
                anchor: anchor
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
            let anchoredPin = NSApp.windows.first {
                $0.identifier?.rawValue == "ScreenshotLabPin" && $0.isVisible
                    && Self.rectsApproximatelyEqual($0.frame, anchor)
            }
            record(
                "pin.anchor",
                anchoredPin != nil,
                anchoredPin.map { "\($0.frame)" } ?? "window not at anchor"
            )

            pinManager.closeAll()
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("pin.close", pinManager.count == 0, "count=\(pinManager.count)")

            // OCR keeps the screenshot at the selection and opens the text
            // panel immediately to its right.
            let ocrSource = CGRect(x: 240, y: 620, width: 300, height: 200)
            performOCR(
                on: DebugFixtures.makeSampleImage(width: 600, height: 400),
                sourceFrame: ocrSource,
                pinImage: true
            )
            try? await Task.sleep(nanoseconds: 600_000_000)
            let ocrSourcePin = NSApp.windows.first {
                $0.identifier?.rawValue == "ScreenshotLabPin" && $0.isVisible
            }
            record(
                "pin.ocrSource",
                ocrSourcePin.map {
                    Self.rectsApproximatelyEqual($0.frame, ocrSource)
                } ?? false,
                ocrSourcePin.map { "\($0.frame)" } ?? "no pin"
            )
            if let ocrWindow = ocrWindowController?.window {
                record(
                    "ocr.besideImage",
                    abs(ocrWindow.frame.minX - (ocrSource.maxX + 14)) <= 2
                        && abs(ocrWindow.frame.maxY - ocrSource.maxY) <= 2,
                    "\(ocrWindow.frame)"
                )
            } else {
                record("ocr.besideImage", false, "no OCR window")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            ocrWindowController?.window?.close()
            pinManager.closeAll()
            try? await Task.sleep(nanoseconds: 300_000_000)

            openEditor(with: DebugFixtures.makeSampleImage())
            try? await Task.sleep(nanoseconds: 700_000_000)
            record("editor.window", editorControllers.count == 1)
            editorControllers.forEach { $0.window?.close() }
            try? await Task.sleep(nanoseconds: 400_000_000)
            record("editor.close", editorControllers.isEmpty)

            // Closing the overlay used to over-release the ARC-owned window.
            captureController.beginDemoCapture()
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("overlay.present", captureController.isCapturing)
            captureController.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("overlay.close", !captureController.isCapturing)

            // Delayed capture exercises the timer path and a real snapshot.
            captureController.beginDelayedCapture(seconds: 0.4)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            record("capture.delayed", captureController.isCapturing)
            var copiedSelection: CGRect?
            if let overlay = NSApp.windows
                .compactMap({ $0 as? CaptureOverlayWindow })
                .first(where: { $0.isVisible }) {
                runOverlayInteractionChecks(overlay: overlay, record: record)
                copiedSelection = overlay.overlayView.currentSelection
                // Primary flow: select a region and press Return to copy it.
                if let keyDown = Self.returnKeyEvent(windowNumber: overlay.windowNumber) {
                    overlay.overlayView.keyDown(with: keyDown)
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                record("capture.copy", !captureController.isCapturing)
                checkClipboardSize(for: copiedSelection ?? .zero, record: record)
            } else {
                record("overlay.interaction", false, "window missing")
            }
            captureController.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)

            if let copiedSelection {
                captureController.beginCapture(usingLastSelection: true)
                var lastAreaOverlay: CaptureOverlayWindow?
                for _ in 0..<30 {
                    if let overlay = NSApp.windows
                        .compactMap({ $0 as? CaptureOverlayWindow })
                        .first(where: { $0.isVisible }) {
                        lastAreaOverlay = overlay
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let lastAreaOverlay {
                    let selection = lastAreaOverlay.overlayView.currentSelection
                    let overlayFrame = lastAreaOverlay.frame
                    record(
                        "capture.lastArea",
                        Self.rectsApproximatelyEqual(
                            selection,
                            copiedSelection
                        ),
                        "\(selection)"
                    )
                    // Pin from the overlay must land on the selected region.
                    if let keyDown = Self.keyEvent(
                        characters: "p",
                        keyCode: 35,
                        windowNumber: lastAreaOverlay.windowNumber
                    ) {
                        lastAreaOverlay.overlayView.keyDown(with: keyDown)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    let expectedPinFrame = selection.offsetBy(
                        dx: overlayFrame.minX,
                        dy: overlayFrame.minY
                    )
                    let pinWindow = NSApp.windows.first {
                        $0.identifier?.rawValue == "ScreenshotLabPin" && $0.isVisible
                    }
                    record(
                        "pin.fromCapture",
                        pinWindow.map {
                            Self.rectsApproximatelyEqual(
                                $0.frame,
                                expectedPinFrame
                            )
                        } ?? false,
                        pinWindow.map { "\($0.frame)" } ?? "no pin"
                    )
                    captureController.cancel()
                    pinManager.closeAll()
                } else {
                    record("capture.lastArea", false, "no overlay")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)

                captureController.beginCapture(usingLastSelection: true)
                var ocrOverlay: CaptureOverlayWindow?
                for _ in 0..<30 {
                    if let overlay = NSApp.windows
                        .compactMap({ $0 as? CaptureOverlayWindow })
                        .first(where: { $0.isVisible }) {
                        ocrOverlay = overlay
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let ocrOverlay {
                    let selection = ocrOverlay.overlayView.currentSelection
                    let overlayFrame = ocrOverlay.frame
                    if let keyDown = Self.keyEvent(
                        characters: "o",
                        keyCode: 31,
                        windowNumber: ocrOverlay.windowNumber
                    ) {
                        ocrOverlay.overlayView.keyDown(with: keyDown)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let expected = selection.offsetBy(
                        dx: overlayFrame.minX,
                        dy: overlayFrame.minY
                    )
                    let pinWindow = NSApp.windows.first {
                        $0.identifier?.rawValue == "ScreenshotLabPin"
                            && $0.isVisible
                    }
                    record(
                        "pin.fromOCRCapture",
                        pinWindow.map {
                            Self.rectsApproximatelyEqual($0.frame, expected)
                        } ?? false,
                        pinWindow.map { "\($0.frame)" } ?? "no pin"
                    )
                    if let ocrWindow = ocrWindowController?.window,
                       ocrWindow.isVisible {
                        record(
                            "ocr.fromCapture",
                            abs(ocrWindow.frame.minX - (expected.maxX + 14)) <= 2
                                && abs(ocrWindow.frame.maxY - expected.maxY) <= 2,
                            "\(ocrWindow.frame)"
                        )
                    } else {
                        record("ocr.fromCapture", false, "no OCR window")
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    ocrWindowController?.window?.close()
                    pinManager.closeAll()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    record("ocr.fromCapture", false, "no overlay")
                }
            }

            do {
                let windowImage = try await captureTestWindow()
                record(
                    "capture.window",
                    windowImage.width >= 600,
                    "\(windowImage.width)x\(windowImage.height)"
                )
            } catch {
                record("capture.window", false, error.localizedDescription)
            }

            switch await recordGIF(directory: workingDirectory) {
            case .success(let url):
                record(
                    "gif.captureCallbacks",
                    e2eGIFCaptureCallbacks > 0,
                    "callbacks=\(e2eGIFCaptureCallbacks)"
                )
                record(
                    "gif.file",
                    FileManager.default.fileExists(atPath: url.path),
                    url.lastPathComponent
                )
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let frameCount = CGImageSourceGetCount(source)
                    record("gif.frames", frameCount > 1, "frames=\(frameCount)")
                    record(
                        "gif.distinctFrames",
                        Self.distinctFrameCount(source) > 1,
                        "distinct=\(Self.distinctFrameCount(source))"
                    )
                    let properties = CGImageSourceCopyPropertiesAtIndex(
                        source,
                        0,
                        nil
                    ) as? [CFString: Any]
                    let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
                    record("gif.width", pixelWidth == 960, "width=\(pixelWidth ?? 0)")
                } else {
                    record("gif.frames", false, "unreadable")
                }
            case .failure(let error):
                record("gif.record", false, error.localizedDescription)
            }

            showPreferences()
            try? await Task.sleep(nanoseconds: 500_000_000)
            record("preferences.window", preferencesWindowController?.window != nil)
            runHotKeyRecorderCheck(record: record)
            preferencesWindowController?.window?.close()

            toastPresenter.show("E2E", duration: 0.2)
            try? await Task.sleep(nanoseconds: 400_000_000)

            record("summary", failures == 0, "failures=\(failures)")
            lines.append(failures == 0 ? "E2E_PASS" : "E2E_FAIL")
            writeReport()
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func runImageOutputChecks(
        image: CGImage,
        directory: URL,
        record: (String, Bool, String) -> Void
    ) {
        let pngURL = directory.appendingPathComponent("crop.png")
        let jpegURL = directory.appendingPathComponent("crop.jpg")
        do {
            try ImageOutput.writePNG(image, to: pngURL)
            try ImageOutput.write(image, to: jpegURL)
            let expected = CGSize(width: image.width, height: image.height)
            let pngSize = Self.readImageSize(pngURL)
            let jpegSize = Self.readImageSize(jpegURL)
            record("output.png", pngSize == expected, "\(pngSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unreadable")")
            record("output.jpeg", jpegSize == expected, "\(jpegSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unreadable")")
        } catch {
            record("output", false, error.localizedDescription)
        }

        do {
            let savedURL = try ImageActions.quickSave(image, to: directory)
            record(
                "quickSave",
                FileManager.default.fileExists(atPath: savedURL.path),
                savedURL.lastPathComponent
            )
        } catch {
            record("quickSave", false, error.localizedDescription)
        }
    }

    private func runClipboardChecks(
        image: CGImage,
        record: (String, Bool, String) -> Void
    ) {
        do {
            try ImageActions.copyToPasteboard(image, includeFile: true)
            let pasteboard = NSPasteboard.general
            let types = pasteboard.types ?? []
            record(
                "clipboard.image",
                types.contains(.tiff) || types.contains(.png),
                "types=\(types.count)"
            )
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            if let url = urls?.first, let size = Self.readImageSize(url) {
                record(
                    "clipboard.file",
                    size == CGSize(width: image.width, height: image.height),
                    "\(Int(size.width))x\(Int(size.height))"
                )
            } else {
                record("clipboard.file", false, "no file URL")
            }
        } catch {
            record("clipboard", false, error.localizedDescription)
        }
    }

    private static func readImageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return CGSize(width: image.width, height: image.height)
    }

    private static func distinctFrameCount(_ source: CGImageSource) -> Int {
        var signatures = Set<Data>()
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let context = CGContext(
                    data: nil,
                    width: 32,
                    height: 32,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { continue }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            if let data = context.data {
                signatures.insert(Data(bytes: data, count: 32 * 32 * 4))
            }
        }
        return signatures.count
    }

    private static func rectsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func keyEvent(
        characters: String,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private static func returnKeyEvent(windowNumber: Int) -> NSEvent? {
        keyEvent(characters: "\r", keyCode: 36, windowNumber: windowNumber)
    }

    private func checkClipboardSize(
        for selection: CGRect,
        record: (String, Bool, String) -> Void
    ) {
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
              let url = urls.first,
              let size = Self.readImageSize(url) else {
            record("capture.copy.size", false, "no clipboard file")
            return
        }
        let scale = ScreenCaptureService.screenAtMouse().backingScaleFactor
        let expectedWidth = (selection.width * scale).rounded()
        let expectedHeight = (selection.height * scale).rounded()
        record(
            "capture.copy.size",
            abs(size.width - expectedWidth) <= 2
                && abs(size.height - expectedHeight) <= 2,
            "\(Int(size.width))x\(Int(size.height)) expected \(Int(expectedWidth))x\(Int(expectedHeight))"
        )
    }

    private static func sendHotKeyEvent(identifier: UInt32) {
        var event: EventRef?
        let created = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            OSType(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone),
            &event
        )
        guard created == noErr, let event else {
            return
        }
        var hotKeyID = EventHotKeyID(
            signature: HotKeyManager.signature,
            id: identifier
        )
        SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &hotKeyID
        )
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
    }

    private static func findView(
        withIdentifier identifier: String,
        in view: NSView
    ) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findView(withIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private func runHotKeyRecorderCheck(
        record: (String, Bool, String) -> Void
    ) {
        guard let window = preferencesWindowController?.window,
              let contentView = window.contentView,
              let recorder = Self.findView(
                withIdentifier: "ScreenshotLabCaptureHotKey",
                in: contentView
              ) as? HotKeyRecorderButton else {
            record("hotkey.record", false, "recorder missing")
            return
        }

        let original = settings.captureHotKey
        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let mouseDown {
            recorder.mouseDown(with: mouseDown)
        }

        let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "j",
            charactersIgnoringModifiers: "j",
            isARepeat: false,
            keyCode: 38
        )
        if let keyDown {
            recorder.keyDown(with: keyDown)
        }

        let recorded = settings.captureHotKey
        let expectedModifiers = HotKeyChoice.carbonModifiers(
            from: [.command, .shift]
        )
        record(
            "hotkey.record",
            recorded.keyCode == 38
                && recorded.modifiers == expectedModifiers,
            recorded.name
        )

        settings.captureHotKey = original
        _ = applyHotKeys()
    }

    /// Drives the overlay with synthetic mouse events: create, move and resize.
    @MainActor
    private func runOverlayInteractionChecks(
        overlay: CaptureOverlayWindow,
        record: (String, Bool, String) -> Void
    ) {
        let view = overlay.overlayView
        let bounds = view.bounds

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        func drag(from start: CGPoint, to end: CGPoint) {
            event(.leftMouseDown, at: start).map(view.mouseDown(with:))
            event(.leftMouseDragged, at: end).map(view.mouseDragged(with:))
            event(.leftMouseUp, at: end).map(view.mouseUp(with:))
        }

        let start = CGPoint(
            x: (bounds.width * 0.30).rounded(),
            y: (bounds.height * 0.30).rounded()
        )
        let end = CGPoint(
            x: (bounds.width * 0.45).rounded(),
            y: (bounds.height * 0.45).rounded()
        )
        drag(from: start, to: end)
        let created = CGRect(
            x: start.x,
            y: start.y,
            width: end.x - start.x,
            height: end.y - start.y
        )
        record(
            "overlay.create",
            Self.rectsApproximatelyEqual(view.currentSelection, created),
            "\(view.currentSelection)"
        )

        let dx = (bounds.width * 0.02).rounded()
        let dy = (bounds.height * 0.02).rounded()
        let center = CGPoint(x: created.midX, y: created.midY)
        drag(from: center, to: CGPoint(x: center.x + dx, y: center.y + dy))
        let moved = created.offsetBy(dx: dx, dy: dy)
        record(
            "overlay.move",
            Self.rectsApproximatelyEqual(view.currentSelection, moved),
            "\(view.currentSelection)"
        )

        let corner = CGPoint(x: moved.maxX, y: moved.minY)
        drag(from: corner, to: CGPoint(x: corner.x + dx, y: corner.y - dy))
        let resized = CGRect(
            x: moved.minX,
            y: moved.minY - dy,
            width: moved.width + dx,
            height: moved.height + dy
        )
        record(
            "overlay.resize",
            Self.rectsApproximatelyEqual(view.currentSelection, resized),
            "\(view.currentSelection)"
        )
    }

    @MainActor
    private func captureTestWindow() async throws -> CGImage {
        let window = NSWindow(
            contentRect: CGRect(x: 240, y: 240, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "ScreenshotLab E2E"
        window.backgroundColor = .systemRed
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(nanoseconds: 500_000_000)
        defer { window.close() }
        return try await ScreenCaptureService.captureWindow(ownerPID: getpid())
    }

    private func recordGIF(directory: URL) async -> Result<URL, Error> {
        let recorder = GIFRecorder()
        var result: Result<URL, Error>?
        e2eGIFCaptureCallbacks = 0
        recorder.onProgress = { [weak self] _, _, captured in
            self?.e2eGIFCaptureCallbacks = captured
        }
        recorder.onFinish = { result = $0 }

        let screen = ScreenCaptureService.screenAtMouse()
        let displayNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        // Wider than the 960 px output cap, to exercise downscaling.
        let regionWidth = max(640, min(1200, screen.frame.width - 240))
        let region = GIFCaptureRegion(
            displayID: CGDirectDisplayID(
                displayNumber?.uint32Value ?? CGMainDisplayID()
            ),
            screenFrame: screen.frame,
            selection: CGRect(x: 120, y: 160, width: regionWidth, height: 200)
        )

        do {
            try await recorder.start(region: region)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            recorder.stop(saveTo: directory, save: true)
        } catch {
            return .failure(error)
        }

        for _ in 0..<40 {
            if let result {
                return result
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .failure(GIFRecorderError.frameConversionFailed)
    }

    /// Captures the current screen without showing the overlay and reports the
    /// pixel size. Used to verify Retina resolution end to end.
    private func runCaptureProbe() {
        let reportURL = URL(fileURLWithPath: "/tmp/screenshotlab-capture-probe.txt")
        Task { @MainActor in
            do {
                let snapshot = try await ScreenCaptureService.capture()
                try ImageOutput.writePNG(
                    snapshot.image,
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-capture-probe.png")
                )
                let report = "CAPTURE_PROBE_OK width=\(snapshot.image.width) "
                    + "height=\(snapshot.image.height) scale=\(snapshot.scale) "
                    + "displayID=\(snapshot.displayID)\n"
                try report.write(to: reportURL, atomically: true, encoding: .utf8)
            } catch {
                try? "CAPTURE_PROBE_FAIL \(error.localizedDescription)\n"
                    .write(to: reportURL, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    private func runGIFSmokeTest() {
        let outputURL = URL(fileURLWithPath: "/tmp/ScreenshotLabGifSmoke.gif")
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let encoder = try GIFEncoder(url: outputURL, framesPerSecond: 5)
            let image = DebugFixtures.makeSampleImage(width: 640, height: 360)
            for _ in 0..<4 {
                try encoder.addFrame(image)
            }
            _ = try encoder.finalize()

            guard let source = CGImageSourceCreateWithURL(
                outputURL as CFURL,
                nil
            ) else {
                throw GIFEncoderError.encodeFailed
            }
            let frameCount = CGImageSourceGetCount(source)
            guard frameCount == 4 else {
                throw GIFEncoderError.encodeFailed
            }
            print("GIF_SMOKE_PASS frames=\(frameCount)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            print("GIF_SMOKE_FAIL \(error.localizedDescription)")
            fflush(stderr)
            exit(1)
        }
    }

    private func showError(_ error: Error) {
        lastError = error.localizedDescription
        if let captureError = error as? ScreenCaptureError,
           case .permissionDenied = captureError {
            showTemporaryMessage(
                "需要屏幕录制权限，请从菜单打开权限引导",
                duration: 4
            )
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

}
