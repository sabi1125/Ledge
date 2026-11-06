import AppKit
import LedgeCore

/// The one timer, shared by every island.
@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var countdown: Countdown
    /// Called the moment the countdown reaches zero.
    var onFinish: (() -> Void)?

    static let presets: [Int] = [1, 5, 10, 15, 25, 45] // minutes
    private static let durationKey = "timerDuration"
    private var ticker: Timer?

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.durationKey)
        countdown = Countdown(duration: saved > 0 ? saved : 5 * 60)
    }

    func choose(minutes: Int) {
        countdown.choose(TimeInterval(minutes * 60))
        UserDefaults.standard.set(countdown.duration, forKey: Self.durationKey)
    }

    func start() {
        countdown.start(at: Date())
        LedgeLog.shared.write("timer: started, \(formatCountdown(countdown.remaining(at: Date()))) left")
        schedule()
    }

    func pause() {
        countdown.pause(at: Date())
        schedule()
    }

    func reset() {
        countdown.reset()
        schedule()
    }

    func addMinute() {
        countdown.add(60, at: Date())
        if !countdown.isActive { UserDefaults.standard.set(countdown.duration, forKey: Self.durationKey) }
    }

    /// Ticks only while running, and lands exactly on zero.
    private func schedule() {
        ticker?.invalidate()
        ticker = nil
        guard countdown.isRunning else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 0.05
    }

    private func tick() {
        if countdown.tick(at: Date()) {
            ticker?.invalidate()
            ticker = nil
            LedgeLog.shared.write("timer: done")
            NSSound(named: "Glass")?.play()
            onFinish?()
        }
    }
}
