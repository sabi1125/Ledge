import AppKit
import IOKit.pwr_mgt
import LedgeCore

/// Keeps the Mac awake, like `caffeinate`: asks macOS not to sleep (no permission needed).
/// Ends on its own when the time runs out, when you turn it off, or when Ledge quits.
@MainActor
final class AwakeStore: ObservableObject {
    enum Reason { case you, charging }

    /// nil = off. `until` nil = until you turn it off.
    @Published private(set) var session: (until: Date?, reason: Reason)?

    var isOn: Bool { session != nil }
    var onStart: ((_ minutes: Int) -> Void)?
    var onEnd: (() -> Void)?

    /// Lengths offered in the menu (minutes; 0 = until you turn it off).
    static let lengths = [15, 30, 60, 120, 0]

    private var assertion: IOPMAssertionID = 0
    private var endTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var keptScreenOn = Pref.bool(Pref.awakeKeepScreenOn)
    private var onPower = false
    private var chargingRule = Pref.bool(Pref.awakeWhileCharging)

    init() {
        // Switching "Keep the screen on too" while awake takes effect right away.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOn, self.keptScreenOn != Pref.bool(Pref.awakeKeepScreenOn) { self.holdAssertion() }
                // Turning the charging rule on while plugged in starts it now; turning it off ends it.
                if self.chargingRule != Pref.bool(Pref.awakeWhileCharging) {
                    self.chargingRule = Pref.bool(Pref.awakeWhileCharging)
                    if self.chargingRule { self.powerChanged(onPower: self.onPower) }
                    else if self.session?.reason == .charging { self.stop() }
                }
            }
        }
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        session?.until.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// A plain click on the cup: on for the default length, or off.
    func toggle() {
        if isOn { stop() } else { start(minutes: UserDefaults.standard.integer(forKey: Pref.awakeDefaultMinutes)) }
    }

    func start(minutes: Int, reason: Reason = .you) {
        let until = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        session = (until, reason)
        holdAssertion()
        endTimer?.invalidate()
        endTimer = nil
        if let until {
            endTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        LedgeLog.shared.write("awake: on for \(describeAwakeLength(minutes: minutes))\(reason == .charging ? " (charging)" : "")")
        onStart?(minutes)
    }

    func stop() {
        guard isOn else { return }
        endTimer?.invalidate()
        endTimer = nil
        releaseAssertion()
        session = nil
        LedgeLog.shared.write("awake: off")
        onEnd?()
    }

    /// The "stay awake while charging" rule.
    func powerChanged(onPower: Bool) {
        self.onPower = onPower
        guard Pref.bool(Pref.awakeWhileCharging) else { return }
        if onPower, !isOn { start(minutes: 0, reason: .charging) }
        if !onPower, session?.reason == .charging { stop() }
    }

    private func holdAssertion() {
        releaseAssertion()
        keptScreenOn = Pref.bool(Pref.awakeKeepScreenOn)
        let type = keptScreenOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Ledge: stay awake" as CFString, &assertion)
        if result != kIOReturnSuccess { LedgeLog.shared.write("awake: macOS refused to stay awake (\(result))") }
    }

    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
    }
}
