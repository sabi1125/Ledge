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
    case timerDone(duration: TimeInterval)
    case awakeOn(minutes: Int)
    case awakeOff
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
    /// A countdown is running or paused: it lives in the notch's right wing.
    @Published var timerActive = false { didSet { if timerActive != oldValue { recompute() } } }
    /// Called when the island opens, for the trackpad tick.
    var onOpen: (() -> Void)?

    /// Ledge's settings are showing in this island (opened from Spotlight or a right-click).
    @Published private(set) var isShowingSettings = false
    /// Called when settings open or close, so the panel can take or give back keyboard focus.
    var onSettingsShown: ((Bool) -> Void)?

    /// Whether the last shape change made the island bigger (opening) or smaller (closing).
    @Published private(set) var growing = true

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
        guard !isShowingSettings else { return } // settings has its own close button
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
        case .timerDone: seconds = 6
        case .awakeOn, .awakeOff: seconds = 1.8
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

    func openSettings() {
        guard !isShowingSettings else { return }
        isTyping = false
        isExpanded = false
        isShowingSettings = true
        recompute()
        onSettingsShown?(true)
        onOpen?()
    }

    func closeSettings() {
        guard isShowingSettings else { return }
        isShowingSettings = false
        recompute()
        onSettingsShown?(false)
    }

    /// Settings closes and reopens, to show the animation style just picked.
    func replaySettings() {
        guard isShowingSettings else { return }
        isShowingSettings = false
        recompute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, !self.isShowingSettings else { return }
            self.isShowingSettings = true
            self.recompute()
        }
    }

    /// Opens the island and closes it again, to show off the animation style.
    func previewAnimation() {
        guard !isExpanded else { return }
        expand(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, !self.isHovering, !self.isTyping else { return }
            self.close()
        }
    }

    /// Pages or features were switched on or off in settings.
    func settingsChanged() { recompute() }

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
        // On the notch, the countdown needs slightly wider wings than the music bars.
        guard style == .floating else { return timerActive ? notch.width + 2 * 52 : nil }
        let musicShowing = hasMedia && media.isPlaying
        let title = musicShowing ? (media.title ?? "") : "Timer"
        let artist = musicShowing ? (media.artist ?? "") : ""
        let bold = NSFont.systemFont(ofSize: pillFontSize, weight: .semibold)
        let plain = NSFont.systemFont(ofSize: pillFontSize, weight: .regular)
        var width = (title as NSString).size(withAttributes: [.font: bold]).width
        if !artist.isEmpty { width += ("  " + artist as NSString).size(withAttributes: [.font: plain]).width }
        // The countdown takes the place of the bars and is a bit wider.
        if timerActive { width += Self.countdownWidth(fontSize: pillFontSize) - 16 }
        return IslandLayout.floatingCompactWidth(textWidth: width.rounded(.up) + 2, height: notch.height)
    }

    static func countdownWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        return ("00:00" as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 2
    }
    var pages: [IslandPage] { IslandPage.available(enabled: Pref.enabledPages, hasMedia: hasMedia) }

    private func expand(force: Bool = false) {
        guard force || isHovering || !Pref.bool(Pref.openOnHover) else { return }
        guard !isExpanded, !pages.isEmpty else { return }
        // Open on Music while something plays, on the Timer while one runs; otherwise where you left off.
        if hasMedia && media.isPlaying && pages.contains(.music) { page = .music }
        else if timerActive && pages.contains(.timer) { page = .timer }
        else if !pages.contains(page) { page = pages.first ?? .calendar }
        isExpanded = true
        recompute()
        onOpen?()
    }

    private func collapseIfIdle() {
        guard isExpanded, !isHovering, !isTyping else { return }
        isExpanded = false
        recompute()
    }

    private func recompute() {
        if !pages.isEmpty && !pages.contains(page) { page = pages.first! }
        if isExpanded && pages.isEmpty { isExpanded = false }
        let next: IslandShape
        if isShowingSettings {
            next = .settings
        } else if isExpanded {
            next = .expanded
        } else if hud != nil {
            next = .hud
        } else if (hasMedia && media.isPlaying) || timerActive {
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
            // Long enough for the slowest closing animation to settle back into the notch.
            fillTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                Task { @MainActor in if self?.shape == .idle { self?.showsFill = false } }
            }
        }
        if next != shape {
            let old = IslandLayout.size(for: shape, notch: notch, style: style, compactWidth: compactWidth)
            let new = IslandLayout.size(for: next, notch: notch, style: style, compactWidth: compactWidth)
            growing = new.width * new.height >= old.width * old.height
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
