// Draws Ledge's app icon: a dark squircle with a black island holding a
// tiny album cover and a warm waveform. Usage: swift make-icon.swift OUT.iconset
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle background with a deep violet gradient (like a dusk wallpaper).
    let inset = 100 * s
    let bg = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.29, blue: 0.66, alpha: 1),
                        NSColor(srgbRed: 0.14, green: 0.11, blue: 0.31, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // The island, hanging from the top edge.
    let islandW = 560 * s, islandH = 150 * s
    let island = NSRect(x: (size - islandW) / 2, y: bg.maxY - islandH - 70 * s, width: islandW, height: islandH)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: islandH / 2, yRadius: islandH / 2).fill()

    // Album art on the left.
    let art = NSRect(x: island.minX + 34 * s, y: island.midY - 42 * s, width: 84 * s, height: 84 * s)
    let artPath = NSBezierPath(roundedRect: art, xRadius: 22 * s, yRadius: 22 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.75, blue: 0.54, alpha: 1),
                        NSColor(srgbRed: 0.88, green: 0.45, blue: 0.48, alpha: 1),
                        NSColor(srgbRed: 0.48, green: 0.25, blue: 0.56, alpha: 1)])!
        .draw(in: artPath, angle: -45)

    // Waveform on the right.
    let heights: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.5]
    let barW = 16 * s, gap = 12 * s, maxH = 86 * s
    var x = island.maxX - 40 * s - CGFloat(heights.count) * barW - CGFloat(heights.count - 1) * gap
    NSColor(srgbRed: 0.95, green: 0.6, blue: 0.46, alpha: 1).setFill()
    for h in heights {
        let bh = maxH * h
        NSBezierPath(roundedRect: NSRect(x: x, y: island.midY - bh / 2, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
