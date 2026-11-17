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
    case pomodoro(ended: PomodoroPhase, next: PomodoroPhase, minutes: Int)
    case awakeOff
    /// Files went into the tray ("Holding 2 files in tray"), or didn't fit (`full`).
    case tray(text: String, full: Bool)
}

/// Everything the island view needs to draw itself.
@MainActor
final class IslandModel: ObservableObject {
    /// Notch island on the MacBook screen, floating pill on other screens.
    @Published var style: IslandStyle = .notch { didSet { recompute() } }
    @Published var notch: NotchMetrics = .fallback
    @Published private(set) var shape: IslandShape = .idle
    /// The last open size (normal or bigger for notes). The open content keeps this size while it
    /// fades out, so it never shrinks as the island closes.
    @Published private(set) var lastOpenShape: IslandShape = .expanded
    /// False while the island is still opening or changing size. Text boxes (macOS text views)
    /// aren't clipped to the moving black shape, so their text would show outside it for a moment;
    /// until it settles they're drawn as plain text, which is clipped.
    @Published private(set) var isSettled = true
    private var settleTimer: Timer?

    @Published var media = NowPlayingState() { didSet { recompute() } }
    @Published var artwork: NSImage?
    @Published var tint: Color = Theme.defaultTint

    @Published private(set) var hud: HUD?
    @Published private(set) var isHovering = false
    @Published private(set) var isExpanded = false
    /// A countdown is running or paused: it lives in the notch's right wing.
    @Published var timerActive = false { didSet { if timerActive != oldValue { recompute() } } }
    /// "Timer", "Focus", "Short break"… (sizes the floating pill).
    var timerTitle = "Timer"
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
    @Published private(set) var page: IslandPage = .calendar { didSet { if page != oldValue { recompute() } } }
    /// True while you're typing in Notes: the island stays open until you click away or press Esc.
    @Published var isTyping = false {
        didSet {
            guard !isTyping else { return }
            notesWantsCursor = false
            // Clicking away also ends quick add or an open to-do, but remembers it, so the island
            // reopens right there (with what you typed) next time.
            if isQuickAdding {
                LedgeLog.shared.write("quick add: closed because typing ended (clicked away or lost the keyboard)")
                resume = .quickAdd(quickAddKind)
                isQuickAdding = false
            }
            if let id = openTodoID { resume = .todo(id); openTodoID = nil }
            collapseIfIdle()
        }
    }
    /// True while the Calendar page shows the quick add line ("Dentist tomorrow 3pm").
    @Published private(set) var isQuickAdding = false { didSet { if isQuickAdding != oldValue { recompute() } } }
    /// What quick add makes: an event (Events mode) or a to-do (To-dos mode).
    @Published private(set) var quickAddKind: CalendarMode = .events
    /// The Calendar page's Events · To-dos switch (remembered).
    @Published var calendarMode: CalendarMode = CalendarMode.saved {
        didSet {
            UserDefaults.standard.set(calendarMode.rawValue, forKey: CalendarMode.key)
            if calendarMode != oldValue { recompute() }
        }
    }
    /// Where the island was when it closed by accident (a click elsewhere): quick add or an open
    /// to-do. Opening it again goes straight back there. Saving or Esc clears it.
    private enum Resume: Equatable { case quickAdd(CalendarMode), todo(String) }
    private var resume: Resume?

    /// A to-do opened from the list, showing its steps.
    @Published private(set) var openTodoID: String? { didSet { if openTodoID != oldValue { recompute() } } }

    var onCommand: ((MediaCommand) -> Void)?
    /// Called when the island should give keyboard focus back (leaving Notes or closing).
    var onEndTyping: (() -> Void)?
    /// Called when quick add opens, so the panel takes keyboard focus.
    var onBeginTyping: (() -> Void)?
    /// Quick add's notes view is showing (⌘N or the Notes button). Kept here, not in the view,
    /// so keys handled by the island controller change what's on screen.
    @Published var quickAddShowsNotes = false { didSet { if quickAddShowsNotes != oldValue { recompute() } } }
    /// Keys for the quick add view (⌘↩ save, typing that arrived early). The view listens.
    let quickAddKeys = PassthroughSubject<QuickAddKey, Never>()
    /// Quick add is showing its "Added" confirmation (keys do nothing then, except Esc).
    var quickAddIsConfirming = false
    /// Quick add is suggesting Reminders lists for a "#list" being typed (Tab takes the first,
    /// Esc hides them). Set by the quick add view.
    var quickAddSuggestsLists = false

