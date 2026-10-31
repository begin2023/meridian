import AppKit
import ScreenshotLabKit

@main
@MainActor
struct ScreenshotLabOCRSmoke {
    static func main() async {
        _ = NSApplication.shared
        let fixtures = [
            ("2K", makeImage(width: 2200, height: 1300, titleSize: 72, bodySize: 42)),
            ("5K-downsample", makeImage(width: 5120, height: 2880, titleSize: 84, bodySize: 34)),
        ]
        for (name, image) in fixtures {
            do {
                let result = try await OCRService.recognize(image: image, timeout: 30)
                let required = [
                    "ScreenshotLab",
                    "中文文字识别测试",
                    "Clipboard: Hello, 2026!",
                ]
                let missing = required.filter { !result.content.contains($0) }
                guard missing.isEmpty else {
                    fail("\(name) missing=\(missing) content=\(result.content)")
                }
                let positions = required.compactMap { result.content.range(of: $0)?.lowerBound }
                guard positions.count == required.count,
                      zip(positions, positions.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
                    fail("\(name) line order content=\(result.content)")
                }
                guard result.elapsedMilliseconds < 12_000 else {
                    fail("\(name) too slow: \(Int(result.elapsedMilliseconds)) ms")
                }
                print(
                    "SCREENSHOT_OCR_SMOKE_PASS \(name) "
                        + "lines=\(result.lineCount) chars=\(result.characterCount) "
                        + "ms=\(Int(result.elapsedMilliseconds.rounded()))"
                )
            } catch {
                fail("\(name) \(error.localizedDescription)")
            }
        }
    }

    private static func makeImage(
        width: Int,
        height: Int,
        titleSize: CGFloat,
        bodySize: CGFloat
    ) -> CGImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]
        NSString(string: "ScreenshotLab").draw(
            at: CGPoint(x: 160, y: CGFloat(height) - 260),
            withAttributes: titleAttributes
        )

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bodySize, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
        ]
        NSString(string: "中文文字识别测试").draw(
            at: CGPoint(x: 160, y: CGFloat(height) * 0.58),
            withAttributes: bodyAttributes
        )
        NSString(string: "Clipboard: Hello, 2026!").draw(
            at: CGPoint(x: 160, y: CGFloat(height) * 0.50),
            withAttributes: bodyAttributes
        )

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("SCREENSHOT_OCR_SMOKE_FAIL \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
