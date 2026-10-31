import AppKit

/// An accessory menu bar app has no Dock or application-switcher entry, so
/// regular windows would be hard to recover once closed to the background.
/// This controller registers every document-style window and flips the app
/// between .accessory and .regular accordingly.
final class WindowPresenceController {
    private var windows = NSHashTable<NSWindow>.weakObjects()
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private var regularWhenOpen: Bool {
        windows.anyObject != nil
    }

    func register(_ window: NSWindow?) {
        guard let window, window is NSPanel == false else { return }
        let key = ObjectIdentifier(window)
        guard closeObservers[key] == nil else { return }

        windows.add(window)
        window.isExcludedFromWindowsMenu = false
        NSApp.addWindowsItem(window, title: window.title, filename: false)

        if regularWhenOpen, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.unregister(window)
        }
    }

    func unregister(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows.remove(window)
        NSApp.removeWindowsItem(window)

        if !regularWhenOpen, NSApp.activationPolicy() != .accessory {
            DispatchQueue.main.async {
                if !self.regularWhenOpen {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func bringForward() {
        for window in windows.allObjects.reversed() {
            window.deminiaturize(nil)
        }
        windows.allObjects.first?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
