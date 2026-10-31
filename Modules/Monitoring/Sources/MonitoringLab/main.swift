import AppKit

if !CommandLine.arguments.contains("--test-instance"),
   let bundleIdentifier = Bundle.main.bundleIdentifier {
    let existingInstance = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first { $0.processIdentifier != getpid() }
    if let existingInstance {
        existingInstance.activate()
        exit(EXIT_SUCCESS)
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
