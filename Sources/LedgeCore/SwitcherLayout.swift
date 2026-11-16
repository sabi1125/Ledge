import CoreGraphics

/// How the window switcher lays out its windows, in each of its four styles.
public enum SwitcherStyle: String, CaseIterable, Sendable {
    /// Every window as a preview, in rows under the notch.
    case grid
    /// The chosen window big in the middle, the one before and after smaller at the sides.
    case focus
    /// A row of icons (one per window) and a big preview of the chosen one. The default.
    case strip
    /// Icons and titles in a list, the chosen one's preview beside it.
    case list

    public static let key = "switcherStyle"

    public var title: String {
        switch self {
        case .grid: return "Preview grid"
        case .focus: return "Focus"
        case .strip: return "Icons and preview"
        case .list: return "List and preview"
        }
    }

    public var detail: String {
        switch self {
        case .grid: return "Every window as a preview, in rows."
        case .focus: return "The chosen window big, its neighbours at the sides."
        case .strip: return "A row of icons and one big preview."
        case .list: return "Titles in a list, the preview beside them."
        }
    }
}

public enum SwitcherLayout {
    /// The space under the notch (or the pill's top edge) before the windows start.
    public static func top(notch: NotchMetrics, style: IslandStyle) -> CGFloat {
        style == .notch ? notch.height + 8 : 14
    }

    // Grid
    public static let gridGap: CGFloat = 10
    /// Columns and the size of one preview: up to 4 across; smaller previews past 8 windows,
    /// so 3 rows still fit.
    public static func grid(count: Int) -> (columns: Int, rows: Int, thumb: CGSize) {
        let n = max(1, count)
        let columns = min(n, n > 8 ? 5 : 4)
        let rows = min(3, Int((Double(n) / Double(columns)).rounded(.up)))
        let thumb = n > 8 ? CGSize(width: 112, height: 70) : CGSize(width: 140, height: 88)
        return (columns, rows, thumb)
    }
    /// A grid cell: the preview and the title under it.
    public static func gridCell(_ thumb: CGSize) -> CGSize { CGSize(width: thumb.width, height: thumb.height + 20) }

    // Focus
    public static let focusBig = CGSize(width: 300, height: 188)
    public static let focusSmall = CGSize(width: 150, height: 94)

    // Strip
    public static let stripIcon: CGFloat = 30
    public static let stripPreview = CGSize(width: 420, height: 236)

    // List
    public static let listWidth: CGFloat = 230
    public static let listRow: CGFloat = 28
    public static let listVisibleRows = 9
    public static let listPreview = CGSize(width: 360, height: 225)

    /// The whole island for this many windows, in this style.
    public static func size(style s: SwitcherStyle, count: Int, notch: NotchMetrics, style: IslandStyle) -> CGSize {
        let top = top(notch: notch, style: style)
        let bottom: CGFloat = 16
        let side: CGFloat = 18
        switch s {
        case .grid:
            let g = grid(count: count)
            let cell = gridCell(g.thumb)
            let w = CGFloat(g.columns) * cell.width + CGFloat(g.columns - 1) * gridGap + side * 2
            let h = CGFloat(g.rows) * cell.height + CGFloat(g.rows - 1) * gridGap
            return CGSize(width: max(w, minWidth(notch, style)), height: top + h + bottom)
        case .focus:
            let w = focusBig.width + (focusSmall.width + 16) * 2 + side * 2
            return CGSize(width: w, height: top + focusBig.height + 26 + bottom)
        case .strip:
            let w = max(stripPreview.width + side * 2, minWidth(notch, style))
            return CGSize(width: w, height: top + stripIcon + 12 + stripPreview.height + 24 + bottom)
        case .list:
            let rows = CGFloat(min(max(count, 1), listVisibleRows))
            let h = max(rows * listRow, listPreview.height)
            return CGSize(width: listWidth + 14 + listPreview.width + side * 2, height: top + h + bottom)
        }
    }

    /// Never narrower than the open island (so it clearly comes out past the notch).
    private static func minWidth(_ notch: NotchMetrics, _ style: IslandStyle) -> CGFloat {
        style == .notch ? max(notch.width + 230, IslandLayout.expandedMinWidth) : IslandLayout.expandedMinWidth
    }
}
