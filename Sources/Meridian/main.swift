import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppCoordinator.shared
    app.run()
}
