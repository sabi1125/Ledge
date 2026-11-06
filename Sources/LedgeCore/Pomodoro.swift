import Foundation

/// Focus / short break / long break lengths, and how many focus sessions make a cycle.
public struct PomodoroPlan: Equatable, Sendable {
    public var focus: TimeInterval
    public var shortBreak: TimeInterval
    public var longBreak: TimeInterval
    public var sessions: Int

    public init(focusMinutes: Int = 25, shortMinutes: Int = 5, longMinutes: Int = 15, sessions: Int = 4) {
        focus = TimeInterval(max(1, focusMinutes) * 60)
        shortBreak = TimeInterval(max(1, shortMinutes) * 60)
        longBreak = TimeInterval(max(1, longMinutes) * 60)
        self.sessions = max(1, sessions)
    }

    public func length(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .shortBreak: return shortBreak
        case .longBreak: return longBreak
        }
    }
}

public enum PomodoroPhase: Equatable, Sendable {
    case focus, shortBreak, longBreak

    public var isBreak: Bool { self != .focus }

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

/// A pomodoro cycle: focus, break, focus, break… with a long break after `sessions` focus rounds.
public struct Pomodoro: Equatable, Sendable {
    public private(set) var plan: PomodoroPlan
    public private(set) var phase: PomodoroPhase = .focus
    /// Focus sessions finished in the current cycle (for the dots).
    public private(set) var completedFocus = 0
    public private(set) var countdown: Countdown

    public init(plan: PomodoroPlan = PomodoroPlan()) {
        self.plan = plan
        countdown = Countdown(duration: plan.focus)
    }

    /// "2 of 4" while focusing.
    public var sessionNumber: Int { min(completedFocus + 1, plan.sessions) }

    /// What comes after the current phase.
    public var nextPhase: PomodoroPhase {
        switch phase {
        case .focus: return completedFocus + 1 >= plan.sessions ? .longBreak : .shortBreak
        case .shortBreak, .longBreak: return .focus
        }
    }

    public mutating func start(at now: Date) { countdown.start(at: now) }
    public mutating func pause(at now: Date) { countdown.pause(at: now) }

    /// Back to the first focus session, not running.
    public mutating func reset() {
        phase = .focus
        completedFocus = 0
        countdown = Countdown(duration: plan.focus)
    }

    /// New lengths from settings; applies right away unless a phase is underway.
    public mutating func update(plan newPlan: PomodoroPlan) {
        plan = newPlan
        completedFocus = min(completedFocus, plan.sessions)
        if !countdown.isActive { countdown = Countdown(duration: plan.length(of: phase)) }
    }

    /// Moves to the next phase (when one finishes, or on Skip). Returns the new phase.
    @discardableResult
    public mutating func advance(at now: Date, autoStart: Bool) -> PomodoroPhase {
        let next = nextPhase
        switch phase {
        case .focus: completedFocus += 1
        case .longBreak: completedFocus = 0
        case .shortBreak: break
        }
        phase = next
        countdown = Countdown(duration: plan.length(of: next))
        if autoStart { countdown.start(at: now) }
        return next
    }

    /// Call regularly; returns the phase that just ended, if the countdown reached zero.
    public mutating func tick(at now: Date, autoStart: Bool) -> (ended: PomodoroPhase, next: PomodoroPhase)? {
        var c = countdown
        guard c.tick(at: now) else { return nil }
        let ended = phase
        let next = advance(at: now, autoStart: autoStart)
        return (ended, next)
    }
}
