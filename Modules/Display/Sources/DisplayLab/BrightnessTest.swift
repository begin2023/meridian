import AppKit
import DisplayCore

/// End-to-end brightness regression: drives the combined brightness
/// controller against the real hardware, verifies a set sticks, then restores
/// the original value. Reports to /tmp/displaylab-brightness-test.txt with a
/// final BRIGHTNESS_TEST_PASS/FAIL marker for the shell runner.
enum BrightnessTest {
    static func run(displayManager: DisplayManager) {
        var report: [String] = []

        func finish(_ pass: Bool) {
            report.append(pass ? "BRIGHTNESS_TEST_PASS" : "BRIGHTNESS_TEST_FAIL")
            let text = report.joined(separator: "\n")
            try? text.write(toFile: "/tmp/displaylab-brightness-test.txt", atomically: true, encoding: .utf8)
            fflush(stdout)
            print(text)
            exit(pass ? 0 : 1)
        }

        let candidates = displayManager.displays.compactMap { display -> (DisplayInfo, DisplayBrightnessController)? in
            guard let controller = displayManager.brightnessController(for: display.identifier),
                  controller.backendKind == .ddc || controller.backendKind == .apple else {
                return nil
            }
            return (display, controller)
        }

        guard let (display, controller) = candidates.first else {
            report.append("FAIL no brightness-capable display")
            finish(false)
            return
        }

        report.append("display=\(display.identifier) backend=\(controller.backendKind.rawValue)")

        DispatchQueue.global(qos: .userInitiated).async {
            guard let original = controller.readCurrentFraction() else {
                report.append("FAIL initial brightness read")
                finish(false)
                return
            }
            report.append(String(format: "original=%.3f", original))

            controller.setTarget(0.5, smooth: false)
            Thread.sleep(forTimeInterval: 1.5)

            guard let midRead = controller.readCurrentFraction() else {
                report.append("FAIL mid brightness read")
                finish(false)
                return
            }
            report.append(String(format: "mid=%.3f", midRead))
            if abs(midRead - 0.5) > 0.05 {
                report.append("FAIL mid value drifted beyond tolerance")
                finish(false)
                return
            }

            controller.setTarget(original, smooth: false)
            Thread.sleep(forTimeInterval: 1.5)

            guard let restored = controller.readCurrentFraction() else {
                report.append("FAIL restore read")
                finish(false)
                return
            }
            report.append(String(format: "restored=%.3f", restored))
            if abs(restored - original) > 0.05 {
                report.append("FAIL restore drifted beyond tolerance")
                finish(false)
                return
            }

            finish(true)
        }
    }
}
