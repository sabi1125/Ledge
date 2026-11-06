import Foundation

/// A countdown timer's state, independent of any UI.
public struct Countdown: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    /// The length chosen (also what Reset goes back to).
    public var duration: TimeInterval
    public private(set) var phase: Phase = .idle

    public init(duration: TimeInterval = 5 * 60) {
        self.duration = duration
    }

    /// Running or paused: worth showing in the notch.
    public var isActive: Bool {
        switch phase {
        case .running, .paused: return true
        case .idle, .finished: return false
        }
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .idle: return duration
        case let .running(end): return max(0, end.timeIntervalSince(now))
        case let .paused(remaining): return remaining
        case .finished: return 0
        }
    }

    /// Picks a new length; only while not counting down.
    public mutating func choose(_ seconds: TimeInterval) {
        duration = max(1, seconds)
        if !isActive { phase = .idle }
    }

    public mutating func start(at now: Date) {
        switch phase {
        case .idle, .finished: phase = .running(end: now.addingTimeInterval(duration))
        case let .paused(remaining): phase = .running(end: now.addingTimeInterval(remaining))
        case .running: break
        }
    }

    public mutating func pause(at now: Date) {
        guard case let .running(end) = phase else { return }
        phase = .paused(remaining: max(0, end.timeIntervalSince(now)))
    }

    public mutating func reset() {
        phase = .idle
    }

    /// Adds time to a running or paused timer (or to the chosen length when idle).
    public mutating func add(_ seconds: TimeInterval, at now: Date) {
        switch phase {
        case let .running(end): phase = .running(end: end.addingTimeInterval(seconds))
        case let .paused(remaining): phase = .paused(remaining: remaining + seconds)
        case .idle, .finished:
            duration += seconds
            phase = .idle
        }
    }

    /// Marks the countdown done if its time is up. Returns true the moment it finishes.
    public mutating func tick(at now: Date) -> Bool {
        guard case let .running(end) = phase, now >= end else { return false }
        phase = .finished
        return true
    }
}

/// "4:05", "12:00", "1:02:03".
public func formatCountdown(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Stay-awake time left, short enough for the cup button: "58m", "1h 20m", "2h".
public func formatAwakeRemaining(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded(.up)))
    if minutes < 60 { return "\(minutes)m" }
    let h = minutes / 60, m = minutes % 60
    return m == 0 ? "\(h)h" : "\(h)h\(m)m"
}

/// Stay-awake length as words, for the pop and the menu: "1 h", "30 min", "until you turn it off".
public func describeAwakeLength(minutes: Int) -> String {
    switch minutes {
    case ..<1: return "until off"
    case ..<60: return "\(minutes) min"
    default: return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
