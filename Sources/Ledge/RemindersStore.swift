import AppKit
import EventKit
import LedgeCore
import SwiftUI

/// One to-do from the Reminders app, as Ledge shows it.
struct TodoItem: Identifiable, Equatable {
    var id: String
    /// The title without the time guess ("[30m]" is shown separately).
    var title: String
    var minutes: Int?
    /// High priority in Reminders ("!" when typed in Ledge).
    var isMust: Bool
    var listTitle: String
    var listColor: Color
    var due: Date?
    var dueHasTime: Bool
    var created: Date?
    var url: URL?
    var notes: String
    var isDone: Bool
    /// Kept by Ledge (Reminders has no such state).
    var isInProgress: Bool

    var checklist: [ChecklistItem] { Checklist.items(in: notes) }
    var nextStep: ChecklistItem? { checklist.first { !$0.done } }
}

/// A to-do quick add just saved, kept so it can be undone.
struct AddedTodo: Equatable {
    var id: String
    var title: String
    var listTitle: String
    var draft: TodoDraft
}

/// Reads and writes to-dos in the Reminders app (iCloud, On My Mac…), so they show up there
/// and on your iPhone too.
@MainActor
final class RemindersStore: ObservableObject {
    static let shared = RemindersStore()

    enum Access { case notAsked, granted, denied }