    /// ⌘L opened the island on Notes: the note should get the cursor. A flag, not a one-off
    /// signal, because the Notes page only exists once the island has opened; it clears it on taking it.
    @Published var notesWantsCursor = false
    /// On a full-screen desktop, the pill's full-screen twin is showing (not the normal window).
    /// Each window has its own copy of the pages; only the copy on screen takes the cursor.
    @Published var twinIsShowing = false

    private var hudTimer: Timer?
    private var hoverTimer: Timer?
    private var collapseTimer: Timer?
    /// Watches whether the to-do list is long enough for the bigger island.
    private var todoCountWatch: AnyCancellable?
    private var trayWatch: AnyCancellable?

    /// Files being dragged toward this island (set by the controller while a Finder drag is near).
    @Published private(set) var fileDrag: FileDrag?

    /// The open island has the tray area under its page: the tray is shown and holding something,
    /// or files are being dragged over it (the drop box takes its place).
    var trayArea: Bool {
        guard Pref.bool(Pref.trayEnabled) else { return false }
        if fileDrag != nil { return true }
        let tray = TrayStore.shared
        return tray.isShown && !tray.items.isEmpty
    }
    private var lastTrayArea = false

    init() {
        // The tray showing or hiding changes the open island's height.
        trayWatch = TrayStore.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.trayChanged() } }
        // More than 2 to-dos: the list gets the bigger island, so they're all in view at once.
        todoCountWatch = RemindersStore.shared.$items
            .map { $0.count > Self.shortTodoListLimit }
            .removeDuplicates()
            .sink { [weak self] _ in
                // $items fires before the new list is stored, so look again on the next turn.
                DispatchQueue.main.async { self?.recompute() }
            }
    }

    private func trayChanged() {
        let area = trayArea
        objectWillChange.send()
        guard area != lastTrayArea else { return }
        lastTrayArea = area
        // The island changes height: text boxes wait for it to settle (see `isSettled`).
        if isExpanded { unsettle() }
    }

    /// The controller saw a file drag come near (or leave, with nil).
    func setFileDrag(_ drag: FileDrag?) {
        guard drag != fileDrag else { return }
        fileDrag = drag
        recompute()
        trayChanged()
    }

    /// The pointer is over the drop target, or left it.
    func setFileDragOver(_ over: Bool) {
        guard var d = fileDrag, d.over != over else { return }
        d.over = over
        fileDrag = d
    }

    /// Files dropped on the island go into the tray: all of them, or none if they don't fit.
    /// The tray stays hidden; dropped on the closed island, the indicator says what it holds.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard Pref.bool(Pref.trayEnabled), !isShowingSettings, !providers.isEmpty else { return false }
        let tray = TrayStore.shared
        tray.prune()
        let fromClosed = !isExpanded
        guard TrayText.fits(adding: providers.count, held: tray.items.count) else {
            LedgeLog.shared.write("tray: \(providers.count) dropped, doesn't fit (holding \(tray.items.count))")
            setFileDrag(nil)
            if fromClosed { show(.tray(text: "Tray is full · holds \(TrayText.limit)", full: true)) }
            return false
        }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await Self.loadFileURL(p) { urls.append(url) }
            }
            let added = tray.add(urls)
            self.setFileDrag(nil)
            if fromClosed {
                show(.tray(text: added ? tray.holdingText : "Tray is full · holds \(TrayText.limit)", full: !added))
            }
        }
        return true
    }

    nonisolated private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
        }
    }

    /// ⌃⌥F: shows or hides the tray under the open page. With the island closed, it opens on
    /// your last page with the tray showing. An empty tray just says so.
    func toggleTray() {
        guard Pref.bool(Pref.trayEnabled), !isNoteEnlarged else { return }
        let tray = TrayStore.shared
        tray.prune()
        if tray.items.isEmpty {
            if !isExpanded { show(.tray(text: TrayText.empty, full: false)) }
            return
        }
        if isShowingSettings { closeSettings() }
        if isExpanded {
            tray.isShown.toggle()
        } else {
            tray.isShown = true
            expand(force: true)
        }
    }

    /// Up to this many to-dos fit the normal open island; more get the bigger one.
    static let shortTodoListLimit = 2

    /// The Calendar page shows the to-do list (not quick add or one to-do) with more than 2 to-dos.
    private var showsLongTodoList: Bool {
        page == .calendar && calendarMode == .todos && !isQuickAdding && openTodoID == nil
            && RemindersStore.shared.items.count > Self.shortTodoListLimit
    }

    /// ⌘L from anywhere: opens the island where you left off, or closes it when it's open.
    /// On the Notes page the cursor goes straight into the note.
    func toggleFromShortcut() {
        if isNoteEnlarged { closeEnlargedNote(); return }
        if isShowingSettings { closeSettings(); return }
        if isExpanded { close(); return }
        expand(force: true)
        guard isExpanded, page == .notes else { return }
        beginNotesTyping()
        notesWantsCursor = true
    }

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

    // MARK: Window switcher

    /// The window switcher, while it's showing: every window, which one is chosen, and how it's drawn.
    struct SwitcherState: Equatable {
        var windows: [SwitcherWindow]
        var selected: Int
        var style: SwitcherStyle
        var size: CGSize
    }
    @Published private(set) var switcher: SwitcherState?
    /// Goes up each time new window previews come in (the switcher redraws them).
    @Published var switcherPreviews = 0
    /// A window was clicked in the switcher.
    var onSwitcherPick: (() -> Void)?

    /// Opens the switcher with these windows. Like Windows' Alt+Tab, the one after the window
    /// you're in is chosen first, so a quick tap flips between your last two.
    func showSwitcher(_ windows: [SwitcherWindow], style: SwitcherStyle) {
        closeEnlargedNote()
        if isShowingSettings { closeSettings() }
        if isExpanded { close() }
        let size = SwitcherLayout.size(style: style, count: windows.count, notch: notch, style: self.style)
        // A switcher is just there the moment you press its keys: no growing out of the notch.
        snapUntil = Date().addingTimeInterval(0.1)
        switcher = SwitcherState(windows: windows, selected: windows.count > 1 ? 1 : 0, style: style, size: size)
        recompute()
    }

    /// Fresh window titles, once they've been read (the switcher shows first, with last time's).
    func updateSwitcherTitles(_ titles: [CGWindowID: String]) {
        guard var s = switcher else { return }
        var changed = false
        for i in s.windows.indices {
            if let t = titles[s.windows[i].id], !t.isEmpty, t != s.windows[i].title {
                s.windows[i].title = t
                changed = true
            }
        }
        if changed { switcher = s }
    }

    func moveSwitcher(by step: Int) {
        guard var s = switcher, !s.windows.isEmpty else { return }
        s.selected = (s.selected + step + s.windows.count) % s.windows.count
        switcher = s
    }

    /// Clicking a window in the switcher picks it.
    func pickSwitcher(_ index: Int) {
        guard var s = switcher, s.windows.indices.contains(index) else { return }
        s.selected = index
        switcher = s
        onSwitcherPick?()
    }

    /// Closes the switcher; returns the window that was chosen.
    @discardableResult
    func endSwitcher() -> SwitcherWindow? {
        guard let s = switcher else { return nil }
        // And gone the moment you let go.
        snapUntil = Date().addingTimeInterval(0.1)
        switcher = nil
        recompute()
        return s.windows.indices.contains(s.selected) ? s.windows[s.selected] : nil
    }

    // MARK: Enlarged note

    /// The open note is enlarged: shown on its own in a big card in the middle of the screen,
    /// while the island steps aside into the notch.
    @Published private(set) var isNoteEnlarged = false
    /// The card is on its way back up into the island (the island reappears when it arrives).
    private(set) var isReturningNote = false

    enum NoteEnlargeChange { case open, backToIsland, close }
    /// The enlarged note's card: grow out of the island, go back into it, or just close.
    var onNoteEnlarged: ((NoteEnlargeChange) -> Void)?

    /// Until when the island jumps to its new shape instead of animating (the card covers it).
    private(set) var snapUntil = Date.distantPast

    /// The expand button or ⌘E on the Notes page: the note grows out of the island into the
    /// middle of the screen.
    func enlargeNote() {
        guard isExpanded, page == .notes, !isNoteEnlarged else { return }
        LedgeLog.shared.write("notes: enlarged")
        isNoteEnlarged = true
        // The card starts exactly where the open island is, so the island just steps aside
        // underneath it (no closing animation of its own). Not `close()`: you're still typing.
        snapUntil = Date().addingTimeInterval(0.1)
        onNoteEnlarged?(.open)
        isExpanded = false
        recompute()
        notesWantsCursor = true
        beginNotesTyping()
    }

    /// Esc, ⌘E or the shrink button: the card shrinks back up into the island, which then opens
    /// on the note at its normal size (see `finishReturningNote`).
    func shrinkNote() {
        guard isNoteEnlarged else { return }
        LedgeLog.shared.write("notes: back to the island")
        isNoteEnlarged = false
        isReturningNote = true
        onNoteEnlarged?(.backToIsland)
    }

    /// The card has reached the island's shape: the island takes over, open on the note.
    func finishReturningNote() {
        guard isReturningNote else { return }
        isReturningNote = false
        snapUntil = Date().addingTimeInterval(0.1)
        if pages.contains(.notes) { page = .notes }
        isExpanded = true
        recompute()
        onOpen?()
        notesWantsCursor = true
        beginNotesTyping()
    }

    /// ⌘L (or another way of leaving): the enlarged note closes all the way.
    func closeEnlargedNote() {
        guard isNoteEnlarged else { return }
        LedgeLog.shared.write("notes: enlarged note closed")
        isNoteEnlarged = false
        onNoteEnlarged?(.close)
        isTyping = false
        onEndTyping?()
        recompute()
    }

    func clicked() {
        guard !isShowingSettings else { return } // settings has its own close button
        // The island while the note is enlarged: the note comes back into it.
        if isNoteEnlarged { shrinkNote(); return }
        if isExpanded {
            // Clicks never close the open island, inside or outside: only ⌘L and Esc do.
            return
        } else {
            expand(force: true)
        }
    }

    /// Closes the island (Esc in Notes, or a click on Music/Calendar).
    func close() {
        if isQuickAdding { resume = .quickAdd(quickAddKind) }
        else if let id = openTodoID { resume = .todo(id) }
        isQuickAdding = false
        openTodoID = nil
        isTyping = false
        onEndTyping?()
        isExpanded = false
        recompute()
    }

    /// Two-finger swipe while open: fingers left = next page, right = previous.
    /// Called when Ledge hands you over to another app (so it doesn't bring back the previous one).
    var onHandOff: (() -> Void)?

    /// You opened something in Notes or Reminders: the island closes and stays out of the way.
    /// (It won't reopen on that note or to-do next time, and the app you were in before isn't
    /// brought back over the one just opened.)
    func closeForHandOff() {
        onHandOff?()
        close()
        resume = nil
    }

    /// ⌘1–⌘4: the page with that number, counting the dots from the left.
    func showPage(number: Int) {
        let available = pages
        guard isExpanded, number >= 1, number <= available.count else { return }
        show(page: available[number - 1])
        // Picked from the keyboard, so you're about to type: the cursor goes into the note.
        if page == .notes {
            beginNotesTyping()
            notesWantsCursor = true
        }
    }

    /// The Notes page's text box got the cursor: take the keyboard like quick add does.
    func beginNotesTyping() {
        if !isTyping { LedgeLog.shared.write("notes: typing starts (page \(page.rawValue))") }
        isTyping = true
        onBeginTyping?()
    }

    func swipePage(forward: Bool) {
        guard isExpanded, !isQuickAdding, openTodoID == nil, let next = IslandPage.step(from: page, forward: forward, in: pages) else { return }
        show(page: next)
    }

    func show(page newPage: IslandPage) {
        guard newPage != page else { return }
        if isQuickAdding { endQuickAdd() }
        if openTodoID != nil { closeTodo() }
        if page == .notes { isTyping = false; onEndTyping?() }
        page = newPage
    }

    /// The + on the Calendar page: turns it into one line to type an event into.
    func beginQuickAdd() {
        guard isExpanded, page == .calendar, !isQuickAdding else { return }
        openTodoID = nil
        quickAddKind = calendarMode
        quickAddShowsNotes = false
        quickAddIsConfirming = false
        isQuickAdding = true
        isTyping = true
        onBeginTyping?()
    }

    /// ⌃⌥E / ⌃⌥T from anywhere: opens the island on the Calendar page, straight into quick add
    /// for an event or a to-do.
    func openQuickAdd(_ kind: CalendarMode) {
        closeEnlargedNote()
        guard pages.contains(.calendar) else { return }
        if isShowingSettings { closeSettings() }
        if isQuickAdding {
            if quickAddKind == kind { onBeginTyping?(); return }
            endQuickAdd()
        }
        if openTodoID != nil { closeTodo() }
        if page == .notes { isTyping = false; onEndTyping?() }
        page = .calendar
        calendarMode = kind
        if !isExpanded {
            isExpanded = true
            recompute()
            onOpen?()
        }
        beginQuickAdd()
    }

    /// Esc on the quick add line: cancel, and forget what was typed.
    func cancelQuickAdd() {
        guard isQuickAdding else { return }
        drafts[quickAddKind] = nil
        endQuickAdd()
    }

    /// What you typed in quick add, kept if it closes by accident (a click elsewhere), so it's
    /// still there next time. Cleared when it saves or when you cancel with Esc.
    private var drafts: [CalendarMode: QuickAddDraft] = [:]
    func draft(for kind: CalendarMode) -> QuickAddDraft { drafts[kind] ?? QuickAddDraft() }
    /// Keys typed in the moment before the quick add line has the cursor.
    func appendToDraft(_ chars: String) {
        var d = draft(for: quickAddKind)
        if quickAddShowsNotes { d.notes += chars } else { d.text += chars }
        drafts[quickAddKind] = d
    }

    func keepDraft(_ draft: QuickAddDraft, for kind: CalendarMode) {
        drafts[kind] = draft.text.isEmpty && draft.notes.isEmpty ? nil : draft
    }

    /// Esc, or a moment after saving: back to the event list.
    func endQuickAdd() {
        guard isQuickAdding else { return }
        resume = nil
        isQuickAdding = false
        isTyping = false
        onEndTyping?()
    }

    /// Click a to-do: the right side shows it with its steps. Esc or Back returns to the list.
    func openTodo(_ id: String) {
        guard isExpanded, page == .calendar, !isQuickAdding else { return }
        openTodoID = id
        isTyping = true
        onBeginTyping?()
    }

    func closeTodo() {
        guard openTodoID != nil else { return }
        resume = nil
        openTodoID = nil
        isTyping = false
        onEndTyping?()
    }

    func show(_ newHUD: HUD) {
        hud = newHUD
        hudTimer?.invalidate()
        let seconds = Self.duration(of: newHUD)
        hudTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hud = nil
                self?.recompute()
            }
        }
        recompute()
    }

    /// How long each pop stays.
    static func duration(of hud: HUD) -> TimeInterval {
        switch hud {
        case .volume, .brightness: return 1.5
        case .charging, .lowBattery: return 2.6
        case .timerDone: return 6
        case .awakeOn, .awakeOff: return 1.8
        case .pomodoro: return 4
        case .tray(_, let full): return full ? 2.4 : 1.6
        }
    }

    func setArtwork(image: NSImage?, tint newTint: Color) {
        artwork = image
        tint = newTint
    }

    func openSettings() {
        closeEnlargedNote()
        guard !isShowingSettings else { return }
        isQuickAdding = false
        openTodoID = nil
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
    /// Debug only (the animation recorder).
    func debugOpen() { expand(force: true) }
    func debugSetPage(_ p: IslandPage) { if pages.contains(p) { page = p } }

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
        if s.isOpen { lastOpenShape = s }
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
        let title = musicShowing ? (media.title ?? "") : timerTitle
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
        // While the note is enlarged (or on its way back), or the switcher shows, hovering the
        // notch doesn't open the island.
        guard !isNoteEnlarged, !isReturningNote, switcher == nil else { return }
        guard force || isHovering || !Pref.bool(Pref.openOnHover) else { return }
        guard !isExpanded, !pages.isEmpty else { return }
        // Always open where you left off: the same page, and quick add or the to-do you had open.
        if !pages.contains(page) { page = pages.first ?? .calendar }
        isExpanded = true
        recompute()
        onOpen?()
        if let r = resume, page == .calendar {
            resume = nil
            switch r {
            case .quickAdd(let kind):
                calendarMode = kind
                beginQuickAdd()
            case .todo(let id):
                calendarMode = .todos
                openTodo(id)
            }
        }
    }

    /// Once open, the island stays open until you press ⌘L or Esc, so moving the
    /// pointer away by mistake never closes it or loses what you're typing.
    private func collapseIfIdle() {}

    private func recompute() {
        if !pages.isEmpty && !pages.contains(page) { page = pages.first! }
        if isExpanded && pages.isEmpty { isExpanded = false }
        let next: IslandShape
        if switcher != nil {
            next = .switcher
        } else if isShowingSettings {
            next = .settings
        } else if isExpanded {
            // Bigger for notes: the Notes page (tallest), a to-do's notes, and quick add notes.
            if page == .notes { next = .expandedNotes }
            else if openTodoID != nil || (isQuickAdding && quickAddShowsNotes) { next = .expandedTall }
            // A long to-do list gets the bigger island too, so every to-do shows without scrolling.
            else if showsLongTodoList { next = .expandedTall }
            else { next = .expanded }
        } else if fileDrag != nil {
            next = .drop
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
        if next.isOpen && next != lastOpenShape { lastOpenShape = next }
        if next != shape {
            let old = IslandLayout.size(for: shape, notch: notch, style: style, compactWidth: compactWidth, switcherSize: switcher?.size)
            let new = IslandLayout.size(for: next, notch: notch, style: style, compactWidth: compactWidth, switcherSize: switcher?.size)
            growing = new.width * new.height >= old.width * old.height
            let p = NSEvent.mouseLocation
            LedgeLog.shared.write("island: \(shape) -> \(next) page \(page.rawValue) (pointer \(Int(p.x)),\(Int(p.y)) buttons \(NSEvent.pressedMouseButtons) hover \(isHovering) typing \(isTyping) playing \(media.isPlaying))")
            shape = next
            unsettle()
        }
    }

    /// The island is about to move: text boxes are drawn as plain text until it settles.
    private func unsettle() {
        isSettled = false
        settleTimer?.invalidate()
        // Longer than the slowest open or resize in any animation style.
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isSettled = true }
        }
    }
}

struct QuickAddDraft: Equatable {
    var text = ""
    var notes = ""
}

/// The Calendar page shows your events or your to-dos.
enum CalendarMode: String {
    case events, todos

    static let key = "calendarMode"
    static var saved: CalendarMode {
        UserDefaults.standard.string(forKey: key).flatMap(CalendarMode.init(rawValue:)) ?? .events
    }
}

/// Keys quick add handles, seen by the island controller before the text fields take them.
enum QuickAddKey {
    /// ⌘N: switch between the title line and the notes view.
    case toggleNotes
    /// Esc: from the notes view back to the title line.
    case back
    /// ⌘return: save from anywhere (return makes a new line in notes).
    case save
    /// Characters typed before the text field has the cursor (right after ⌘T or ⌃⌥T).
    case typeAhead(String)
    /// Tab while lists are suggested: take the first one.
    case acceptListSuggestion
    /// Esc while lists are suggested: hide them (a second Esc cancels quick add).
    case hideListSuggestions
}

enum MediaCommand {
    case toggle, next, previous
    case seek(Double)
}
