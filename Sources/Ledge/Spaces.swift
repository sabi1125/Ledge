import AppKit
import CoreGraphics

/// Reads macOS's own record of desktops ("Spaces") per screen, and pins Ledge's windows
/// to specific ones. Uses private window-server functions (the same ones tools like yabai
/// use); every call is optional, so if one is missing Ledge just falls back to hiding.
enum Spaces {
    struct DisplaySpaces {
        var uuid: String          // the screen's UUID, or "Main" when screens share Spaces
        var current: UInt64
        var currentIsFullScreen: Bool
        var normal: [UInt64]      // ordinary desktops
        var fullScreen: [UInt64]  // full-screen app desktops
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias WindowsSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen(nil, RTLD_NOW)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
    private static let mainConnection = fn("CGSMainConnectionID", MainConnection.self)
    private static let copyManaged = fn("CGSCopyManagedDisplaySpaces", CopyManagedDisplaySpaces.self)
    private static let addWindows = fn("CGSAddWindowsToSpaces", WindowsSpaces.self)
    private static let removeWindows = fn("CGSRemoveWindowsFromSpaces", WindowsSpaces.self)
    private static let copySpacesForWindows = fn("CGSCopySpacesForWindows", CopySpacesForWindows.self)

    static var canPin: Bool { mainConnection != nil && copyManaged != nil && addWindows != nil && removeWindows != nil }

    private static let fullScreenType = 4

    /// Every screen's desktops, as macOS sees them.
    static func all() -> [DisplaySpaces] {
        guard let mainConnection, let copyManaged,
              let array = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let current = d["Current Space"] as? [String: Any] else { return nil }
            let spaces = d["Spaces"] as? [[String: Any]] ?? []
            func id(_ s: [String: Any]) -> UInt64? { (s["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            func type(_ s: [String: Any]) -> Int { (s["type"] as? NSNumber)?.intValue ?? 0 }
            return DisplaySpaces(
                uuid: uuid,
                current: id(current) ?? 0,
                currentIsFullScreen: type(current) == fullScreenType,
                normal: spaces.filter { type($0) != fullScreenType }.compactMap(id),
                fullScreen: spaces.filter { type($0) == fullScreenType }.compactMap(id))
        }
    }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// The desktops belonging to a screen. When screens share Spaces, macOS lists one "Main" entry.
    static func spaces(for display: CGDirectDisplayID, in all: [DisplaySpaces]) -> DisplaySpaces? {
        let id = uuid(of: display)
        return all.first { $0.uuid.caseInsensitiveCompare(id ?? "") == .orderedSame }
            ?? (all.count == 1 ? all.first : nil)
    }

    /// Puts a window on exactly these desktops (and takes it off the others).
    static func pin(window: Int, to keep: [UInt64], removeFrom drop: [UInt64]) {
        guard let mainConnection, let addWindows, let removeWindows else { return }
        let cid = mainConnection()
        let windows = [NSNumber(value: window)] as CFArray
        if !drop.isEmpty { removeWindows(cid, windows, drop.map { NSNumber(value: $0) } as CFArray) }
        if !keep.isEmpty { addWindows(cid, windows, keep.map { NSNumber(value: $0) } as CFArray) }
    }

    /// The desktops a window is on (for checking that pinning worked).
    static func spaces(ofWindow window: Int) -> [UInt64] {
        guard let mainConnection, let copySpacesForWindows,
              let result = copySpacesForWindows(mainConnection(), 0x7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map(\.uint64Value)
    }
}
