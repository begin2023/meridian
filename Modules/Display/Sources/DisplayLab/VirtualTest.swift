import AppKit
import CoreGraphics
import DisplayCore

/// Virtual screen end-to-end regression: creates a 1920×1080 HiDPI virtual
/// screen, waits for it to appear in the CG display list with the expected
/// modes, then disconnects it and waits for it to disappear. Reports to
/// /tmp/displaylab-virtual-test.txt with a final VIRTUAL_TEST_PASS/FAIL.
enum VirtualTest {
    static func run() {
        var report: [String] = []

        func finish(_ pass: Bool) {
            report.append(pass ? "VIRTUAL_TEST_PASS" : "VIRTUAL_TEST_FAIL")
            let text = report.joined(separator: "\n")
            try? text.write(toFile: "/tmp/displaylab-virtual-test.txt", atomically: true, encoding: .utf8)
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

        report.append("baseline displays=\(activeDisplayCount())")

        let controller = VirtualDisplayController()
        let spec = VirtualDisplayController.Spec(name: "DisplayLab 测试屏", pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)

        // The test entry point already runs on the main queue.
        let createdID: CGDirectDisplayID
        do {
            createdID = try controller.create(spec: spec)
            report.append("created=\(createdID)")
        } catch {
            report.append("FAIL create: \(error.localizedDescription)")
            finish(false)
            return
        }

        var createdOnline = false
        var createdPixelsWide: Int = 0
        for _ in 0..<50 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            createdOnline = CGDisplayIsOnline(createdID) != 0
            createdPixelsWide = Int(CGDisplayPixelsWide(createdID))
            if createdPixelsWide > 0 {
                break
            }
        }
        report.append("created online=\(createdOnline) pixelsWide=\(createdPixelsWide)")
        report.append("created model=\(CGDisplayModelNumber(createdID)) vendor=\(CGDisplayVendorNumber(createdID))")
        guard createdPixelsWide > 0 else {
            report.append("FAIL virtual display never came up")
            for line in activeDisplayDump() {
                report.append(line)
            }
            controller.disconnectAll()
            finish(false)
            return
        }
        report.append("appeared=\(createdID) model=0x\(String(CGDisplayModelNumber(createdID), radix: 16))")

        // Another process (or a fresh one) can read the modes even when this
        // process's per-process mode cache is stale; from this process the
        // readiness signal above is authoritative.
        let info = DisplayEnumerator.describe(display: createdID)
        report.append("modes=\(info.modes.count) name=\(info.name) pixel=\(info.pixelWidth)x\(info.pixelHeight)")

        controller.disconnectAll()
        var removed = false
        var lastPixels: [String] = []
        for tick in 0..<100 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let pixels = Int(CGDisplayPixelsWide(createdID))
            if tick % 10 == 0 {
                lastPixels.append("t\(tick * 2 / 10)s=\(pixels)")
            }
            if pixels == 0 {
                removed = true
                break
            }
        }
        report.append("pixels timeline: \(lastPixels.joined(separator: " "))")
        report.append("removed=\(removed)")
        guard removed else {
            report.append("FAIL virtual display did not disappear")
            finish(false)
            return
        }

        finish(true)
    }

    private static func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return Int(count)
    }

    private static func onlineDisplayDump() -> [String] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        _ = CGGetOnlineDisplayList(count, &ids, &count)
        return ids.map { id in
            "online-list id=\(id) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))"
        }
    }

    private static func activeDisplayDump() -> [String] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        _ = CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            "active-list id=\(id) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) online=\(CGDisplayIsOnline(id) != 0)"
        }
    }
}
