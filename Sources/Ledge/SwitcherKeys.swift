import AppKit
import Carbon
import CoreGraphics

/// The switcher's shortcut: a key with modifiers (⌥Tab by default). Kept in settings.
struct SwitcherShortcut: Equatable {
    var keyCode: Int
    /// Command, option, control (shift is kept for going backwards).
    var modifiers: NSEvent.ModifierFlags
    /// What the key is called ("Tab", "`", "S").
    var keyName: String

    static let `default` = SwitcherShortcut(keyCode: kVK_Tab, modifiers: .option, keyName: "Tab")

    static let keyCodeKey = "switcherKeyCode"
    static let modifiersKey = "switcherModifiers"
    static let nameKey = "switcherKeyName"

    static var saved: SwitcherShortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: keyCodeKey) != nil else { return .default }
        let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modifiersKey)))
            .intersection([.command, .option, .control])
        guard !mods.isEmpty else { return .default }
        return SwitcherShortcut(keyCode: d.integer(forKey: keyCodeKey), modifiers: mods,
                                keyName: d.string(forKey: nameKey) ?? "?")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(keyCode, forKey: Self.keyCodeKey)
        d.set(Int(modifiers.rawValue), forKey: Self.modifiersKey)
        d.set(keyName, forKey: Self.nameKey)
    }

    /// "⌥Tab", "⌘⇧`".
    var label: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// Shortcuts macOS (or a common app) already uses, with what for. ⌘Tab is fine: Ledge takes it over.
    var clash: String? {
        let m = modifiers
        switch (keyCode, m) {
        case (kVK_Space, .command): return "⌘Space opens Spotlight"
        case (kVK_Space, .control): return "⌃Space switches input sources"
        case (kVK_ANSI_Q, .command): return "⌘Q quits apps"
        case (kVK_ANSI_W, .command): return "⌘W closes windows"
        case (kVK_ANSI_H, .command): return "⌘H hides apps"
        case (kVK_ANSI_M, .command): return "⌘M minimizes windows"
        case (kVK_ANSI_C, .command), (kVK_ANSI_V, .command), (kVK_ANSI_X, .command), (kVK_ANSI_Z, .command):
            return "\(label) is used for editing"
        case (kVK_ANSI_L, .command): return "⌘L opens Ledge"
        case (kVK_ANSI_E, [.control, .option]), (kVK_ANSI_T, [.control, .option]): return "\(label) is Ledge's quick add"
        default: return nil
        }
    }

    /// The name to show for a key pressed in the shortcut field.
    static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Delete: return "Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let c = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return c.isEmpty ? "Key \(event.keyCode)" : c
        }
    }
}

/// Catches the switcher's shortcut from any app: holding its modifiers and pressing its key
/// opens the switcher (and steps on), ⇧ steps back, letting go of the modifiers switches,
/// Esc cancels. Uses the Accessibility permission (like the volume keys).
final class SwitcherKeys {
    enum Action { case open, next, previous, commit, cancel }
    /// Return true if it was handled (the key is then hidden from other apps).
    var onAction: ((Action) -> Bool)?
    /// Read on every key press, so a new shortcut works straight away.
    var shortcut: () -> SwitcherShortcut = { .saved }
    var enabled: () -> Bool = { true }
    /// While the shortcut field in settings is listening for a new shortcut.
    @MainActor static var paused = false
    /// The shortcut field, while it listens: gets every key press first (⌘Tab included, which
    /// macOS never hands to an app's own window). Return true to keep the key from everything else.
    @MainActor static var recorder: ((NSEvent) -> Bool)?

    private var tap: CFMachPort?
    private var retry: Timer?
    private var active = false
    /// The switcher's key went down while it was open: its key-up is ours too.
    private var swallowKeyUp = Set<Int64>()

    func start() {
        if install() { return }
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.install() else { return }
            self.retry?.invalidate()
        }
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SwitcherKeys>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        LedgeLog.shared.write("switcher: listening for \(shortcut().label)")
        return true
    }

    /// Ends a switch from outside (a click on a window): the keys go back to normal.
    func reset() { active = false }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // The tap runs on the main run loop, so the main-thread flags can be read here.
        let (paused, recorder) = MainActor.assumeIsolated { (Self.paused, Self.recorder) }
        if let recorder {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, let ns = NSEvent(cgEvent: event), recorder(ns) {
                swallowKeyUp.insert(code)
                return nil
            }
            if type == .keyUp, swallowKeyUp.remove(code) != nil { return nil }
            return pass
        }
        guard enabled(), !paused else { active = false; return pass }
        let sc = shortcut()
        let flags = event.flags
        var held: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { held.insert(.command) }
        if flags.contains(.maskAlternate) { held.insert(.option) }
        if flags.contains(.maskControl) { held.insert(.control) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            // Letting go of the shortcut's modifiers: switch to the chosen window.
            if active, !held.isSuperset(of: sc.modifiers) {
                active = false
                _ = onAction?(.commit)
            }
            return pass
        case .keyDown:
            if Int(code) == sc.keyCode && held == sc.modifiers {
                let back = flags.contains(.maskShift)
                if !active {
                    guard onAction?(.open) == true else { return pass }
                    active = true
                    if back { _ = onAction?(.previous) }
                } else {
                    _ = onAction?(back ? .previous : .next)
                }
                swallowKeyUp.insert(code)
                return nil
            }
            guard active else { return pass }
            // While it's open: Esc cancels, arrows move, return switches; other keys are ignored.
            switch Int(code) {
            case kVK_Escape: active = false; _ = onAction?(.cancel)
            case kVK_LeftArrow, kVK_UpArrow: _ = onAction?(.previous)
            case kVK_RightArrow, kVK_DownArrow: _ = onAction?(.next)
            case kVK_Return: active = false; _ = onAction?(.commit)
            default: break
            }
            swallowKeyUp.insert(code)
            return nil
        case .keyUp:
            return swallowKeyUp.remove(code) != nil ? nil : pass
        default:
            return pass
        }
    }
}
