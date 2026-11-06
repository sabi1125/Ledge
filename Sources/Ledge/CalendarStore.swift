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

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
}

/// Reads upcoming events from the Calendar app's accounts (iCloud, Google, Exchange…).
@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notAsked, granted, denied }

    @Published private(set) var access: Access = .notAsked
    @Published private(set) var events: [CalendarItem] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var isSample = false

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
                // All-day events first within a day, then by start time.
                if cal.isDate(a.startDate, inSameDayAs: b.startDate), a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .prefix(12)
            .map { e in
                CalendarItem(
                    id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)",
                    title: e.title?.isEmpty == false ? e.title! : "Untitled",
                    start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                    color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                    joinURL: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]))
            }
        if Array(found) != events { events = Array(found) }
    }

    /// For snapshots only.
    func useSample(_ items: [CalendarItem]) {
        isSample = true
        access = .granted
        events = items
        timer?.invalidate()
    }
}
