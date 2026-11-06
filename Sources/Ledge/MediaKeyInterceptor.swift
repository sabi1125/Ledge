import AppKit
import CoreGraphics

/// Catches the volume and brightness keys before macOS handles them, so Ledge can
/// change the level itself and show its own indicator instead of the system pop-up.
///
/// Needs the Accessibility permission. If it isn't granted (or anything goes wrong),
/// the keys simply keep working the normal macOS way.
final class MediaKeyInterceptor {
    enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    /// Called on key down (and auto-repeat). Return true if Ledge handled it,
    /// which hides the key from macOS (no system pop-up).
    var onKey: ((Key, _ fine: Bool) -> Bool)?

    private(set) var isActive = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    /// Keys whose key-down we swallowed, so the matching key-up is swallowed too.
    private var swallowed = Set<Int>()

    func start() {
        if install() { return }
        LedgeLog.shared.write("keys: waiting for Accessibility permission to replace the volume/brightness pop-ups")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.install() else { return }
            self.retryTimer?.invalidate()
        }
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED: media, volume and brightness keys
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        LedgeLog.shared.write("keys: handling volume and brightness keys (system pop-ups hidden)")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off if it's ever slow; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = Int((ns.data1 & 0xFFFF_0000) >> 16)
        let state = (ns.data1 & 0xFF00) >> 8
        let key: Key
        switch code {
        case 0: key = .volumeUp      // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown    // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute          // NX_KEYTYPE_MUTE
        case 2: key = .brightnessUp  // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown
        default: return Unmanaged.passUnretained(event)
        }
        switch state {
        case 0x0A: // key down (also sent for auto-repeat)
            let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
            if onKey?(key, fine) == true {
                swallowed.insert(code)
                return nil
            }
            swallowed.remove(code)
            return Unmanaged.passUnretained(event)
        case 0x0B: // key up
            return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
