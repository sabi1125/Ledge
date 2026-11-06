import Foundation
import LedgeCore
import ServiceManagement

/// UserDefaults keys and defaults, shared by the app and the settings window.
enum Pref {
    static let showMusic = "showMusic"
    static let showVolume = "showVolume"
    static let showBrightness = "showBrightness"
    static let showBattery = "showBattery"
    static let openOnHover = "openOnHover"
    static let hideMenuBarIcons = "hideMenuBarIcons"
    static let didFirstLaunch = "didFirstLaunch"
    static let showOnOtherDisplays = "showOnOtherDisplays"
    static let pageCalendar = "pageCalendar"
    static let pageTimer = "pageTimer"
    static let pageNotes = "pageNotes"
    static let haptics = "haptics"
    static let awakeDefaultMinutes = "awakeDefaultMinutes"
    static let awakeKeepScreenOn = "awakeKeepScreenOn"
    static let awakeWhileCharging = "awakeWhileCharging"

    /// The island pages switched on in settings (Music uses "Show what's playing").
    static var enabledPages: Set<IslandPage> {
        var pages = Set<IslandPage>()
        if bool(showMusic) { pages.insert(.music) }
        if bool(pageCalendar) { pages.insert(.calendar) }
        if bool(pageTimer) { pages.insert(.timer) }
        if bool(pageNotes) { pages.insert(.notes) }
        return pages
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showMusic: true,
            showVolume: true,
            showBrightness: true,
            showBattery: true,
            openOnHover: true,
            hideMenuBarIcons: true,
            showOnOtherDisplays: true,
            pageCalendar: true,
            pageTimer: true,
            pageNotes: true,
            haptics: true,
            awakeDefaultMinutes: 60,
            awakeKeepScreenOn: true,
            awakeWhileCharging: false,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Ledge: login item change failed: \(error.localizedDescription)")
        }
    }
}
