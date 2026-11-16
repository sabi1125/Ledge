import AppKit
import LedgeCore
import SwiftUI

/// The window switcher, inside the island: every window (two Chromes are two), in one of four
/// styles. Hold the shortcut's modifier and press its key to move, let go to switch.
struct SwitcherView: View {
    @ObservedObject var model: IslandModel
    var state: IslandModel.SwitcherState

    private var windows: [SwitcherWindow] { state.windows }
    private var selected: Int { state.selected }

    var body: some View {
        Group {
            if windows.isEmpty {
                Text("No windows to switch to")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch state.style {
                case .grid: grid
                case .focus: focus
                case .strip: strip
                case .list: list
                }
            }
        }
        .padding(.top, SwitcherLayout.top(notch: model.notch, style: model.style))
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: selected)
    }

    // MARK: 1 · Preview grid

    private var grid: some View {
        let g = SwitcherLayout.grid(count: windows.count)
        let columns = Array(repeating: GridItem(.fixed(g.thumb.width), spacing: SwitcherLayout.gridGap), count: g.columns)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: SwitcherLayout.gridGap) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { i, w in
                        VStack(spacing: 5) {
                            WindowThumb(window: w, size: g.thumb, selected: i == selected, tick: model.switcherPreviews)
                            title(w, selected: i == selected)
                                .frame(width: g.thumb.width)
                        }
                        .id(i)
                        .contentShape(Rectangle())
                        .onTapGesture { model.pickSwitcher(i) }
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: selected) { _, now in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(now, anchor: .center) } }
        }
    }

    // MARK: 2 · Focus with neighbours

    private var focus: some View {
        let big = SwitcherLayout.focusBig, small = SwitcherLayout.focusSmall
        return ZStack {
            ForEach(Array(windows.enumerated()), id: \.element.id) { i, w in
                let offset = signedOffset(i)
                if abs(offset) <= 1 {
                    let isMain = offset == 0
                    VStack(spacing: 6) {
                        WindowThumb(window: w, size: isMain ? big : small, selected: isMain, tick: model.switcherPreviews)
                        title(w, selected: isMain).frame(width: isMain ? big.width : small.width)
                    }
                    .opacity(isMain ? 1 : 0.5)
                    .offset(x: CGFloat(offset) * (big.width / 2 + small.width / 2 + 16), y: isMain ? 0 : (big.height - small.height) / 2)
                    .zIndex(isMain ? 1 : 0)
                    .onTapGesture { model.pickSwitcher(i) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Where a window sits relative to the chosen one, going round (so the last is "before" the first).
    private func signedOffset(_ i: Int) -> Int {
        let n = windows.count
        var d = (i - selected + n) % n
        if d > n / 2 { d -= n }
        return n == 2 && d == -1 ? 1 : d
    }

    // MARK: 3 · Icons and preview

    private var strip: some View {
        let w = windows[selected]
        return VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { i, win in
                            AppIcon(pid: win.pid, size: SwitcherLayout.stripIcon)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(i == selected ? 0.2 : 0)))
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { model.pickSwitcher(i) }
                                .help(win.title.isEmpty ? win.appName : win.title)
                        }
                    }
                    .frame(minWidth: SwitcherLayout.stripPreview.width)
                }
                .scrollIndicators(.never)
                .onChange(of: selected) { _, now in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(now, anchor: .center) } }
            }
            .frame(height: SwitcherLayout.stripIcon + 8)
            WindowThumb(window: w, size: SwitcherLayout.stripPreview, selected: false, tick: model.switcherPreviews)
                .id(w.id)
                .transition(.opacity)
            title(w, selected: true, long: true)
                .frame(width: SwitcherLayout.stripPreview.width)
        }
    }

    // MARK: 4 · List and preview

    private var list: some View {
        let w = windows[selected]
        return HStack(alignment: .top, spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { i, win in
                            HStack(spacing: 8) {
                                AppIcon(pid: win.pid, size: 18)
                                Text(label(win))
                                    .font(.system(size: 12, weight: i == selected ? .semibold : .regular))
                                    .foregroundStyle(i == selected ? Color.white : Color(white: 0.7))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7)
                            .frame(height: SwitcherLayout.listRow)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(i == selected ? 0.15 : 0)))
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { model.pickSwitcher(i) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selected) { _, now in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(now, anchor: .center) } }
            }
            .frame(width: SwitcherLayout.listWidth)
            WindowThumb(window: w, size: SwitcherLayout.listPreview, selected: false, tick: model.switcherPreviews)
                .id(w.id)
                .transition(.opacity)
        }
    }

    // MARK: Pieces

    /// "Chrome · GitHub — Ledge" (or just the app name when the window has no title).
    private func label(_ w: SwitcherWindow) -> String {
        w.title.isEmpty || w.title == w.appName ? w.appName : "\(w.appName) · \(w.title)"
    }

    private func title(_ w: SwitcherWindow, selected: Bool, long: Bool = false) -> some View {
        Text(label(w))
            .font(.system(size: long ? 12.5 : 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color(white: 0.62))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A window's preview (or, without one yet, its app's icon on a dark card), its app's icon in
/// the corner, and a white edge when it's the chosen one.
struct WindowThumb: View {
    var window: SwitcherWindow
    var size: CGSize
    var selected: Bool
    /// Changes when new previews come in.
    var tick: Int

    var body: some View {
        let card = RoundedRectangle(cornerRadius: max(6, size.width * 0.05), style: .continuous)
        ZStack(alignment: .bottomLeading) {
            card.fill(Color(white: 0.12))
            if let image = WindowCatalog.shared.previews[window.id] {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            } else {
                AppIcon(pid: window.pid, size: min(size.width, size.height) * 0.42)
                    .frame(width: size.width, height: size.height)
            }
            AppIcon(pid: window.pid, size: max(14, size.width * 0.1))
                .padding(max(4, size.width * 0.03))
                .opacity(WindowCatalog.shared.previews[window.id] == nil ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(card)
        .overlay(card.strokeBorder(Color.white.opacity(selected ? 0.95 : 0.08), lineWidth: selected ? 2.5 : 0.5))
    }
}

/// An app's icon, by process.
struct AppIcon: View {
    var pid: pid_t
    var size: CGFloat

    var body: some View {
        if let icon = WindowCatalog.shared.icon(for: pid) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(white: 0.25)).frame(width: size, height: size)
        }
    }
}
