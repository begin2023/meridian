import AppKit

// Standalone candidate; the production icon stays in make-icon.swift until selected.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/IconDesign")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
}

func fill(_ path: NSBezierPath, _ hex: UInt32, _ alpha: CGFloat = 1) {
    color(hex, alpha).setFill()
    path.fill()
}

func gradient(_ path: NSBezierPath, _ colors: [UInt32], angle: CGFloat = -90) {
    NSGradient(colors: colors.map { color($0) })!.draw(in: path, angle: angle)
}

func stroke(_ path: NSBezierPath, _ hex: UInt32, width: CGFloat, alpha: CGFloat = 1) {
    color(hex, alpha).setStroke()
    path.lineWidth = width
    path.stroke()
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ opacity: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let effect = NSShadow()
    effect.shadowColor = color(0x001E27, opacity)
    effect.shadowBlurRadius = blur
    effect.shadowOffset = NSSize(width: 0, height: dy)
    effect.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()

    let tile = rounded(100, 100, 824, 824, 184)
    shadow(22, -12, 0.23) {
        gradient(tile, [0x168D9C, 0x096572, 0x063E50], angle: -62)
    }
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glow = NSGradient(starting: color(0x7CF5DD, 0.38), ending: color(0x7CF5DD, 0))!
    glow.draw(fromCenter: NSPoint(x: 235, y: 866), radius: 0,
              toCenter: NSPoint(x: 235, y: 866), radius: 750, options: [.drawsAfterEndingLocation])
    let shade = NSGradient(starting: color(0x002135, 0.35), ending: color(0x002135, 0))!
    shade.draw(fromCenter: NSPoint(x: 870, y: 120), radius: 0,
               toCenter: NSPoint(x: 870, y: 120), radius: 660, options: [.drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    stroke(rounded(103, 103, 818, 818, 181), 0xD7FFF5, width: 3, alpha: 0.25)

    // A broad handle is recognizable even at Dock size; the dark cutout is real negative space.
    let handle = rounded(376, 624, 272, 157, 54)
    shadow(13, -7, 0.28) { gradient(handle, [0xF8FFFF, 0xA9C5CB, 0xE0F0F0]) }
    gradient(rounded(419, 626, 186, 111, 24), [0x126E7A, 0x0E6271])
    stroke(rounded(381, 630, 262, 144, 49), 0xFFFFFF, width: 3, alpha: 0.65)

    let body = rounded(238, 276, 548, 384, 73)
    shadow(32, -25, 0.46) {
        gradient(body, [0xF1FAFA, 0xA5C2C9, 0x87AAB5])
    }
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    gradient(rounded(239, 482, 546, 178, 72), [0xFFFFFF, 0xE7F3F3, 0xBDD5DB])
    // The lid seam forms the horizontal rail of a single orange control slider.
    fill(rounded(238, 477, 548, 13, 5), 0x4E7784)
    fill(rounded(240, 490, 544, 3, 1), 0xFFFFFF, 0.65)
    let sheen = NSGradient(starting: color(0xFFFFFF, 0.29), ending: color(0xFFFFFF, 0))!
    sheen.draw(in: NSRect(x: 238, y: 276, width: 240, height: 384), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    stroke(rounded(241, 279, 542, 378, 70), 0xF2FFFF, width: 3, alpha: 0.75)
    stroke(rounded(245, 283, 534, 370, 65), 0x476F80, width: 2, alpha: 0.18)

    shadow(9, -5, 0.30) {
        gradient(rounded(466, 432, 92, 109, 23), [0xFFD38B, 0xFFAC48, 0xEC782C])
    }
    stroke(rounded(470, 437, 84, 100, 19), 0xFFF5D7, width: 3, alpha: 0.70)
    fill(rounded(488, 477, 48, 10, 5), 0xA74D1F, 0.70)
    fill(rounded(488, 487, 48, 3, 1.5), 0xFFFFFF, 0.55)

    // Three inset bars hint at monitoring without competing with the main silhouette.
    if pixels >= 64 {
        for (index, height) in [24, 42, 62].enumerated() {
            let bar = rounded(CGFloat(476 + index * 28), 326, 16, CGFloat(height), 7)
            fill(bar, 0x3F7784, 0.84)
            let glint = rounded(CGFloat(476 + index * 28), 324, 16, 3, 1.5)
            fill(glint, 0xEDFFFF, 0.60)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = output.appendingPathComponent("AppIcon-v2.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
        try render(base * scale).representation(using: .png, properties: [:])!.write(to: file)
    }
}
try render(1024).representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("meridian-v2.png"))

print("Generated candidate icon at \(output.path)")