    @Published private(set) var access: Access = .notAsked
    /// Every open to-do, in every list: in progress first, then due today or overdue, then no due
    /// date, then upcoming. Musts first within each.
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var doneToday = 0
    /// List names, for matching "#s3" while you type.
    @Published private(set) var listTitles: [String] = []
    @Published private(set) var defaultListTitle = "Reminders"
    /// The to-do quick add just saved, softly highlighted for a moment.
    @Published private(set) var justAddedID: String?

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var justAddedTimer: Timer?
    /// Just ticked off: stays in the list, crossed out, for a moment (with Undo).
    private var lingering: [String: (item: TodoItem, index: Int)] = [:]
    private var inProgress: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "todoInProgress") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "todoInProgress") }
    }

    private init() {
        updateAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keeps "Due today" and "Overdue" current.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
    }

    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] _, error in
            if let error { LedgeLog.shared.write("reminders: access request failed: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateAccess()
                LedgeLog.shared.write("reminders: access \(self.access == .granted ? "granted" : "not granted")")
                self.refresh()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading

    func refresh() {
        updateAccess()
        guard access == .granted else { items = []; doneToday = 0; return }
        let lists = store.calendars(for: .reminder)
        let titles = lists.map(\.title)
        if titles != listTitles { listTitles = titles }
        let fallback = store.defaultCalendarForNewReminders()?.title ?? "Reminders"
        if fallback != defaultListTitle { defaultListTitle = fallback }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let progress = inProgress

        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { [weak self] found in
            let mapped = (found ?? []).map { Self.item(from: $0, inProgress: progress) }
                .sorted { Self.order($0, $1, startOfTomorrow: startOfTomorrow) }
            DispatchQueue.main.async { self?.apply(mapped) }
        }
        store.fetchReminders(matching: store.predicateForCompletedReminders(withCompletionDateStarting: startOfToday, ending: startOfTomorrow, calendars: nil)) { [weak self] found in
            let count = found?.count ?? 0
            DispatchQueue.main.async { if self?.doneToday != count { self?.doneToday = count } }
        }
    }

    private func apply(_ fresh: [TodoItem]) {
        var list = fresh
        // Just-ticked to-dos keep their place for a moment.
        for (id, entry) in lingering.sorted(by: { $0.value.index < $1.value.index }) where !list.contains(where: { $0.id == id }) {
            list.insert(entry.item, at: min(entry.index, list.count))
        }
        if list != items { items = list }
    }

    nonisolated private static func item(from r: EKReminder, inProgress: Set<String>) -> TodoItem {
        let (title, minutes) = TodoTitle.split(r.title ?? "")
        let comps = r.dueDateComponents
        var due: Date?
        if let comps {
            var c = comps
            if c.calendar == nil { c.calendar = Calendar.current }
            due = c.date
        }
        return TodoItem(
            id: r.calendarItemIdentifier,
            title: title.isEmpty ? "Untitled" : title,
            minutes: minutes,
            isMust: r.priority >= 1 && r.priority <= 4,
            listTitle: r.calendar?.title ?? "",
            listColor: Color(nsColor: r.calendar?.color ?? .systemOrange),
            due: due,
            dueHasTime: comps?.hour != nil,
            created: r.creationDate,
            // Reminders' own link field isn't readable by other apps, so a link in the notes counts too.
            url: r.url ?? NoteLinks.first(in: r.notes ?? ""),
            notes: r.notes ?? "",
            isDone: r.isCompleted,
            isInProgress: inProgress.contains(r.calendarItemIdentifier))
    }

    /// In progress, then due today or overdue, then no due date, then upcoming. Within each:
    /// musts first, then by due date, then oldest first.
    nonisolated private static func order(_ a: TodoItem, _ b: TodoItem, startOfTomorrow: Date) -> Bool {
        func group(_ t: TodoItem) -> Int {
            if t.isInProgress { return 0 }
            guard let due = t.due else { return 2 }
            return due < startOfTomorrow ? 1 : 3
        }
        let ga = group(a), gb = group(b)
        if ga != gb { return ga < gb }
        if a.isMust != b.isMust { return a.isMust }
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return (a.created ?? .distantFuture) < (b.created ?? .distantFuture)
        }
    }

    private func reminder(_ id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    // MARK: Changing

    /// The circle: tick off (it stays crossed out for a moment, with Undo), or untick.
    func toggleDone(_ id: String) {
        guard let r = reminder(id) else { return }
        if lingering[id] != nil || r.isCompleted {
            r.isCompleted = false
            lingering[id] = nil
        } else {
            r.isCompleted = true
            if let index = items.firstIndex(where: { $0.id == id }) {
                var item = items[index]
                item.isDone = true
                item.isInProgress = false
                lingering[id] = (item, index)
                items[index] = item
            }
            inProgress.remove(id)
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lingering[id] = nil
                    self?.refresh()
                }
            }
        }
        save(r, what: "toggle done")
    }

    /// Right-click on the circle: working on it now (or not any more).
    func toggleInProgress(_ id: String) {
        var set = inProgress
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        inProgress = set
        refresh()
    }

    /// Ticks a step ("- [ ] …" in the notes) on or off.
    func toggleStep(_ id: String, line: Int) {
        guard let r = reminder(id) else { return }
        r.notes = Checklist.toggling(line: line, in: r.notes ?? "")
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].notes = r.notes ?? "" }
        save(r, what: "toggle step")
    }

    private func save(_ r: EKReminder, what: String) {
        do { try store.save(r, commit: true) }
        catch { LedgeLog.shared.write("reminders: \(what) failed: \(error.localizedDescription)") }
        refresh()
    }

    // MARK: Quick add

    /// Where "#s3" files a to-do: the first list whose name starts with (or contains) it.
    /// No tag: your default Reminders list. No match: a new list with that name.
    func listFor(tag: String?) -> (title: String, isNew: Bool) {
        guard let tag, !tag.isEmpty else { return (defaultListTitle, false) }
        if let match = Self.match(tag, in: listTitles) { return (match, false) }
        return (tag, true)
    }

    nonisolated static func match(_ tag: String, in titles: [String]) -> String? {
        let t = tag.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return titles.first { $0.lowercased() == t }
            ?? titles.first { $0.lowercased().hasPrefix(t) }
            ?? titles.first { $0.lowercased().contains(t) }
    }

    func add(_ draft: TodoDraft, notes: String) -> Result<AddedTodo, QuickAddError> {
        guard access == .granted else {
            requestAccess()
            return .failure(QuickAddError(message: "Allow Reminders access, then press return again"))
        }
        let target: EKCalendar
        let wanted = listFor(tag: draft.listTag)
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == wanted.title }) {
            target = existing
        } else if wanted.isNew, let base = store.defaultCalendarForNewReminders() {
            let list = EKCalendar(for: .reminder, eventStore: store)
            list.title = wanted.title
            list.source = base.source
            do { try store.saveCalendar(list, commit: true) } catch {
                LedgeLog.shared.write("reminders: new list failed: \(error.localizedDescription)")
                return .failure(QuickAddError(message: "Couldn't make the list “\(wanted.title)”"))
            }
            target = list
        } else if let base = store.defaultCalendarForNewReminders() {
            target = base
        } else {
            return .failure(QuickAddError(message: "No Reminders list to save to"))
        }

        let r = EKReminder(eventStore: store)
        r.calendar = target
        r.title = TodoTitle.join(draft.title.isEmpty ? "New to-do" : draft.title, minutes: draft.minutes)
        if draft.isMust { r.priority = 1 }
        if draft.hasDue {
            let parts: Set<Calendar.Component> = draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            r.dueDateComponents = Calendar.current.dateComponents(parts, from: draft.event.start)
            // A time means you want to be reminded then.
            if draft.dueHasTime { r.addAlarm(EKAlarm(absoluteDate: draft.event.start)) }
        }
        r.url = draft.url
        // The Reminders app doesn't show links saved by other apps, so the link also goes first
        // in the notes, where it's visible (and clickable) everywhere.
        var body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = draft.url { body = body.isEmpty ? url.absoluteString : url.absoluteString + "\n" + body }
        if !body.isEmpty { r.notes = body }
        do { try store.save(r, commit: true) } catch {
            LedgeLog.shared.write("reminders: quick add failed: \(error.localizedDescription)")
            return .failure(QuickAddError(message: "Couldn't save: \(error.localizedDescription)"))
        }
        LedgeLog.shared.write("reminders: quick add saved to \(target.title)")
        justAddedID = r.calendarItemIdentifier
        justAddedTimer?.invalidate()
        justAddedTimer = Timer.scheduledTimer(withTimeInterval: 3.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.justAddedID = nil }
        }
        refresh()
        return .success(AddedTodo(id: r.calendarItemIdentifier, title: draft.title.isEmpty ? "New to-do" : draft.title,
                                  listTitle: target.title, draft: draft))
    }

    /// Opens the Reminders app on this to-do.
    func openInReminders(_ id: String) {
        AppleScriptBridge.run(AppleScripts.showReminder, [id])
    }

    func undo(_ added: AddedTodo) {
        justAddedTimer?.invalidate()
        justAddedID = nil
        guard let r = reminder(added.id) else { return }
        do { try store.remove(r, commit: true) }
        catch { LedgeLog.shared.write("reminders: undo failed: \(error.localizedDescription)") }
        refresh()
    }
}

/// "Due today", "Due tomorrow 3:00 PM", "Due Fri", "Overdue".
enum TodoWords {
    static func due(_ date: Date, hasTime: Bool, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = hasTime ? " " + date.formatted(date: .omitted, time: .shortened) : ""
        if hasTime ? date < now : date < cal.startOfDay(for: now) { return "Overdue" }
        if cal.isDate(date, inSameDayAs: now) { return "Due today" + time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Due tomorrow" + time
        }
        if let ahead = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day,
           (2..<7).contains(ahead) {
            return "Due " + date.formatted(.dateTime.weekday(.wide)) + time
        }
        return "Due " + date.formatted(.dateTime.month(.abbreviated).day()) + time
    }

    /// "since 11-04" for a to-do carried over from an earlier day.
    static func since(_ created: Date?, now: Date = Date()) -> String? {
        guard let created, created < Calendar.current.startOfDay(for: now) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return "since " + f.string(from: created)
    }
}
