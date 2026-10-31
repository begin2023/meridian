import AppKit

// Pin/HUD panels stay unobtrusive; document-style windows participate in the
// Dock, app switcher and Window menu until their last window is closed.
final class WindowPresenceController: NSObject {
    private let windows = NSHashTable<NSWindow>.weakObjects()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var hasWindows: Bool { !windows.allObjects.isEmpty }

    func register(_ window: NSWindow?) {
        guard let window, !(window is NSPanel) else { return }
        windows.add(window)
        window.isExcludedFromWindowsMenu = false
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.addWindowsItem(window, title: window.title, filename: false)
    }

    func bringForward() {
        let ordered = NSApp.orderedWindows.filter { windows.contains($0) }
        let candidates = ordered + windows.allObjects.filter { !ordered.contains($0) }
        for window in candidates.reversed() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        candidates.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, windows.contains(window) else { return }
        windows.remove(window)
        NSApp.removeWindowsItem(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasWindows else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
