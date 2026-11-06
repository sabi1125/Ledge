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
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lastShowOthers: Bool?

    init(media: MediaController, calendar: CalendarStore, notes: NotesStore, openSettings: @escaping () -> Void) {
        self.media = media
        self.calendar = calendar
        self.notes = notes
        self.openSettings = openSettings
    }

    var models: [IslandModel] { controllers.values.map(\.model) }

    func start() {
        media.islands = { [weak self] in self?.models ?? [] }
        sync()
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
                let controller = IslandController(displayID: id, model: model, calendar: calendar, notes: notes,
                                                  openSettings: openSettings)
                controllers[id] = controller
                controller.start(on: screen)
                media.sync(model)
                LedgeLog.shared.write("islands: added \(model.style == .notch ? "notch island" : "floating pill") on display \(id)")
            }
        }
        for (id, controller) in controllers where !present.contains(id) {
            controller.stop()
            controllers[id] = nil
            LedgeLog.shared.write("islands: removed island from display \(id)")
        }
    }

    /// The island on the screen you're using (where the pointer is), for indicators.
    func islandUnderPointer() -> IslandModel? {
        let p = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.contains(point: p) }) { return c.model }
        return controllers.values.first(where: { $0.model.style == .notch })?.model ?? controllers.values.first?.model
    }
}
