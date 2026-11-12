import Foundation

// MARK: - Event order

/// The order of the Calendar page's events, so what's next is at the top: the meeting you're in,
/// then the meetings still to come today, then today's all-day and day-long items (they're not
/// done, but they're not what's next), then tomorrow the same way.
public enum EventOrder {
    /// Longer than this, an event is background (an "in office" block, out of office) rather than
    /// a meeting, and goes with the all-day items.
    public static let longEvent: TimeInterval = 4 * 60 * 60

    public enum Group: Int, Comparable, Sendable {
        /// A meeting going on right now.
        case now
        /// A meeting later today.
        case laterToday
        /// Today's all-day or day-long items.
        case todayBackground
        /// A meeting tomorrow.
        case tomorrow
        /// Tomorrow's all-day or day-long items.
        case tomorrowBackground

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which part of the list an event belongs in.
    public static func group(start: Date, end: Date, isAllDay: Bool, now: Date, calendar: Calendar = .current) -> Group {
        let background = isAllDay || end.timeIntervalSince(start) > longEvent
        let tomorrow = start > now && !calendar.isDate(start, inSameDayAs: now)
        if tomorrow { return background ? .tomorrowBackground : .tomorrow }
        if background { return .todayBackground }
        return start <= now ? .now : .laterToday
    }

    /// True when the first event goes above the second: by group, then by start time.
    public static func isBefore(_ a: (start: Date, end: Date, isAllDay: Bool),
                                _ b: (start: Date, end: Date, isAllDay: Bool),
                                now: Date, calendar: Calendar = .current) -> Bool {
        let groupA = group(start: a.start, end: a.end, isAllDay: a.isAllDay, now: now, calendar: calendar)
        let groupB = group(start: b.start, end: b.end, isAllDay: b.isAllDay, now: now, calendar: calendar)
        if groupA != groupB { return groupA < groupB }
        return a.start < b.start
    }
}
