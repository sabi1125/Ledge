import CoreGraphics

/// The shapes the island can take. Each one has a fixed target size;
/// SwiftUI springs between them.
public enum IslandShape: Equatable, Sendable {
    case idle       // exactly the hardware notch
    case hover      // small bump when the pointer is over an idle notch
    case compact    // music playing: art on the left wing, waveform on the right
    case hud        // volume / brightness / battery: wider wings
    case expanded   // full player
}

public struct NotchMetrics: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// Used on Macs without a notch (or in tests): matches a 14" MacBook Pro.
    public static let fallback = NotchMetrics(width: 185, height: 32)
}

public enum IslandLayout {
    /// Width of each "wing" next to the notch in compact mode.
    public static let compactWing: CGFloat = 42
    /// HUD mode drops below the notch like the Dynamic Island: extra width on each side,
    /// and a row under the notch for the icon, bar and number.
    public static let hudWing: CGFloat = 36
    public static let hudBody: CGFloat = 38
    /// Height of the player area under the notch when expanded.
    public static let expandedBody: CGFloat = 140
    public static let expandedMinWidth: CGFloat = 420

    public static func size(for shape: IslandShape, notch: NotchMetrics) -> CGSize {
        switch shape {
        case .idle:
            return CGSize(width: notch.width, height: notch.height)
        case .hover:
            return CGSize(width: notch.width + 18, height: notch.height + 4)
        case .compact:
            return CGSize(width: notch.width + compactWing * 2, height: notch.height)
        case .hud:
            return CGSize(width: notch.width + hudWing * 2, height: notch.height + hudBody)
        case .expanded:
            return CGSize(width: max(notch.width + 230, expandedMinWidth),
                          height: notch.height + expandedBody)
        }
    }

    /// Radius of the island's bottom corners.
    public static func bottomRadius(for shape: IslandShape, notch: NotchMetrics) -> CGFloat {
        switch shape {
        case .idle: return 10
        case .hover, .compact: return notch.height * 0.42
        case .hud: return 24
        case .expanded: return 30
        }
    }

    /// Radius of the small outward curves where the island meets the top edge,
    /// like the real notch's shoulders.
    public static func shoulderRadius(for shape: IslandShape) -> CGFloat {
        shape == .expanded ? 12 : 6
    }

    /// The window that hosts the island never changes size; it's big enough
    /// for the largest shape plus its shadow.
    public static func panelSize(notch: NotchMetrics) -> CGSize {
        let expanded = size(for: .expanded, notch: notch)
        let hud = size(for: .hud, notch: notch)
        return CGSize(width: max(expanded.width, hud.width) + 120, height: expanded.height + 50)
    }
}
