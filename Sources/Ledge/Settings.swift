import Foundation
import LedgeCore
import ServiceManagement

/// UserDefaults keys and defaults, shared by the app and the settings window.
enum Pref {
    static let showMusic = "showMusic"
    static let showVolume = "showVolume"
    static let showBrightness = "showBrightness"
    static let showBattery = "showBattery"
    /// A countdown beside the notch before a meeting, then a pill with Join.
    static let meetingAlerts = "meetingAlerts"
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
    static let pomoFocus = "pomoFocusMinutes"
    static let pomoShort = "pomoShortMinutes"
    static let pomoLong = "pomoLongMinutes"
    static let pomoSessions = "pomoSessions"
    static let pomoAutoStart = "pomoAutoStart"
    /// The window switcher: on or off, previews, and every desktop or only this one.
    static let switcherOn = "switcherOn"
    static let switcherPreviews = "switcherPreviews"
    static let switcherAllDesktops = "switcherAllDesktops"
    /// The Notes page shows its list of notes (⌥⌘S or the sidebar button hides it).
    static let notesSidebar = "notesSidebar"
    /// The Notes page's text box takes Vim keys (normal, insert and visual mode).
    static let vimMotions = "vimMotions"
    /// The tray: drop files on the island to hold them (up to 5); ⌃⌥F shows it.
    static let trayEnabled = "trayEnabled"

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
            meetingAlerts: true,
            openOnHover: true,
            hideMenuBarIcons: false,
            showOnOtherDisplays: true,
            pageCalendar: true,
            pageTimer: true,
            pageNotes: true,
            haptics: true,
            awakeDefaultMinutes: 60,
            awakeKeepScreenOn: true,
            awakeWhileCharging: false,
            pomoFocus: 25,
            pomoShort: 5,
            pomoLong: 15,
            pomoSessions: 4,
            pomoAutoStart: true,
            notesSidebar: true,
            switcherOn: true,
            switcherPreviews: true,
            switcherAllDesktops: true,
            SwitcherStyle.key: SwitcherStyle.strip.rawValue,
            vimMotions: false,
            trayEnabled: true,
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
