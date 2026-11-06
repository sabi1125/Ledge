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
