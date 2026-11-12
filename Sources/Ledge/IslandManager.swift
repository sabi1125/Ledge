import AppKit
import Combine
import LedgeCore

/// Keeps one island per screen: the notch island on the MacBook's display, and a floating
/// pill on every other display (unless turned off in settings). Islands are added and
/// removed as screens are plugged in, unplugged, or the lid is closed.
@MainActor
final class IslandManager {
    private var controllers: [CGDirectDisplayID: IslandController] = [:]
    private let media: MediaController
    private let calendar: CalendarStore
    private let notes: NotesStore
    private let timer: TimerStore
    private let awake: AwakeStore
    private let settings: SettingsState
    private let updater: Updater
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lastShowOthers: Bool?
    private let fullScreen = FullScreenWatcher()

    init(media: MediaController, calendar: CalendarStore, notes: NotesStore, timer: TimerStore,
         awake: AwakeStore, settings: SettingsState, updater: Updater, openSettings: @escaping () -> Void) {
        self.media = media
        self.timer = timer
        self.awake = awake
        self.settings = settings
        self.updater = updater
        self.calendar = calendar
        self.notes = notes
        self.openSettings = openSettings
    }

    var models: [IslandModel] { controllers.values.map(\.model) }

    func start() {
        media.islands = { [weak self] in self?.models ?? [] }
        sync()
        // A running or paused timer shows in every island's compact view.
        timer.$live
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] live in
                self?.models.forEach { $0.timerTitle = live?.title ?? "Timer"; $0.timerActive = live != nil }
            }
            .store(in: &cancellables)
        // Settings changes (pages switched on or off) reshape every island.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.models.forEach { $0.settingsChanged() } }
            .store(in: &cancellables)
        // Keep each pill on its screen's normal desktops only (see FullScreenWatcher).
        fullScreen.onChange = { [weak self] in self?.applyFullScreen() }
        fullScreen.start()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        // The "Show Ledge on other displays" setting.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.lastShowOthers != Pref.bool(Pref.showOnOtherDisplays) else { return }
                self.sync()
            }
            .store(in: &cancellables)
    }

    func sync() {
        let showOthers = Pref.bool(Pref.showOnOtherDisplays)
        lastShowOthers = showOthers
        var present = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = IslandController.displayID(of: screen) else { continue }
            guard IslandController.hasNotch(screen) || showOthers else { continue }
            present.insert(id)
            if let existing = controllers[id] {
                existing.layout(on: screen)
            } else {
                let model = IslandModel()
                model.onCommand = { [weak self] in self?.media.send($0) }
                model.timerTitle = timer.live?.title ?? "Timer"
                model.timerActive = timer.live != nil
                // Only one island is open at a time: opening one closes the others (otherwise an
                // island left open on another screen could take your keys).
                model.onOpen = { [weak self, weak model] in
                    Haptics.openTick()
                    if let model { self?.closeOthers(than: model) }
                }
                let controller = IslandController(displayID: id, model: model, calendar: calendar, notes: notes,
                                                  timer: timer, awake: awake, settings: settings, updater: updater,
                                                  openSettings: openSettings)
                controllers[id] = controller
                controller.start(on: screen)
                if model.style == .floating { apply(fullScreenRulesTo: controller) }
                media.sync(model)
                LedgeLog.shared.write("islands: added \(model.style == .notch ? "notch island" : "floating pill") on display \(id)")
            }
        }
        for (id, controller) in controllers where !present.contains(id) {
            controller.stop()
            controllers[id] = nil
            LedgeLog.shared.write("islands: removed island from display \(id)")
        }
        fullScreen.isNeeded = controllers.values.contains { $0.model.style == .floating }
    }

    private func applyFullScreen() {
        for c in controllers.values where c.model.style == .floating { apply(fullScreenRulesTo: c) }
    }

    /// Pins a pill to its screen's normal desktops, so it's simply absent from full-screen ones.
    /// If pinning isn't available, it hides while its screen shows a full-screen desktop instead.
    private func apply(fullScreenRulesTo c: IslandController) {
        if Spaces.canPin, let spaces = Spaces.spaces(for: c.displayID, in: fullScreen.spaces) {
            c.keepOff(fullScreen: spaces)
        } else {
            c.setSuppressed(fullScreen.fullScreenDisplays.contains(c.displayID))
        }
    }

    /// Opens settings in the island on the screen you're using (the MacBook's notch if unsure).
    func showSettings() {
        let p = NSEvent.mouseLocation
        let target = controllers.values.first { $0.contains(point: p) && !$0.isSuppressed }
            ?? controllers.values.first { $0.model.style == .notch }
            ?? controllers.values.first
        for c in controllers.values where c !== target { c.model.closeSettings() }
        target?.revealForShortcut()
        target?.model.openSettings()
    }

    /// Debug only: reveals every floating pill that's on a full-screen desktop.
    func debugReveal() {
        controllers.values.filter { $0.model.style == .floating }.forEach { $0.debugReveal() }
    }

    /// Debug only: plays a style's open and close on the notch while recording it.
    func debugRecord(style: String, to dir: String) {
        // "scene:<name>" or "scene:<name>@pill" plays one transition (see `debugScene`).
        if style.hasPrefix("scene:") {
            var name = String(style.dropFirst(6))
            let pill = name.hasSuffix("@pill")
            if pill { name = String(name.dropLast(5)) }
            let want: IslandStyle = pill ? .floating : .notch
            guard let c = controllers.values.first(where: { $0.model.style == want }) else { return }
            debugScene(name, on: c, to: dir)
            return
        }
        guard let c = controllers.values.first(where: { $0.model.style == .notch }) ?? controllers.values.first else { return }
        if style == "hud" {
            // A volume pop, as if the key was pressed.
            c.recordFrames(to: dir, seconds: 2.4, every: 0.025)
            c.model.show(.volume(level: 0.62, muted: false))
            return
        }
        UserDefaults.standard.set(style, forKey: IslandAnimation.key)
        c.recordFrames(to: dir)
        c.model.previewAnimation()
    }

    /// Debug only: sets the island up, then records one transition at 40 frames a second.
    /// open, close, page, tonotes, fromnotes, quickadd, quicknotes, settings, settingsclose, hud, compacthud
    private func debugScene(_ name: String, on c: IslandController, to dir: String) {
        let m = c.model
        IslandRootView.logMoves = true
        func record(_ seconds: TimeInterval = 1.4, _ action: @escaping () -> Void) {
            c.recordFrames(to: dir, seconds: seconds, every: 0.025)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: action)
        }
        func reset(page: IslandPage?, then: @escaping () -> Void) {
            m.closeEnlargedNote()
            m.closeSettings()
            m.close()
            if let page { m.debugSetPage(page) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: then)
        }
        func opened(page: IslandPage, then: @escaping () -> Void) {
            reset(page: page) {
                m.debugOpen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: then)
            }
        }
        switch name {
        case "open": reset(page: .calendar) { record { m.debugOpen() } }
        case "close": opened(page: .calendar) { record { m.close() } }
        case "opennotes": reset(page: .notes) { record { m.debugOpen() } }
        case "closenotes": opened(page: .notes) { record { m.close() } }
        case "page": opened(page: .calendar) { record { m.show(page: .timer) } }
        case "tonotes": opened(page: .timer) { record { m.show(page: .notes) } }
        case "fromnotes": opened(page: .notes) { record { m.show(page: .timer) } }
        case "quickadd": opened(page: .calendar) { record { m.calendarMode = .events; m.beginQuickAdd() } }
        case "quickaddend": opened(page: .calendar) {
            m.calendarMode = .events; m.beginQuickAdd()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { record { m.cancelQuickAdd() } }
        }
        case "quicknotes": opened(page: .calendar) {
            m.calendarMode = .events; m.beginQuickAdd()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { record { m.quickAddShowsNotes = true } }
        }
        case "mode": opened(page: .calendar) { record { m.calendarMode = m.calendarMode == .events ? .todos : .events } }
        case "settings": reset(page: nil) { record(1.6) { m.openSettings() } }
        case "settingsclose": reset(page: nil) {
            m.openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { record { m.closeSettings() } }
        }
        case "hud": reset(page: nil) { record(2.2) { m.show(.volume(level: 0.62, muted: false)) } }
        case "enlarge": opened(page: .notes) {
            m.enlargeNote()
            c.recordFrames(to: dir + "-card", seconds: 0.9, every: 0.03, note: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { c.debugCaptureNote(to: dir + "-note.png") }
        }
        case "shrink": opened(page: .notes) {
            m.enlargeNote()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                c.recordFrames(to: dir + "-card", seconds: 0.6, every: 0.03, note: true)
                record { m.shrinkNote() }
            }
        }
        default: break
        }
    }

    /// Plays the open-and-close animation on the MacBook's notch (or the first island).
    func previewAnimation() {
        (controllers.values.first { $0.model.style == .notch } ?? controllers.values.first)?.model.previewAnimation()
    }

    /// The island on the screen you're using (where the pointer is), for indicators.
    /// Alerts you shouldn't miss go to every screen (and show even over full-screen apps).
    func alertEverywhere(_ hud: HUD) {
        for c in controllers.values { c.alert(hud) }
    }

    private func closeOthers(than model: IslandModel) {
        for c in controllers.values where c.model !== model {
            if c.model.isShowingSettings { c.model.closeSettings() }
            if c.model.isExpanded { c.model.close() }
        }
    }

    /// ⌃⌥E / ⌃⌥T: quick add on the island you're using (under the pointer, else the notch).
    func quickAdd(_ kind: CalendarMode) {
        let p = NSEvent.mouseLocation
        let target = controllers.values.first { $0.contains(point: p) && !$0.isSuppressed }
            ?? controllers.values.first { $0.model.style == .notch }
            ?? controllers.values.first
        for c in controllers.values where c !== target && c.model.isExpanded { c.model.close() }
        target?.revealForShortcut()
        target?.model.openQuickAdd(kind)
    }

    /// ⌘L: opens the island on the screen you're pointing at (or the MacBook screen), or closes it.
    func toggleFromShortcut() {
        let p = NSEvent.mouseLocation
        let target = controllers.values.first { $0.contains(point: p) && !$0.isSuppressed }
            ?? controllers.values.first { $0.model.style == .notch }
            ?? controllers.values.first
        for c in controllers.values where c !== target && c.model.isExpanded { c.model.close() }
        // Opening (not closing) on a full-screen desktop: the hidden pill comes in first.
        if target?.model.isExpanded == false { target?.revealForShortcut() }
        target?.model.toggleFromShortcut()
    }

    func islandUnderPointer() -> IslandModel? {
        let p = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.contains(point: p) }) { return c.model }
        return controllers.values.first(where: { $0.model.style == .notch })?.model ?? controllers.values.first?.model
    }
}
