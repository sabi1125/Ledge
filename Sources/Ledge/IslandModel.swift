import AppKit
import Combine
import LedgeCore
import SwiftUI

/// A short-lived indicator shown in the island.
enum HUD: Equatable {
    case volume(level: Double, muted: Bool)
    case brightness(level: Double)
    case charging(percent: Int)
    case lowBattery(percent: Int)
}

/// Everything the island view needs to draw itself.
@MainActor
final class IslandModel: ObservableObject {
    /// Notch island on the MacBook screen, floating pill on other screens.
    @Published var style: IslandStyle = .notch { didSet { recompute() } }
    @Published var notch: NotchMetrics = .fallback
    @Published private(set) var shape: IslandShape = .idle

    @Published var media = NowPlayingState() { didSet { recompute() } }
    @Published var artwork: NSImage?
    @Published var tint: Color = Theme.defaultTint

    @Published private(set) var hud: HUD?
    @Published private(set) var isHovering = false
    @Published private(set) var isExpanded = false
    /// Whether the black shape is drawn (see `recompute`).
    @Published private(set) var showsFill = false
    private var fillTimer: Timer?

    /// The page shown in the open island.
    @Published private(set) var page: IslandPage = .calendar
    /// True while you're typing in Notes: the island stays open until you click away or press Esc.
    @Published var isTyping = false { didSet { if !isTyping { collapseIfIdle() } } }

    var onCommand: ((MediaCommand) -> Void)?
    /// Called when the island should give keyboard focus back (leaving Notes or closing).
    var onEndTyping: (() -> Void)?

    private var hudTimer: Timer?
    private var hoverTimer: Timer?
    private var collapseTimer: Timer?

    // MARK: Inputs

    func pointerEntered() {
        guard !isHovering else { return }
        isHovering = true
        collapseTimer?.invalidate()
        recompute()
        guard Pref.bool(Pref.openOnHover) else { return }
        // Short delay so it doesn't spring open when you just reach for the menu bar.
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expand() }
        }
    }

    func pointerExited() {
        guard isHovering else { return }
        isHovering = false
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.collapseIfIdle() }
        }
        recompute()
    }

    func clicked() {
        if isExpanded {
            // Clicks inside Notes are for typing, not for closing.
            guard page != .notes else { return }
            close()
        } else {
            expand(force: true)
        }
    }

    /// Closes the island (Esc in Notes, or a click on Music/Calendar).
    func close() {
        isTyping = false
        onEndTyping?()
        isExpanded = false
        recompute()
    }

    /// Two-finger swipe while open: fingers left = next page, right = previous.
    func swipePage(forward: Bool) {
        guard isExpanded, let next = IslandPage.step(from: page, forward: forward, in: pages) else { return }
        show(page: next)
    }

    func show(page newPage: IslandPage) {
        guard newPage != page else { return }
        if page == .notes { isTyping = false; onEndTyping?() }
        page = newPage
    }

    func show(_ newHUD: HUD) {
        hud = newHUD
        hudTimer?.invalidate()
        let seconds: TimeInterval
        switch newHUD {
        case .volume, .brightness: seconds = 1.5
        case .charging, .lowBattery: seconds = 2.6
        }
        hudTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hud = nil
                self?.recompute()
            }
        }
        recompute()
    }

    func setArtwork(image: NSImage?, tint newTint: Color) {
        artwork = image
        tint = newTint
    }

    /// Used only by the snapshot tool to draw a specific state.
    func forceShape(_ s: IslandShape, hud: HUD? = nil, page: IslandPage? = nil) {
        self.hud = hud
        if let page { self.page = page }
        showsFill = s != .idle || style == .floating
        shape = s
    }

    // MARK: State

    var hasMedia: Bool { Pref.bool(Pref.showMusic) && media.hasContent }

    /// Font size of the song name in the floating music pill.
    var pillFontSize: CGFloat { notch.height >= 24 ? 12 : 11 }

    /// Width of the floating music pill, sized to fit the song name (nil on the notch).
    var compactWidth: CGFloat? {
        guard style == .floating else { return nil }
        let title = media.title ?? "", artist = media.artist ?? ""
        let bold = NSFont.systemFont(ofSize: pillFontSize, weight: .semibold)
        let plain = NSFont.systemFont(ofSize: pillFontSize, weight: .regular)
        var width = (title as NSString).size(withAttributes: [.font: bold]).width
        if !artist.isEmpty { width += ("  " + artist as NSString).size(withAttributes: [.font: plain]).width }
        return IslandLayout.floatingCompactWidth(textWidth: width.rounded(.up) + 2, height: notch.height)
    }
    var pages: [IslandPage] { IslandPage.available(hasMedia: hasMedia) }

    private func expand(force: Bool = false) {
        guard force || isHovering || !Pref.bool(Pref.openOnHover) else { return }
        guard !isExpanded else { return }
        // Open on Music while something plays; otherwise where you left off.
        if hasMedia && media.isPlaying { page = .music }
        else if !pages.contains(page) { page = pages.first ?? .calendar }
        isExpanded = true
        recompute()
    }

    private func collapseIfIdle() {
        guard isExpanded, !isHovering, !isTyping else { return }
        isExpanded = false
        recompute()
    }

    private func recompute() {
        if page == .music && !hasMedia { page = .calendar }
        let next: IslandShape
        if isExpanded {
            next = .expanded
        } else if hud != nil {
            next = .hud
        } else if hasMedia && media.isPlaying {
            next = .compact
        } else if isHovering && !Pref.bool(Pref.openOnHover) {
            // Click-to-open mode: a small bump shows the island noticed you.
            // With hover-to-open it goes straight from the notch to open, in one motion.
            next = .hover
        } else {
            next = .idle
        }
        // The black shape is solid whenever the island is out (and while it animates back in);
        // it turns invisible only once it has fully settled back into the notch.
        // The floating pill is always visible.
        if next != .idle || style == .floating {
            fillTimer?.invalidate()
            if !showsFill { showsFill = true }
        } else if showsFill {
            fillTimer?.invalidate()
            fillTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                Task { @MainActor in if self?.shape == .idle { self?.showsFill = false } }
            }
        }
        if next != shape {
            let p = NSEvent.mouseLocation
            LedgeLog.shared.write("island: \(shape) -> \(next) page \(page.rawValue) (pointer \(Int(p.x)),\(Int(p.y)) buttons \(NSEvent.pressedMouseButtons) hover \(isHovering) typing \(isTyping) playing \(media.isPlaying))")
            shape = next
        }
    }
}

enum MediaCommand {
    case toggle, next, previous
    case seek(Double)
}
