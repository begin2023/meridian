import AppKit
import DisplayCore

/// Mode switching regression. Safest possible round trip: re-apply the
/// currently active mode through both the public and CGS paths and verify
/// the mode stays current. Reports to /tmp/displaylab-mode-test.txt with a
/// final MODE_TEST_PASS/FAIL marker.
enum ModeTest {
    static func run(displayManager: DisplayManager) {
        var report: [String] = []

        func finish(_ pass: Bool) {
            report.append(pass ? "MODE_TEST_PASS" : "MODE_TEST_FAIL")
            let text = report.joined(separator: "\n")
            try? text.write(toFile: "/tmp/displaylab-mode-test.txt", atomically: true, encoding: .utf8)
            fflush(stdout)
            print(text)
            exit(pass ? 0 : 1)
        }

        guard let display = displayManager.displays.first else {
            report.append("FAIL no display")
            finish(false)
            return
        }

        guard let current = display.currentMode else {
            report.append("FAIL no current mode identified")
            finish(false)
            return
        }
        report.append("display=\(display.identifier) current=\(current.label) cgsIndex=\(current.cgsIndex.map(String.init) ?? "nil")")

        DispatchQueue.global(qos: .userInitiated).async {
            // Public path (or CGS path when the mode came from the CGS table).
            do {
                try ModeService.apply(mode: current, to: display.identifier)
            } catch {
                report.append("FAIL re-apply current mode: \(error.localizedDescription)")
                finish(false)
                return
            }
            Thread.sleep(forTimeInterval: 1.0)

            let after = DisplayEnumerator.describe(display: display.identifier)
            guard let afterMode = after.currentMode else {
                report.append("FAIL current mode disappeared after apply")
                finish(false)
                return
            }
            report.append("after=\(afterMode.label)")

            let dimensionsStable = afterMode.pixelWidth == current.pixelWidth
                && afterMode.pixelHeight == current.pixelHeight
            guard dimensionsStable else {
                report.append("FAIL mode changed dimensions")
                finish(false)
                return
            }

            finish(true)
        }
    }
}
