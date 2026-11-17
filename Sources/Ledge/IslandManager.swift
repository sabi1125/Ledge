import AppKit
import Combine
import SwiftUI
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
        // Meetings: a countdown, then a pill with Join (looked at again whenever the calendar changes).
        calendar.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkMeetings() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.lastMeetingPref != Pref.bool(Pref.meetingAlerts) else { return }
                self.lastMeetingPref = Pref.bool(Pref.meetingAlerts)
                self.checkMeetings()
            }
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
        // Lid closed (only external displays): with no notch to sit in, the main display gets the
        // pill even when "Show Ledge on other displays" is off, so there's always an island.
        let screens = NSScreen.screens
        let noNotch = !screens.contains(where: IslandController.hasNotch)
        let fallback = noNotch && !showOthers ? (NSScreen.main ?? screens.first) : nil
        var wanted: [(CGDirectDisplayID, NSScreen)] = []
        for screen in screens {
            guard let id = IslandController.displayID(of: screen) else { continue }
            guard IslandController.hasNotch(screen) || showOthers || screen === fallback else { continue }
            wanted.append((id, screen))
        }
        let present = Set(wanted.map(\.0))
        // Islands of screens that are gone go first, so they let go of their shortcuts before
        // a new island takes them.
        for (id, controller) in controllers where !present.contains(id) {
            if controller === switcherIsland {
                switcherIsland = nil
                onSwitcherClicked?() // the keys go back to normal
            }
            controller.stop()
            controllers[id] = nil
            LedgeLog.shared.write("islands: removed island from display \(id)")
        }
        for (id, screen) in wanted {
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
                wireMeetings(model)
                model.meeting = models.compactMap(\.meeting).first
                LedgeLog.shared.write("islands: added \(model.style == .notch ? "notch island" : "floating pill") on display \(id)")
            }
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
        case _ where name.hasPrefix("switch") && !name.hasPrefix("switcher"):
            // "switch" / "switch3": opens the switcher, moves to that window (2nd by default), switches.
            let steps = Int(name.dropFirst(6)) ?? 2
            _ = switcher(.open)
            for _ in 0..<max(0, steps - 2) { _ = switcher(.next) }
            if let s = switcherIsland?.model.switcher {
                LedgeLog.shared.write("switcher: list \(s.windows.map(\.appName)), chose \(s.windows[s.selected].appName)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { _ = self.switcher(.commit) }
        case _ where name.hasPrefix("switcher-"):
            // "switcher-strip": open the switcher in that style, step once, then close it.
            let style = SwitcherStyle(rawValue: String(name.dropFirst(9))) ?? .strip
            reset(page: nil) {
                let windows = WindowCatalog.shared.windows(allDesktops: true)
                LedgeLog.shared.write("switcher: \(windows.count) windows: \(windows.prefix(8).map { "\($0.appName) · \($0.title)" })")
                record(1.6) { m.showSwitcher(windows, style: style) }
                WindowCatalog.shared.refreshPreviews(of: windows) { _ in m.switcherPreviews += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { m.moveSwitcher(by: 1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { m.endSwitcher() }
            }
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
    // MARK: Meetings

    /// Meetings you dismissed or joined (no more heads-up for them).
    private var meetingsDone = Set<String>()
    private var meetingTimer: Timer?
    /// The meeting whose pill already played its sound.
    private var meetingChimed: String?
    private var lastMeetingPref = Pref.bool(Pref.meetingAlerts)

    /// Looks at the calendar: every second while a meeting is close, otherwise less often.
    private func checkMeetings() {
        meetingTimer?.invalidate()
        let now = Date()
        let items = calendar.events + (sampleMeeting.map { [$0] } ?? [])
        let events = items.map {
            MeetingSchedule.Event(id: $0.id, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, declined: $0.declined)
        }
        var notice: IslandModel.MeetingNotice?
        if Pref.bool(Pref.meetingAlerts) || sampleMeeting != nil,
           let (id, phase) = MeetingSchedule.current(events, now: now, dismissed: meetingsDone),
           let item = items.first(where: { $0.id == id }) {
            notice = .init(id: id, title: item.title, start: item.start, color: item.color,
                           joinURL: item.joinURL, eventID: item.eventID, phase: phase)
        }
        if notice?.phase == .alert, let id = notice?.id, meetingChimed != id {
            meetingChimed = id
            LedgeLog.shared.write("meeting: heads-up for an event starting \(MeetingSchedule.whenText(start: notice!.start, now: now))")
            NSSound(named: "Purr")?.play()
            Haptics.alert()
        }
        for m in models where m.meeting != notice { m.meeting = notice }
        let wait = MeetingSchedule.nextCheck(events, now: now)
        meetingTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMeetings() }
        }
    }

    /// "Try it" in settings: a sample meeting a little over a minute away, so the countdown shows
    /// for a few seconds and then the pill drops down.
    private var sampleMeeting: CalendarItem?

    func previewMeeting() {
        for c in controllers.values { c.model.closeSettings() }
        let start = Date().addingTimeInterval(MeetingSchedule.alertLead + 6)
        sampleMeeting = CalendarItem(id: "sample-meeting", title: "Sample meeting", start: start,
                                     end: start.addingTimeInterval(30 * 60), isAllDay: false,
                                     color: Color(red: 0.88, green: 0.35, blue: 0.61), joinURL: nil)
        meetingsDone.remove("sample-meeting")
        meetingChimed = nil
        // A beat later, once settings has closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.checkMeetings() }
    }

    private func finishMeeting(open url: URL?) {
        guard let notice = models.compactMap(\.meeting).first else { return }
        meetingsDone.insert(notice.id)
        if notice.id == sampleMeeting?.id { sampleMeeting = nil }
        if let url { NSWorkspace.shared.open(url) }
        checkMeetings()
    }

    private func wireMeetings(_ model: IslandModel) {
        model.onMeetingJoin = { [weak self, weak model] in
            guard let self, let notice = model?.meeting else { return }
            if let url = notice.joinURL {
                self.finishMeeting(open: url)
            } else {
                if let id = notice.eventID { self.calendar.openInCalendar(id) }
                self.finishMeeting(open: nil)
            }
        }
        model.onMeetingOpen = { [weak self, weak model] in
            guard let id = model?.meeting?.eventID else { return }
            self?.calendar.openInCalendar(id)
        }
        model.onMeetingDismiss = { [weak self] in self?.finishMeeting(open: nil) }
    }

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

    // MARK: Window switcher

    /// The island showing the switcher right now.
    private weak var switcherIsland: IslandController?
    /// Called when a click in the switcher picked a window (the keys go back to normal).
    var onSwitcherClicked: (() -> Void)?

    /// The switcher's keys: open it, move through it, switch, or cancel. Returns true if handled.
    /// Keys that came in while the switcher was still being opened (a very quick tap and release).
    private var switcherOpening = false
    private var switcherEarly: [SwitcherKeys.Action] = []

    func switcher(_ action: SwitcherKeys.Action) -> Bool {
        // The keys arrive inside the system's key tap, which must answer at once: only decide here,
        // and open the switcher a moment later (gathering windows can wait on slow apps).
        if action == .open {
            guard Pref.bool(Pref.switcherOn), !controllers.isEmpty else { return false }
            switcherOpening = true
            switcherEarly = []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.openSwitcher()
                self.switcherOpening = false
                // A quick tap and release: Tab presses and the switch, in order.
                let early = self.switcherEarly
                self.switcherEarly = []
                for a in early { _ = self.switcher(a) }
            }
            return true
        }
        if switcherOpening {
            switcherEarly.append(action)
            return true
        }
        return openSwitcher(action)
    }

    private func openSwitcher(_ action: SwitcherKeys.Action = .open) -> Bool {
        switch action {
        case .open:
            let p = NSEvent.mouseLocation
            guard let target = controllers.values.first(where: { $0.contains(point: p) && !$0.isSuppressed })
                ?? controllers.values.first(where: { $0.model.style == .notch }) ?? controllers.values.first else { return false }
            let started = Date()
            let windows = WindowCatalog.shared.windows(allDesktops: Pref.bool(Pref.switcherAllDesktops))
            let listed = Date().timeIntervalSince(started)
            let style = SwitcherStyle(rawValue: UserDefaults.standard.string(forKey: SwitcherStyle.key) ?? "") ?? .strip
            for c in controllers.values where c !== target {
                if c.model.isExpanded { c.model.close() }
            }
            target.revealForShortcut(instant: true)
            target.model.onSwitcherPick = { [weak self] in
                self?.onSwitcherClicked?()
                _ = self?.switcher(.commit)
            }
            target.model.showSwitcher(windows, style: style)
            switcherIsland = target
            LedgeLog.shared.write("switcher: opened with \(windows.map(\.appName)) (windows in \(Int(listed * 1000)) ms, shown in \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            WindowCatalog.shared.readTitles(for: windows) { [weak target] titles in target?.model.updateSwitcherTitles(titles) }
            if Pref.bool(Pref.switcherPreviews) {
                // Shown at once from last time; fresh ones replace them as they come in.
                WindowCatalog.shared.refreshPreviews(of: windows) { [weak target] _ in target?.model.switcherPreviews += 1 }
            }
            return true
        case .next:
            switcherIsland?.model.moveSwitcher(by: 1)
            return true
        case .previous:
            switcherIsland?.model.moveSwitcher(by: -1)
            return true
        case .commit:
            guard let island = switcherIsland else { return false }
            switcherIsland = nil
            if let window = island.model.endSwitcher() { WindowCatalog.shared.focus(window) }
            return true
        case .cancel:
            switcherIsland?.model.endSwitcher()
            switcherIsland = nil
            return true
        }
    }

    /// ⌃⌥F: the tray on the island you're using (opens it on your last page if it's closed).
    func toggleTray() {
        let p = NSEvent.mouseLocation
        let target = controllers.values.first { $0.contains(point: p) && !$0.isSuppressed }
            ?? controllers.values.first { $0.model.style == .notch }
            ?? controllers.values.first
        for c in controllers.values where c !== target && c.model.isExpanded { c.model.close() }
        if target?.model.isExpanded == false, !TrayStore.shared.items.isEmpty { target?.revealForShortcut() }
        target?.model.toggleTray()
    }

    func islandUnderPointer() -> IslandModel? {
        let p = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.contains(point: p) }) { return c.model }
        return controllers.values.first(where: { $0.model.style == .notch })?.model ?? controllers.values.first?.model
    }
}
