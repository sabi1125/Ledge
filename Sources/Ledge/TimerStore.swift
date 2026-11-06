import AppKit
import LedgeCore
import SwiftUI

/// The timer and the pomodoro, shared by every island. Only one counts down at a time.
@MainActor
final class TimerStore: ObservableObject {
    enum Mode: String { case timer, pomodoro }

    /// What's counting down right now (for the notch).
    enum Live: Equatable {
        case timer
        case pomodoro(PomodoroPhase)

        var title: String {
            switch self {
            case .timer: return "Timer"
            case let .pomodoro(phase): return phase.title
            }
        }
        var color: Color {
            switch self {
            case .timer: return Theme.timerOrange
            case let .pomodoro(phase): return phase.isBreak ? Theme.breakGreen : Theme.focusRed
            }
        }
        var symbol: String {
            switch self {
            case .timer: return "timer"
            case let .pomodoro(phase): return phase.isBreak ? "leaf.fill" : "target"
            }
        }
    }

    @Published private(set) var countdown: Countdown
    @Published private(set) var pomodoro: Pomodoro
    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) } }
    @Published private(set) var live: Live?

    /// Called the moment the timer reaches zero.
    var onFinish: (() -> Void)?
    /// Called when a pomodoro phase ends: (ended, next, next length in minutes).
    var onPhaseEnd: ((PomodoroPhase, PomodoroPhase, Int) -> Void)?

    static let presets: [Int] = [1, 5, 10, 15, 25, 45] // minutes
    private static let durationKey = "timerDuration"
    private static let modeKey = "timerMode"
    private var ticker: Timer?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.durationKey)
        countdown = Countdown(duration: saved > 0 ? saved : 5 * 60)
        pomodoro = Pomodoro(plan: Self.planFromSettings())
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .timer
        // New pomodoro lengths in settings apply to the next phase (or right away when stopped).
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let plan = Self.planFromSettings()
                if plan != self.pomodoro.plan { self.pomodoro.update(plan: plan) }
            }
        }
    }

    static func planFromSettings() -> PomodoroPlan {
        let d = UserDefaults.standard
        func v(_ key: String, _ fallback: Int) -> Int { let x = d.integer(forKey: key); return x > 0 ? x : fallback }
        return PomodoroPlan(focusMinutes: v(Pref.pomoFocus, 25), shortMinutes: v(Pref.pomoShort, 5),
                            longMinutes: v(Pref.pomoLong, 15), sessions: v(Pref.pomoSessions, 4))
    }

    // MARK: Timer

    func choose(minutes: Int) {
        countdown.choose(TimeInterval(minutes * 60))
        UserDefaults.standard.set(countdown.duration, forKey: Self.durationKey)
    }

    func start() {
        pausePomodoro() // one countdown at a time
        countdown.start(at: Date())
        LedgeLog.shared.write("timer: started, \(formatCountdown(countdown.remaining(at: Date()))) left")
        refresh()
    }

    func pause() {
        countdown.pause(at: Date())
        refresh()
    }

    func reset() {
        countdown.reset()
        refresh()
    }

    func addMinute() {
        countdown.add(60, at: Date())
        if !countdown.isActive { UserDefaults.standard.set(countdown.duration, forKey: Self.durationKey) }
        refresh()
    }

    // MARK: Pomodoro

    func startPomodoro() {
        if countdown.isRunning { countdown.pause(at: Date()) } // one countdown at a time
        pomodoro.start(at: Date())
        LedgeLog.shared.write("pomodoro: \(pomodoro.phase.title) started")
        refresh()
    }

    func pausePomodoro() {
        guard pomodoro.countdown.isRunning else { return }
        pomodoro.pause(at: Date())
        refresh()
    }

    /// Jumps to the next phase, keeping it running if this one was.
    func skipPomodoro() {
        let wasRunning = pomodoro.countdown.isRunning
        pomodoro.advance(at: Date(), autoStart: wasRunning)
        refresh()
    }

    func resetPomodoro() {
        pomodoro.reset()
        refresh()
    }

    // MARK: Ticking

    /// Which countdown is showing in the notch, and keeping the ticker running only when needed.
    private func refresh() {
        if pomodoro.countdown.isActive { live = .pomodoro(pomodoro.phase) }
        else if countdown.isActive { live = .timer }
        else { live = nil }

        let running = countdown.isRunning || pomodoro.countdown.isRunning
        if running && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            ticker?.tolerance = 0.05
        } else if !running {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// The active countdown's time left (for the notch).
    func liveRemaining(at now: Date) -> TimeInterval {
        if pomodoro.countdown.isActive { return pomodoro.countdown.remaining(at: now) }
        return countdown.remaining(at: now)
    }

    var liveIsRunning: Bool { countdown.isRunning || pomodoro.countdown.isRunning }

    private func tick() {
        let now = Date()
        if countdown.tick(at: now) {
            LedgeLog.shared.write("timer: done")
            NSSound(named: "Glass")?.play()
            onFinish?()
        }
        let autoStart = Pref.bool(Pref.pomoAutoStart)
        if let ended = pomodoro.tick(at: now, autoStart: autoStart) {
            LedgeLog.shared.write("pomodoro: \(ended.ended.title) done, next \(ended.next.title)")
            NSSound(named: ended.ended == .focus ? "Glass" : "Hero")?.play()
            onPhaseEnd?(ended.ended, ended.next, Int(pomodoro.plan.length(of: ended.next) / 60))
        }
        refresh()
    }
}
