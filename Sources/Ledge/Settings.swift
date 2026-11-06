import Foundation
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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showMusic: true,
            showVolume: true,
            showBrightness: true,
            showBattery: true,
            openOnHover: true,
            hideMenuBarIcons: true,
            showOnOtherDisplays: true,
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
