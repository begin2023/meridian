import AppKit

// Meridian: a luminous horizon crossed by a calibrated meridian line.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 0.025, green: 0.16, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.035, green: 0.39, blue: 0.46, alpha: 1)])!
        .draw(in: path, angle: -55)
    NSGraphicsContext.restoreGraphicsState()
    // 顶部高光，模拟玻璃质感
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: size * 0.50, y: size * 0.50)
    let horizon = NSBezierPath()
    horizon.move(to: NSPoint(x: size * 0.20, y: size * 0.46))
    horizon.curve(to: NSPoint(x: size * 0.80, y: size * 0.46),
                  controlPoint1: NSPoint(x: size * 0.36, y: size * 0.57),
                  controlPoint2: NSPoint(x: size * 0.64, y: size * 0.35))
    horizon.lineWidth = size * 0.035
    NSColor(calibratedRed: 0.72, green: 0.91, blue: 0.89, alpha: 0.9).setStroke()
    horizon.stroke()

    let meridian = NSBezierPath()
    meridian.move(to: NSPoint(x: center.x, y: size * 0.20))
    meridian.line(to: NSPoint(x: center.x, y: size * 0.80))
    meridian.lineWidth = size * 0.025
    NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.88, alpha: 0.78).setStroke()
    meridian.stroke()

    let glow = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.17, y: center.y - size * 0.17,
                                           width: size * 0.34, height: size * 0.34))
    NSColor(calibratedRed: 0.99, green: 0.79, blue: 0.39, alpha: 0.22).setFill()
    glow.fill()
    let star = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.105, y: center.y - size * 0.105,
                                           width: size * 0.21, height: size * 0.21))
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.96, blue: 0.79, alpha: 1),
                        NSColor(calibratedRed: 1, green: 0.68, blue: 0.28, alpha: 1)])!
        .draw(in: star, angle: -90)
    let satellite = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.055, y: center.y - size * 0.055,
                                                width: size * 0.11, height: size * 0.11))
    NSColor(calibratedRed: 0.84, green: 0.97, blue: 0.96, alpha: 1).setFill()
    satellite.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
