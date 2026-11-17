import Foundation

/// When a meeting shows on the island: a quiet countdown beside the notch from 5 minutes
/// before, then a pill with Join from 1 minute before until a few minutes after it starts.
public enum MeetingSchedule {
    /// The countdown starts this long before.
    public static let countdownLead: TimeInterval = 5 * 60
    /// The pill drops down this long before.
    public static let alertLead: TimeInterval = 60
    /// …and stays this long after the start (unless you join or dismiss it, or it ends).
    public static let alertStays: TimeInterval = 5 * 60

    public enum Phase: Equatable, Sendable {
        /// Beside the notch, counting down.
        case countdown
        /// Dropped down, with Join.
        case alert
    }

    public struct Event: Equatable, Sendable {
        public var id: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// You said no to it.
        public var declined: Bool

        public init(id: String, start: Date, end: Date, isAllDay: Bool, declined: Bool = false) {
            self.id = id
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.declined = declined
        }

        /// A meeting worth a heads-up: timed, not declined, not a day-long block ("in office").
        var counts: Bool {
            !isAllDay && !declined && end > start && end.timeIntervalSince(start) <= EventOrder.longEvent
        }
    }

    /// The meeting to show now and how, or nil. The pill wins over a countdown; of two pills
    /// (back-to-back meetings), the later one, which is the one about to start.
    public static func current(_ events: [Event], now: Date, dismissed: Set<String> = []) -> (id: String, phase: Phase)? {
        let candidates = events.filter { $0.counts && !dismissed.contains($0.id) }
        let alerts = candidates.filter {
            now >= $0.start.addingTimeInterval(-alertLead) && now < min($0.start.addingTimeInterval(alertStays), $0.end)
        }
        if let latest = alerts.max(by: { $0.start < $1.start }) { return (latest.id, .alert) }
        let countdowns = candidates.filter {
            now >= $0.start.addingTimeInterval(-countdownLead) && now < $0.start.addingTimeInterval(-alertLead)
        }
        if let soonest = countdowns.min(by: { $0.start < $1.start }) { return (soonest.id, .countdown) }
        return nil
    }

    /// How soon it's worth looking again: every second while a meeting is close, otherwise
    /// when the next one's countdown starts (at most every 30 s, since the calendar can change).
    public static func nextCheck(_ events: [Event], now: Date) -> TimeInterval {
        let next = events.filter(\.counts).map { $0.start.addingTimeInterval(-countdownLead) }
        if events.contains(where: { $0.counts && now >= $0.start.addingTimeInterval(-countdownLead)
            && now < $0.start.addingTimeInterval(alertStays) }) { return 1 }
        guard let soonest = next.filter({ $0 > now }).min() else { return 30 }
        return min(30, max(1, soonest.timeIntervalSince(now)))
    }

    /// What the pill says about the time: "in 0:42", "now", "2 min ago".
    public static func whenText(start: Date, now: Date) -> String {
        let left = start.timeIntervalSince(now)
        if left > 0 {
            let s = Int(left.rounded(.up))
            return "in \(s / 60):\(String(format: "%02d", s % 60))"
        }
        let ago = Int(-left / 60)
        return ago < 1 ? "now" : "\(ago) min ago"
    }

    /// The countdown beside the notch: "4:59".
    public static func countdownText(start: Date, now: Date) -> String {
        let s = max(0, Int(start.timeIntervalSince(now).rounded(.up)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
