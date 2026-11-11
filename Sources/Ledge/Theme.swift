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
    /// Indicators popping down out of the notch: quick, and stopping exactly at their size.
    static let pop = Animation.spring(response: 0.32, dampingFraction: 1, blendDuration: 0)
    /// The open island changing size (e.g. into Notes): one smooth move, no bounce, no overshoot.
    static let resize = Animation.spring(response: 0.38, dampingFraction: 1)
    /// The level bar following key presses: smooth, no overshoot.
    static let level = Animation.smooth(duration: 0.16)

    static let defaultTint = Color(red: 0.95, green: 0.60, blue: 0.46)
    static let secondaryText = Color(white: 0.58)
    static let track = Color(white: 0.2)
    static let green = Color(red: 0.37, green: 0.83, blue: 0.54)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let calendarRed = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let timerOrange = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let focusRed = Color(red: 1.0, green: 0.42, blue: 0.35)
    static let breakGreen = Color(red: 0.37, green: 0.83, blue: 0.54)
    static let awakeOrange = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let joinBlue = Color(red: 0.2, green: 0.47, blue: 0.96)
    /// The Notes and Reminders app colors, for the "Open in…" pills.
    static let notesYellow = Color(red: 1.0, green: 0.80, blue: 0.22)
    static let remindersBlue = Color(red: 0.24, green: 0.58, blue: 1.0)
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

/// How the island opens and closes (chosen in Settings → Animation).
enum IslandAnimation: String, CaseIterable, Identifiable {
    case morph, drop, stretch, calm

    static let key = "animationStyle"
    static var current: IslandAnimation {
        UserDefaults.standard.string(forKey: key).flatMap(IslandAnimation.init(rawValue:)) ?? .calm
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morph: return "Morph and blur"
        case .drop: return "Drop down"
        case .stretch: return "Stretch"
        case .calm: return "Calm"
        }
    }

    var detail: String {
        switch self {
        case .morph: return "Springs open, content sharpens in. Closest to iPhone."
        case .drop: return "Falls out of the notch first, then widens."
        case .stretch: return "Widens sideways first, then drops down."
        case .calm: return "Quick and smooth, no bounce."
        }
    }

    /// Width and height animate separately, so a style can do one before the other.
    func width(growing: Bool) -> Animation {
        // Closing always lands exactly on the notch's width (no dipping narrower and back).
        switch self {
        case .morph: return growing ? .spring(response: 0.5, dampingFraction: 0.72)
                                    : .spring(response: 0.34, dampingFraction: 1)
        case .drop: return growing ? .spring(response: 0.36, dampingFraction: 0.85).delay(0.12)
                                   : .spring(response: 0.3, dampingFraction: 1)
        case .stretch: return growing ? .spring(response: 0.32, dampingFraction: 0.8)
                                      : .spring(response: 0.3, dampingFraction: 1).delay(0.12)
        case .calm: return growing ? .smooth(duration: 0.28) : .smooth(duration: 0.24)
        }
    }

    func height(growing: Bool) -> Animation {
        // Heights stop exactly at their target (no stretching past it and back).
        switch self {
        case .morph: return growing ? .spring(response: 0.45, dampingFraction: 1)
                                    : .spring(response: 0.34, dampingFraction: 1)
        case .drop: return growing ? .spring(response: 0.36, dampingFraction: 1)
                                   : .spring(response: 0.3, dampingFraction: 1).delay(0.12)
        case .stretch: return growing ? .spring(response: 0.36, dampingFraction: 1).delay(0.1)
                                      : .spring(response: 0.26, dampingFraction: 1)
        case .calm: return growing ? .smooth(duration: 0.28) : .smooth(duration: 0.24)
        }
    }

    /// For everything else that changes with the shape (corner radii and so on).
    var shape: Animation { height(growing: true) }

    /// How the content inside appears and disappears. It never scales. It starts coming in while
    /// the shape is still opening (about a third of the way), so the island is never an empty black
    /// box, and it's fully there just as the shape settles.
    var content: AnyTransition {
        let out = AnyTransition.modifier(active: BlurFade(radius: 3, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
            .animation(.easeOut(duration: 0.12))
        func soft(_ blur: CGFloat, _ animation: Animation) -> AnyTransition {
            .modifier(active: BlurFade(radius: blur, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
                .animation(animation)
        }
        switch self {
        case .morph:
            return .asymmetric(insertion: soft(10, .easeOut(duration: 0.32).delay(0.08)), removal: out)
        case .drop:
            return .asymmetric(
                insertion: AnyTransition.offset(y: -8)
                    .combined(with: .modifier(active: BlurFade(radius: 3, opacity: 0), identity: BlurFade(radius: 0, opacity: 1)))
                    .animation(.spring(response: 0.36, dampingFraction: 0.92).delay(0.1)),
                removal: out)
        case .stretch:
            // Widens first, then drops: the content arrives with the drop.
            return .asymmetric(insertion: soft(4, .easeOut(duration: 0.24).delay(0.12)), removal: out)
        case .calm:
            return .asymmetric(insertion: soft(4, .easeOut(duration: 0.22).delay(0.05)), removal: out)
        }
    }

    /// Swapping one view for another inside the open island (quick add, a to-do, events and to-dos).
    static var swap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(radius: 3, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
                .animation(.easeOut(duration: 0.22).delay(0.04)),
            removal: .modifier(active: BlurFade(radius: 3, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
                .animation(.easeOut(duration: 0.12)))
    }

    /// Moving between pages: a crossfade in place with a soft focus. Nothing slides, so the content
    /// stays still while the island changes size around it.
    static var page: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(radius: 4, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
                .animation(.easeOut(duration: 0.24).delay(0.06)),
            removal: .modifier(active: BlurFade(radius: 4, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
                .animation(.easeOut(duration: 0.14)))
    }
}

struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}
