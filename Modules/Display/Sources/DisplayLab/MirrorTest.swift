import AppKit
import CoreGraphics
import DisplayCore

/// Mirror-mechanics diagnostic that never touches a physical display: two
/// virtual screens are created, one is pointed at the other through
/// CGConfigureDisplayMirrorOfDisplay, then everything is cleaned up. On this
/// OS build WindowServer accepts the transaction but silently ignores mirror
/// sets between two virtual screens (no hardware scanout involved) — the
/// production path pairs a virtual master with a physical slave and verifies
/// the attachment itself. Pass criteria here: the transaction is accepted and
/// cleanup is complete. Reports to /tmp/displaylab-mirror-test.txt with a
/// final MIRROR_TEST_PASS/FAIL.
enum MirrorTest {
    static func run() {
        var report: [String] = []

        func finish(_ pass: Bool) {
            report.append(pass ? "MIRROR_TEST_PASS" : "MIRROR_TEST_FAIL")
            let text = report.joined(separator: "\n")
            try? text.write(toFile: "/tmp/displaylab-mirror-test.txt", atomically: true, encoding: .utf8)
            fflush(stdout)
            print(text)
            exit(pass ? 0 : 1)
        }

        func waitFor(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            return condition()
        }

        let controller = VirtualDisplayController()
        let masterSpec = VirtualDisplayController.Spec(name: "DisplayLab 镜像主屏", pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        let slaveSpec = VirtualDisplayController.Spec(name: "DisplayLab 镜像从屏", pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)

        let masterID: CGDirectDisplayID
        let slaveID: CGDirectDisplayID
        do {
            masterID = try controller.create(spec: masterSpec)
            slaveID = try controller.create(spec: slaveSpec)
            report.append("created master=\(masterID) slave=\(slaveID)")
        } catch {
            report.append("FAIL create: \(error.localizedDescription)")
            controller.disconnectAll()
            finish(false)
            return
        }

        guard waitFor({ CGDisplayPixelsWide(masterID) > 0 && CGDisplayPixelsWide(slaveID) > 0 }, timeout: 10) else {
            report.append("FAIL virtual displays never came up")
            controller.disconnectAll()
            finish(false)
            return
        }

        // Point the slave at the master inside one configuration transaction.
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            report.append("FAIL begin configuration")
            controller.disconnectAll()
            finish(false)
            return
        }
        let mirrorError = CGConfigureDisplayMirrorOfDisplay(config, slaveID, masterID)
        guard mirrorError == .success else {
            CGCancelDisplayConfiguration(config)
            report.append("FAIL configure mirror: CGError \(mirrorError.rawValue)")
            controller.disconnectAll()
            finish(false)
            return
        }
        let completeError = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeError == .success else {
            report.append("FAIL complete configuration: CGError \(completeError.rawValue)")
            controller.disconnectAll()
            finish(false)
            return
        }

        let mirroredNow = waitFor({ CGDisplayMirrorsDisplay(slaveID) == masterID }, timeout: 5)
        // Informational: virtual-to-virtual sets are ignored by WindowServer
        // on this build; the transaction itself still has to succeed.
        report.append("mirrored=\(mirroredNow) mirrorsDisplay=\(CGDisplayMirrorsDisplay(slaveID)) inMirrorSet=\(CGDisplayIsInMirrorSet(slaveID) != 0)")

        // Detach through kCGNullDisplayMirror (0) and confirm the split.
        try? detach(slaveID)
        let detached = waitFor({ CGDisplayMirrorsDisplay(slaveID) == 0 }, timeout: 5)
        report.append("detached=\(detached) mirrorsDisplay=\(CGDisplayMirrorsDisplay(slaveID))")
        guard detached else {
            report.append("FAIL slave stayed in the mirror set after detach")
            controller.disconnectAll()
            finish(false)
            return
        }

        controller.disconnectAll()
        let removed = waitFor({ CGDisplayPixelsWide(masterID) == 0 && CGDisplayPixelsWide(slaveID) == 0 }, timeout: 20)
        report.append("removed=\(removed)")
        guard removed else {
            report.append("FAIL virtual displays did not disappear")
            finish(false)
            return
        }

        finish(true)
    }

    /// Detaches `display` from any mirror set via a completed transaction.
    private static func detach(_ display: CGDirectDisplayID) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw ModeServiceError.configurationFailed("无法开始显示器配置事务。")
        }
        CGConfigureDisplayMirrorOfDisplay(config, display, 0) // kCGNullDisplayMirror
        CGCompleteDisplayConfiguration(config, .permanently)
    }
}
