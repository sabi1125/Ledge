import AppKit
import EventKit
import LedgeCore
import SwiftUI

struct CalendarItem: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    var joinURL: URL?
    /// The Calendar app's id for the event (to open it there). Nil for sample events.
    var eventID: String? = nil

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
}

/// An event quick add just saved, kept so it can be undone.
struct AddedEvent: Equatable {
    var eventID: String
    var listID: String
    var draft: QuickEventDraft
}

struct QuickAddError: Error, Equatable {
    var message: String
}

/// Reads upcoming events from the Calendar app's accounts (iCloud, Google, Exchange…).
@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notAsked, granted, denied }

    @Published private(set) var access: Access = .notAsked
    @Published private(set) var events: [CalendarItem] = []
    /// The event quick add just saved, softly highlighted in the list for a moment.
    @Published private(set) var justAddedID: String?
    /// The color of the calendar quick add saves to (for its preview bar).
    @Published private(set) var quickAddColor: Color = Color(nsColor: .systemPurple)

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var isSample = false
    private var justAddedTimer: Timer?

    init() {
        updateAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keep "now" / "in 5 min" current and drop finished events.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, error in
            if let error { LedgeLog.shared.write("calendar: access request failed: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                self?.updateAccess()
                LedgeLog.shared.write("calendar: access \(self?.access == .granted ? "granted" : "not granted")")
                self?.refresh()
            }
        }
    }

    func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        guard !isSample else { return }
        updateAccess()
        guard access == .granted else { events = []; return }
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        guard let endOfTomorrow = cal.date(byAdding: .day, value: 2, to: startOfToday) else { return }
        let predicate = store.predicateForEvents(withStart: startOfToday, end: endOfTomorrow, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { a, b in
                // What's next on top: the meeting you're in, then today's meetings, then today's
                // all-day and day-long items; tomorrow the same (see `EventOrder`).
                EventOrder.isBefore((a.startDate, a.endDate, a.isAllDay), (b.startDate, b.endDate, b.isAllDay),
                                    now: now, calendar: cal)
            }
            .prefix(12)
            .map { e in
                CalendarItem(
                    id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)",
                    title: e.title?.isEmpty == false ? e.title! : "Untitled",
                    start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                    color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                    joinURL: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]),
                    eventID: e.eventIdentifier)
            }
        if Array(found) != events { events = Array(found) }
        let color = Color(nsColor: quickAddCalendar?.color ?? .systemPurple)
        if color != quickAddColor { quickAddColor = color }
    }

    // MARK: Quick add

    /// Where quick add saves: your iCloud calendar (the one called Personal or Home, if there is one).
    /// Falls back to the default calendar for new events in the Calendar app.
    private var quickAddCalendar: EKCalendar? {
        let writable = store.calendars(for: .event).filter { $0.allowsContentModifications }
        let iCloud = writable.filter { $0.source?.sourceType == .calDAV && ($0.source?.title ?? "").localizedCaseInsensitiveContains("icloud") }
        return iCloud.first { ["personal", "home"].contains($0.title.lowercased()) }
            ?? iCloud.first
            ?? store.defaultCalendarForNewEvents
    }

    /// Saves a quick add event to the Calendar app.
    func add(_ draft: QuickEventDraft, notes: String) -> Result<AddedEvent, QuickAddError> {
        guard access == .granted else {
            requestAccess()
            return .failure(QuickAddError(message: "Allow Calendar access, then press return again"))
        }
        guard let target = quickAddCalendar else {
            return .failure(QuickAddError(message: "No calendar to save to"))
        }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        if let rule = draft.repeatRule { event.addRecurrenceRule(rule.eventKitRule) }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { event.notes = trimmed }
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            LedgeLog.shared.write("calendar: quick add failed: \(error.localizedDescription)")
            return .failure(QuickAddError(message: "Couldn't save: \(error.localizedDescription)"))
        }
        LedgeLog.shared.write("calendar: quick add saved to \(target.title)")
        let listID = event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)"
        // Highlighted through the confirmation (1.2 s) and about 2 s back in the list.
        justAddedID = listID
        justAddedTimer?.invalidate()
        justAddedTimer = Timer.scheduledTimer(withTimeInterval: 3.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.justAddedID = nil }
        }
        refresh()
        return .success(AddedEvent(eventID: event.eventIdentifier ?? "", listID: listID, draft: draft))
    }

    /// Opens the Calendar app on this event (its day, with the event selected).
    func openInCalendar(_ eventID: String) {
        let id = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        guard let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") else { return }
        LedgeLog.shared.write("calendar: opening an event in Calendar")
        NSWorkspace.shared.open(url)
    }

    /// Removes an event quick add just saved (Undo).
    func undo(_ added: AddedEvent) {
        justAddedTimer?.invalidate()
        justAddedID = nil
        guard let event = store.event(withIdentifier: added.eventID) else { return }
        do {
            // A repeating one goes as a whole series (it was only just made).
            try store.remove(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
            LedgeLog.shared.write("calendar: quick add undone")
        } catch {
            LedgeLog.shared.write("calendar: undo failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// For snapshots only.
    func useSample(_ items: [CalendarItem]) {
        isSample = true
        access = .granted
        events = items
        timer?.invalidate()
    }
}

extension RepeatRule {
    /// The same repeat, for the Calendar and Reminders apps.
    var eventKitRule: EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch self.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let days = weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        // To the end of its last day.
        let end = until.map { EKRecurrenceEnd(end: Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: $0) ?? $0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                                daysOfTheWeek: days.isEmpty ? nil : days,
                                daysOfTheMonth: monthDay.map { [NSNumber(value: $0)] },
                                monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: nil, end: end)
    }
}
