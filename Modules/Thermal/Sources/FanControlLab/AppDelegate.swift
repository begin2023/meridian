import AppKit

/// Owns the local SMC read session and AppKit surfaces.
///
/// Fan writes are deliberately not wired into this delegate. The former
/// `ControlService` path could create or refresh `desired.json`, which an
/// already-installed root daemon would execute. The integrated build is
/// monitoring-only until the safety and recovery gates are verified.
@MainActor
final class AppDelegate: NSObject {
    private let embedded: Bool
    private var monitorService: MonitorService?
    private var menuBarController: MenuBarController?
    private var preferencesController: PreferencesWindowController?
    private var sensorWindowController: SensorWindowController?
    private var client: SMCClient?
    private var started = false

    private(set) var database: SensorDatabase?
    private(set) var latestUpdate: MonitorUpdate?
    private(set) var startupError: String?

    var onShowPreferences: (() -> Void)?

    var isEmbedded: Bool { embedded }

    init(embedded: Bool) {
        self.embedded = embedded
        super.init()
    }

    func start() {
        guard !started else { return }
        startupError = nil

        if !embedded {
            let menuBar = MenuBarController()
            menuBar.openPreferencesHandler = { [weak self] in
                self?.showPreferences()
            }
            menuBar.openMainWindowHandler = { [weak self] in
                self?.showSensorWindow()
            }
            menuBarController = menuBar
        }

        let client = SMCClient()
        do {
            try client.open()
        } catch {
            startupError = error.localizedDescription
            if !embedded {
                presentStartupError(error)
            }
            return
        }
        self.client = client

        let database = SensorDatabase.load()
        self.database = database

        let monitor = MonitorService(client: client, database: database)
        monitor.onUpdate = { [weak self] update in
            guard let self else { return }
            self.latestUpdate = update
            self.menuBarController?.apply(update)
            self.sensorWindowController?.update(update: update, startupError: self.startupError)
        }
        monitorService = monitor

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .fanControlSettingsChanged,
            object: nil
        )

        started = true
        monitor.start()
    }

    func stop() {
        guard started || client != nil || menuBarController != nil
                || preferencesController != nil || sensorWindowController != nil else {
            return
        }
        NotificationCenter.default.removeObserver(
            self,
            name: .fanControlSettingsChanged,
            object: nil
        )
        monitorService?.stop()
        monitorService = nil
        client?.close()
        client = nil
        menuBarController?.remove()
        menuBarController = nil
        sensorWindowController?.close()
        sensorWindowController = nil
        preferencesController?.close()
        preferencesController = nil
        latestUpdate = nil
        started = false
    }

    func showPreferences() {
        if embedded {
            onShowPreferences?()
            return
        }
        if preferencesController == nil {
            // This development-only window changes monitor preferences. It
            // intentionally has no fan-write action.
            preferencesController = PreferencesWindowController(readOnly: true)
        }
        preferencesController?.showWindow()
    }

    func bringWindowsForward() {
        showSensorWindow()
    }

    func showSensorWindow() {
        if sensorWindowController == nil {
            sensorWindowController = SensorWindowController()
        }
        sensorWindowController?.update(
            update: latestUpdate,
            startupError: startupError
        )
        sensorWindowController?.present()
    }

    func refreshNow() {
        monitorService?.refreshNow()
    }

    @objc private func settingsChanged() {
        guard started else { return }
        monitorService?.stop()
        monitorService?.start()
        if let update = latestUpdate {
            menuBarController?.apply(update)
            sensorWindowController?.update(update: update, startupError: startupError)
        }
    }

    var isSensorWindowVisible: Bool {
        sensorWindowController?.isVisible == true
    }

    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法连接 SMC"
        alert.informativeText = """
        \(error.localizedDescription)

        FanControlLab 将继续以只读模式运行，不会安装助手或写入风扇控制。
        """
        alert.addButton(withTitle: "继续")
        alert.runModal()
    }
}
