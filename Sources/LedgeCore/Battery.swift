/// A snapshot of the battery.
public struct BatterySnapshot: Equatable, Sendable {
    public var percent: Int
    public var onPower: Bool
    public var charging: Bool

    public init(percent: Int, onPower: Bool, charging: Bool) {
        self.percent = percent
        self.onPower = onPower
        self.charging = charging
    }
}

public enum BatteryEvent: Equatable, Sendable {
    case pluggedIn(percent: Int)
    case low(percent: Int)
}

public enum BatteryRules {
    /// Low-battery warnings fire once when crossing each of these levels on battery.
    public static let lowLevels = [20, 10, 5]

    /// Decides whether a change between two snapshots deserves a notch pop.
    public static func event(from old: BatterySnapshot?, to new: BatterySnapshot) -> BatteryEvent? {
        guard let old else { return nil } // never pop on launch
        if new.onPower && !old.onPower {
            return .pluggedIn(percent: new.percent)
        }
        if !new.onPower {
            for level in lowLevels where old.percent > level && new.percent <= level {
                return .low(percent: new.percent)
            }
        }
        return nil
    }
}
