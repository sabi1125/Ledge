import Foundation

/// The private (undocumented) macOS functions Ledge relies on. Each feature looks its own up
/// and falls back if it's missing; this only checks them all at launch and logs any that are
/// gone, so after a macOS update the log says straight away what will stop working.
enum PrivateAPIs {
    private static let applicationServices = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let mediaRemote = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    /// (function, framework, what uses it)
    static let all: [(String, String?, String)] = [
        ("MRMediaRemoteGetNowPlayingInfo", mediaRemote, "now playing (through the perl bridge)"),
        ("DisplayServicesGetBrightness", displayServices, "brightness pop"),
        ("DisplayServicesSetBrightness", displayServices, "brightness keys"),
        ("CGSMainConnectionID", nil, "desktops (Spaces)"),
        ("CGSCopyManagedDisplaySpaces", nil, "desktops (Spaces)"),
        ("CGSAddWindowsToSpaces", nil, "external pill off full-screen desktops"),
        ("CGSRemoveWindowsFromSpaces", nil, "external pill off full-screen desktops"),
        ("CGSCopySpacesForWindows", nil, "desktops a window is on"),
        ("_AXUIElementGetWindow", applicationServices, "window switcher (window ids)"),
        ("_AXUIElementCreateWithRemoteToken", applicationServices, "window switcher (other desktops)"),
        ("GetProcessForPID", applicationServices, "window switcher (bring forward)"),
        ("_SLPSSetFrontProcessWithOptions", skyLight, "window switcher (bring forward)"),
        ("SLPSPostEventRecordTo", skyLight, "window switcher (bring forward)"),
    ]

    static func report() {
        let missing = all.filter { name, path, _ in
            let handle = path.map { dlopen($0, RTLD_NOW) } ?? dlopen(nil, RTLD_NOW)
            return handle == nil || dlsym(handle, name) == nil
        }
        if missing.isEmpty {
            LedgeLog.shared.write("private APIs: all \(all.count) found")
        } else {
            LedgeLog.shared.write("private APIs missing (macOS changed?): \(missing.map { "\($0.0) for \($0.2)" })")
        }
    }
}
