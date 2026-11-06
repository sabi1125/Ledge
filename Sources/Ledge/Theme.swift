import AppKit
import SwiftUI

enum Theme {
    /// One motion for every open, close and resize, so it all feels like one object.
    /// "Calm": quick and smooth, with no bounce.
    static let spring = Animation.smooth(duration: 0.28)
    /// Content fades in just after the shape starts opening, and fades out quickly on close.
    static let contentIn = Animation.easeOut(duration: 0.22).delay(0.1)
    static let contentOut = Animation.easeOut(duration: 0.14)
    static let quick = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// A bouncier spring for indicators popping down out of the notch.
    static let pop = Animation.spring(response: 0.38, dampingFraction: 0.64, blendDuration: 0)

    static let defaultTint = Color(red: 0.95, green: 0.60, blue: 0.46)
    static let secondaryText = Color(white: 0.58)
    static let track = Color(white: 0.2)
    static let green = Color(red: 0.37, green: 0.83, blue: 0.54)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let calendarRed = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let timerOrange = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let joinBlue = Color(red: 0.2, green: 0.47, blue: 0.96)
}

enum ArtworkColor {
    /// Average color of the artwork, nudged bright and saturated enough to read on black.
    static func tint(for image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 12
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        // Weight colorful pixels more, so a gray background doesn't win.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let sat = max(pr, pg, pb) - min(pr, pg, pb)
            let w = 0.15 + sat * 2
            r += pr * w; g += pg * w; b += pb * w; total += w
        }
        guard total > 0 else { return nil }
        let base = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        base.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let tuned = NSColor(hue: h, saturation: min(max(s * 1.15, s < 0.08 ? s : 0.35), 0.9),
                            brightness: max(v, 0.82), alpha: 1)
        return Color(nsColor: tuned)
    }
}
