import AppKit

/// Light trackpad taps. They're only felt while a finger rests on a Force Touch trackpad.
enum Haptics {
    /// When the island opens.
    static func openTick() {
        guard Pref.bool(Pref.haptics) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// When a timer finishes.
    static func alert() {
        guard Pref.bool(Pref.haptics) else { return }
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { performer.perform(.generic, performanceTime: .now) }
    }
}
