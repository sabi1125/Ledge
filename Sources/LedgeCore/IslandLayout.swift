import CoreGraphics

/// The shapes the island can take. Each one has a fixed target size;
/// SwiftUI animates between them.
public enum IslandShape: Equatable, Sendable {
    case idle       // at rest: the hardware notch (notch) or a small pill (floating)
    case hover      // small bump when the pointer is over a resting island (click-to-open mode)
    case compact    // music playing
    case hud        // volume / brightness / battery
    case expanded   // open: Music, Calendar, Timer, Notes
    case settings   // Ledge's settings, opened from Spotlight or a right-click
}

/// Where the island lives.
public enum IslandStyle: Equatable, Sendable {
    /// Grows out of the MacBook's notch.
    case notch
    /// A detached pill in the middle of the menu bar (screens without a notch),
    /// like the original iPhone Dynamic Island.
    case floating
}

/// For `.notch`: the notch's size. For `.floating`: the resting pill's size.
public struct NotchMetrics: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// Used on Macs without a notch (or in tests): matches a 14" MacBook Pro.
    public static let fallback = NotchMetrics(width: 185, height: 32)

    /// The resting pill on a screen without a notch: sized to fit inside the menu bar, or a bit
    /// bigger (closer to the iPhone's) when that screen shows no menu bar.
    public static func floatingPill(menuBarHeight: CGFloat) -> NotchMetrics {
        guard menuBarHeight > 0 else { return NotchMetrics(width: 126, height: 28) }
        return NotchMetrics(width: 112, height: max(18, menuBarHeight - 6))
    }
}

public enum IslandLayout {
    /// Width of each "wing" next to the notch in compact mode.
    public static let compactWing: CGFloat = 42
    /// HUD mode drops below the notch like the Dynamic Island: extra width on each side,
    /// and a row under the notch for the icon, bar and number.
    public static let hudWing: CGFloat = 36
    public static let hudBody: CGFloat = 38
    /// Height of the open island's content area (below the notch or the top bar).
    public static let expandedBody: CGFloat = 140
    public static let expandedMinWidth: CGFloat = 530
    /// The settings panel: wider than the open island, a sidebar and one section.
    public static let settingsWidth: CGFloat = 640
    public static let settingsBody: CGFloat = 272
    /// Height of the page bar at the top of an open floating island.
    public static let floatingTopBar: CGFloat = 28
    /// Gap between the top of the screen and a floating island.
    public static let floatingTopGap: CGFloat = 3

    /// The floating music pill fits its content: art + song name + bars, with even ends.
    public static func floatingCompactWidth(textWidth: CGFloat, height h: CGFloat) -> CGFloat {
        let m = floatingCompactMetrics(height: h)
        let content = m.leading + m.art + m.gap + min(textWidth, 230) + m.gap + m.bars + m.trailing
        return min(max(content.rounded(.up), h * 6), 350)
    }

    /// Sizes inside the floating music pill. The art and the bars sit well inside the pill's
    /// round ends (`leading` / `trailing`), with the bars a touch further in since they're thin.
    public static func floatingCompactMetrics(height h: CGFloat)
        -> (art: CGFloat, leading: CGFloat, trailing: CGFloat, gap: CGFloat, bars: CGFloat) {
        let art = (h * 0.68).rounded()
        let leading = ((h - art) / 2 + h * 0.22).rounded()
        return (art, leading, leading + 3, 9, 16)
    }

    public static func size(for shape: IslandShape, notch: NotchMetrics, style: IslandStyle = .notch,
                            compactWidth: CGFloat? = nil) -> CGSize {
        switch style {
        case .notch:
            switch shape {
            case .idle:
                return CGSize(width: notch.width, height: notch.height)
            case .hover:
                return CGSize(width: notch.width + 18, height: notch.height + 4)
            case .compact:
                return CGSize(width: compactWidth ?? (notch.width + compactWing * 2), height: notch.height)
            case .hud:
                return CGSize(width: notch.width + hudWing * 2, height: notch.height + hudBody)
            case .expanded:
                return CGSize(width: max(notch.width + 230, expandedMinWidth),
                              height: notch.height + expandedBody)
            case .settings:
                return CGSize(width: settingsWidth, height: notch.height + settingsBody)
            }
        case .floating:
            let h = notch.height
            switch shape {
            case .idle: return CGSize(width: notch.width, height: h)
            case .hover: return CGSize(width: notch.width + 14, height: h + 2)
            case .compact: return CGSize(width: compactWidth ?? (280 + (h - 18) * 3), height: h)
            case .hud: return CGSize(width: 230 + (h - 18) * 2, height: h)
            case .expanded: return CGSize(width: expandedMinWidth, height: floatingTopBar + expandedBody)
            case .settings: return CGSize(width: settingsWidth, height: floatingTopBar + settingsBody)
            }
        }
    }

    /// Radius of the island's bottom corners.
    public static func bottomRadius(for shape: IslandShape, notch: NotchMetrics, style: IslandStyle = .notch) -> CGFloat {
        switch style {
        case .notch:
            switch shape {
            case .idle: return 10
            case .hover, .compact: return notch.height * 0.42
            case .hud: return 24
            case .expanded, .settings: return 30
            }
        case .floating:
            return shape == .expanded || shape == .settings ? 26 : size(for: shape, notch: notch, style: style).height / 2
        }
    }

    /// Radius of the top corners. The notch island is flush with the top edge; the pill is round all over.
    public static func topRadius(for shape: IslandShape, notch: NotchMetrics, style: IslandStyle = .notch) -> CGFloat {
        style == .notch ? 0 : bottomRadius(for: shape, notch: notch, style: style)
    }

    /// Radius of the small outward curves where the notch island meets the top edge,
    /// like the real notch's shoulders. The floating pill has none.
    public static func shoulderRadius(for shape: IslandShape, style: IslandStyle = .notch) -> CGFloat {
        guard style == .notch else { return 0 }
        return shape == .expanded || shape == .settings ? 12 : 6
    }

    /// Space above the island inside its window.
    public static func topGap(style: IslandStyle) -> CGFloat {
        style == .notch ? 0 : floatingTopGap
    }

    /// The window that hosts the island never changes size; it's big enough
    /// for the largest shape plus its shadow.
    public static func panelSize(notch: NotchMetrics, style: IslandStyle = .notch) -> CGSize {
        let biggest = [IslandShape.expanded, .hud, .settings].map { size(for: $0, notch: notch, style: style) }
        return CGSize(width: biggest.map(\.width).max()! + 120,
                      height: biggest.map(\.height).max()! + topGap(style: style) + 50)
    }
}
