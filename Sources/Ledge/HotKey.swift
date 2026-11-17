import Carbon
import Foundation

/// A system-wide keyboard shortcut (works without any permission).
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        Self.installHandlerIfNeeded()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C44_4745), id: id) // "LDGE"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        // Fails when another app already uses the same shortcut.
        if status != noErr {
            ref = nil
            LedgeLog.shared.write("hotkey \(id): couldn't register (\(status)), another app may use it")
        }
    }

    /// macOS accepted it (it refuses a shortcut something else already holds).
    var isRegistered: Bool { ref != nil }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let action = HotKey.actions[hotKeyID.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
