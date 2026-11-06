import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import LedgeCore

// MARK: - Volume

/// Watches the default output device's volume and mute through Core Audio.
final class VolumeMonitor {
    var onChange: ((Double, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: (Double, Bool)?
    private var quietUntil = Date()

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.attachToDefaultDevice()
    }
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.volumeChanged()
    }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &defaultDeviceAddress, .main, deviceListener)
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, volumeListener)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, volumeListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else { return }
        AudioObjectAddPropertyListenerBlock(id, &volumeAddress, .main, volumeListener)
        AudioObjectAddPropertyListenerBlock(id, &muteAddress, .main, volumeListener)
        last = read()
        // Switching to AirPods etc. changes the volume; don't show that as a key press.
        quietUntil = Date().addingTimeInterval(0.8)
    }

    private func read() -> (Double, Bool)? {
        guard device != kAudioObjectUnknown else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) != noErr { mute = 0 }
        return (Double(volume), mute != 0)
    }

    private func volumeChanged() {
        guard let now = read() else { return }
        defer { last = now }
        guard Date() > quietUntil else { return }
        if let last, abs(last.0 - now.0) < 0.001, last.1 == now.1 { return }
        onChange?(now.0, now.1)
    }

    // MARK: Changing the volume (used when Ledge handles the volume keys itself)

    /// True when the current output device has a volume Ledge can set (not e.g. some HDMI outputs).
    var canControl: Bool {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &volumeAddress) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    /// One volume key press: 1/16 steps like macOS, or 1/64 with ⇧⌥.
    func step(up: Bool, fine: Bool) {
        guard var (volume, muted) = read() else { return }
        let size = fine ? 1.0 / 64 : 1.0 / 16
        volume = ((volume / size).rounded() + (up ? 1 : -1)) * size
        volume = min(1, max(0, volume))
        set(volume: volume)
        if muted && up { set(muted: false); muted = false }
        report(volume, muted || volume == 0)
    }

    func toggleMute() {
        guard let (volume, muted) = read() else { return }
        set(muted: !muted)
        report(volume, !muted)
    }

    private func report(_ volume: Double, _ muted: Bool) {
        last = (volume, muted)
        onChange?(volume, muted)
    }

    private func set(volume: Double) {
        var v = Float32(volume)
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func set(muted: Bool) {
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}

// MARK: - Brightness

/// Shows the brightness when the brightness keys are pressed.
/// Reads the level through the private DisplayServices framework.
final class BrightnessMonitor {
    var onChange: ((Double) -> Void)?
    var displayID: () -> CGDirectDisplayID = { CGMainDisplayID() }

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?
    private var monitors: [Any] = []

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(sym, to: GetBrightness.self)
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightness = unsafeBitCast(sym, to: SetBrightness.self)
            }
        }
    }

    var canControl: Bool { setBrightness != nil && read() != nil }

    /// One brightness key press: 1/16 steps like macOS, or 1/64 with ⇧⌥.
    func step(up: Bool, fine: Bool) {
        guard let setBrightness, let current = read() else { return }
        let size = fine ? 1.0 / 64 : 1.0 / 16
        var value = ((current / size).rounded() + (up ? 1 : -1)) * size
        value = min(1, max(0, value))
        _ = setBrightness(displayID(), Float(value))
        onChange?(value)
    }

    var isAvailable: Bool { getBrightness != nil && read() != nil }

    func read() -> Double? {
        guard let getBrightness else { return nil }
        var value = Float(0)
        guard getBrightness(displayID(), &value) == 0 else { return nil }
        return Double(value)
    }

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        // Media and brightness keys arrive as "aux control button" system events.
        guard e.subtype.rawValue == 8 else { return }
        let key = (e.data1 & 0xFFFF_0000) >> 16
        let isDown = ((e.data1 & 0xFF00) >> 8) == 0x0A
        let brightnessUp = 2, brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        guard isDown, key == brightnessUp || key == brightnessDown else { return }
        // The system animates the change; read it twice so the bar lands on the final value.
        for delay in [0.06, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let level = self?.read() { self?.onChange?(level) }
            }
        }
    }
}

// MARK: - Battery

final class BatteryMonitor {
    var onEvent: ((BatteryEvent) -> Void)?
    private var last: BatterySnapshot?
    private var source: CFRunLoopSource?

    func start() {
        last = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    private func changed() {
        guard let now = Self.read() else { return }
        if let event = BatteryRules.event(from: last, to: now) { onEvent?(event) }
        last = now
    }

    static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            return BatterySnapshot(percent: percent,
                                   onPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                   charging: d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
