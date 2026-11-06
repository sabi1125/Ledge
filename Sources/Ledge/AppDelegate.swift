import AppKit
import Carbon
import Combine
import LedgeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let media = MediaController()
    private let calendar = CalendarStore()
    private let notes = NotesStore()
    private let timer = TimerStore()
    private let awake = AwakeStore()
    private let updater = Updater()
    /// One island per screen: the notch on the MacBook, a floating pill on other displays.
    private lazy var islands = IslandManager(media: media, calendar: calendar, notes: notes, timer: timer,
                                             awake: awake, settings: settingsState, updater: updater) { [weak self] in
        self?.showSettings()
    }
    private let volume = VolumeMonitor()
    private let brightness = BrightnessMonitor()
    private let battery = BatteryMonitor()
    private let hider = MenuBarHider()
    private let keys = MediaKeyInterceptor()
    private let settingsState = SettingsState()
    private var revealHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        LedgeLog.shared.write("Ledge \(version) started")

        islands.start()
        media.start()
        // Stay awake: a short pop when it turns on or off.
        awake.onStart = { [weak self] minutes in self?.showIndicator(.awakeOn(minutes: minutes)) }
        awake.onEnd = { [weak self] in self?.showIndicator(.awakeOff) }
        timer.onPhaseEnd = { [weak self] ended, next, minutes in
            self?.showIndicator(.pomodoro(ended: ended, next: next, minutes: minutes))
            Haptics.alert()
        }
        timer.onFinish = { [weak self] in
            guard let self else { return }
            self.showIndicator(.timerDone(duration: self.timer.countdown.duration))
            Haptics.alert()
        }

        volume.onChange = { [weak self] level, muted in
            guard Pref.bool(Pref.showVolume) else { return }
            self?.showIndicator(.volume(level: level, muted: muted))
        }
        volume.start()

        brightness.displayID = {
            let screen = IslandController.notchedScreen() ?? NSScreen.main
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        }
        brightness.onChange = { [weak self] level in
            guard Pref.bool(Pref.showBrightness) else { return }
            self?.showIndicator(.brightness(level: level))
        }
        brightness.start()

        battery.onEvent = { [weak self] event in
            guard Pref.bool(Pref.showBattery) else { return }
            switch event {
            case let .pluggedIn(p): self?.showIndicator(.charging(percent: p))
            case let .low(p): self?.showIndicator(.lowBattery(percent: p))
            }
        }
        battery.onPowerChange = { [weak self] onPower in
            MainActor.assumeIsolated { self?.awake.powerChanged(onPower: onPower) }
        }
        battery.start()

        // Handle the volume and brightness keys ourselves, so only Ledge's indicator shows.
        keys.onKey = { [weak self] key, fine in
            MainActor.assumeIsolated {
                guard let self else { return false }
                switch key {
                case .volumeUp, .volumeDown, .mute:
                    guard Pref.bool(Pref.showVolume), self.volume.canControl else { return false }
                    if key == .mute { self.volume.toggleMute() }
                    else { self.volume.step(up: key == .volumeUp, fine: fine) }
                    return true
                case .brightnessUp, .brightnessDown:
                    guard Pref.bool(Pref.showBrightness), self.brightness.canControl else { return false }
                    self.brightness.step(up: key == .brightnessUp, fine: fine)
                    return true
                }
            }
        }
        keys.start()
        if !AXIsProcessTrusted() {
            // Ask once per launch; each new build of Ledge needs a fresh grant.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }

        hider.onStatusChange = { [weak self] status in self?.settingsState.hiderStatus = status }
        settingsState.onHideIconsChanged = { [weak self] on in self?.hider.apply(enabled: on) }
        settingsState.requestAccessibility = { [weak self] in self?.hider.requestPermission() }
        settingsState.revealIcons = { [weak self] in self?.hider.reveal() }
        settingsState.previewAnimation = { [weak self] in self?.islands.previewAnimation() }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.sabir.ledge.reveal"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.islands.debugReveal() }
        }
        // Debug only: `ledge-record <style> <folder>` records an animation for checking.
        DistributedNotificationCenter.default().addObserver(forName: .init("local.sabir.ledge.record"), object: nil, queue: .main) { [weak self] note in
            guard let args = (note.object as? String)?.split(separator: "|").map(String.init), args.count == 2 else { return }
            MainActor.assumeIsolated { self?.islands.debugRecord(style: args[0], to: args[1]) }
        }
        if Pref.bool(Pref.hideMenuBarIcons) {
            // Give other apps a moment to add their icons after login.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.hider.start()
                // Ask on every launch until granted (each rebuild needs a fresh grant).
                if self?.hider.status == .needsPermission {
                    self?.hider.requestPermission()
                }
                UserDefaults.standard.set(true, forKey: Pref.didFirstLaunch)
            }
        }

        // ⌃⌥⌘M shows hidden menu bar icons for a few seconds.
        revealHotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey | cmdKey, id: 1) { [weak self] in
            self?.hider.reveal()
        }

        if !Pref.bool(Pref.didFirstLaunch), !LoginItem.isEnabled {
            LoginItem.set(true) // start at login by default
            settingsState.launchAtLogin = LoginItem.isEnabled
        }
    }

    /// Indicators pop up only on the screen you're using.
    private func showIndicator(_ hud: HUD) {
        islands.islandUnderPointer()?.show(hud)
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes.saveNow()
        media.stop()
        hider.stop()
    }

    /// Opening Ledge again (e.g. from Applications or Spotlight) shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Settings open inside the island (on the screen you're using), not in a separate window.
    func showSettings() {
        settingsState.launchAtLogin = LoginItem.isEnabled
        settingsState.hiderStatus = hider.status
        islands.showSettings()
    }
}
