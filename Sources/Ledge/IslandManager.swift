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
        timer.$countdown
            .map(\.isActive)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.models.forEach { $0.timerActive = active } }
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
                model.timerActive = timer.countdown.isActive
                model.onOpen = { Haptics.openTick() }
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
        target?.model.openSettings()
    }

    /// Debug only: plays a style's open and close on the notch while recording it.
    func debugRecord(style: String, to dir: String) {
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

    /// Plays the open-and-close animation on the MacBook's notch (or the first island).
    func previewAnimation() {
        (controllers.values.first { $0.model.style == .notch } ?? controllers.values.first)?.model.previewAnimation()
    }

    /// The island on the screen you're using (where the pointer is), for indicators.
    func islandUnderPointer() -> IslandModel? {
        let p = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.contains(point: p) }) { return c.model }
        return controllers.values.first(where: { $0.model.style == .notch })?.model ?? controllers.values.first?.model
    }
}
