import AppKit

enum DebugFixtures {
    static func makeSampleImage(
        width: Int = 1800,
        height: Int = 1100
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

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1),
        ])!
        gradient.draw(in: bounds, angle: -28)

        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 90, dy: 90),
            xRadius: 34,
            yRadius: 34
        )
        NSColor(calibratedWhite: 0.96, alpha: 0.97).setFill()
        card.fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]
        NSString(string: "ScreenshotLab").draw(
            at: CGPoint(x: 150, y: 820),
            withAttributes: titleAttributes
        )

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
        ]
        let body = """
        截图 · 标注 · 钉图 · OCR
        中文文字识别测试
        Clipboard: Hello, 2026!
        """
        NSString(string: body).draw(
            in: CGRect(x: 150, y: 420, width: width - 300, height: 330),
            withAttributes: bodyAttributes
        )

        let accentRect = NSBezierPath(
            roundedRect: CGRect(x: 150, y: 260, width: 480, height: 92),
            xRadius: 18,
            yRadius: 18
        )
        AppTheme.accent.setFill()
        accentRect.fill()

        let accentText: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
        ]
        NSString(string: "LOCAL VISION OCR").draw(
            at: CGPoint(x: 190, y: 288),
            withAttributes: accentText
        )

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }

    @MainActor
    static func makeSnapshot() -> ScreenSnapshot {
        let screen = ScreenCaptureService.screenAtMouse()
        let pixelWidth = Int(screen.frame.width * screen.backingScaleFactor)
        let pixelHeight = Int(screen.frame.height * screen.backingScaleFactor)
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        return ScreenSnapshot(
            image: makeSampleImage(width: pixelWidth, height: pixelHeight),
            screen: screen,
            displayID: CGDirectDisplayID(screenNumber?.uint32Value ?? CGMainDisplayID()),
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor
        )
    }
}
