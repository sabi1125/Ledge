import AppKit
import ApplicationServices
import ScreenCaptureKit

/// One window in the switcher. Two Chrome windows are two of these.
struct SwitcherWindow: Identifiable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var appName: String
    var title: String
    var bounds: CGRect
    /// On a desktop you can see right now (not another desktop, not minimized).
    var isOnScreen: Bool

    static func == (a: SwitcherWindow, b: SwitcherWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.isOnScreen == b.isOnScreen
    }
}

/// Every window you could switch to, most recently used first; and bringing one to the front,
/// on whichever desktop it's on.
@MainActor
final class WindowCatalog {
    static let shared = WindowCatalog()

    /// Windows in the order you last used them (most recent first). Filled in as you switch
    /// apps; windows Ledge hasn't seen used yet follow in their on-screen order.
    private var recent: [CGWindowID] = []
    private var icons: [pid_t: NSImage] = [:]
    /// The latest preview of each window (kept, so the switcher shows one at once next time).
    private(set) var previews: [CGWindowID: CGImage] = [:]
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?

    private func captureOnLeave(_ pid: pid_t) {
        guard Pref.bool(Pref.switcherOn), Pref.bool(Pref.switcherPreviews), Self.canCapture,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let windows = Self.rawWindows(onScreenOnly: true).filter { $0.pid == pid && !notReal.contains($0.id) }
        refreshPreviews(of: windows) { _ in }
    }

    /// Windows each app says are real, standard windows (from Accessibility), by app. Browsers
    /// also have hidden helper windows and toolbar strips that look like windows to the window
    /// server; only these are shown. Kept up to date in the background, so opening stays instant.
    private var real = Set<CGWindowID>()
    /// Windows found not to be standard (helpers, strips), or not found at all.
    private var notReal = Set<CGWindowID>()
    /// Each real window's Accessibility handle, found by the scan on whichever desktop it's on.
    /// Raising a window through it takes macOS to that window's desktop, even between two windows
    /// of the same app in full screen (where making the app active does nothing: it already is).
    private var handles: [CGWindowID: AXHandle] = [:]
    private var scanTimer: Timer?
    private var scanning = false

    private init() {
        // Each time you switch apps (any way), its front window counts as the most recent.
        // Leaving an app: a fresh preview of its windows while they're still on screen, so they
        // show one in the switcher later even from another desktop (where capturing isn't possible).
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.captureOnLeave(pid) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                // Once its window is in front (a full-screen one slides in first).
                for delay in [0.1, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.noteFront(of: pid) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.scan() }
            }
        }
    }

    /// Starts watching which windows you use (call once at launch).
    func start() {
        scan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scanTimer?.tolerance = 1
    }

    /// Asks the apps (in the background) which of their windows are standard windows. Only windows
    /// not looked at yet are checked, and each answer is kept; windows on other desktops are looked
    /// up the way AltTab does it (see `axWindowsAnywhere`), and only when there's one to find.
    func scan() {
        guard !scanning else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let candidates = Self.rawWindows(onScreenOnly: false)
            .filter { $0.pid != me && ($0.isOnScreen || !Spaces.spaces(ofWindow: Int($0.id)).isEmpty) }
        let alive = Set(candidates.map(\.id))
        real.formIntersection(alive)
        notReal.formIntersection(alive)
        // Forget closed windows and quit apps (previews are a few MB each).
        let allIDs = Set(Self.rawWindows(onScreenOnly: false).map(\.id))
        previews = previews.filter { allIDs.contains($0.key) }
        titleCache = titleCache.filter { allIDs.contains($0.key) }
        handles = handles.filter { allIDs.contains($0.key) }
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        icons = icons.filter { runningPIDs.contains($0.key) }
        let unknown = candidates.filter { !real.contains($0.id) && !notReal.contains($0.id) }
        guard !unknown.isEmpty else { return }
        scanning = true
        let byApp = Dictionary(grouping: unknown, by: \.pid)
        DispatchQueue.global(qos: .utility).async {
            var yes = Set<CGWindowID>(), no = Set<CGWindowID>()
            var newHandles: [CGWindowID: AXHandle] = [:]
            var titles: [CGWindowID: String] = [:]
            var reasons: [String] = []
            for (pid, windows) in byApp {
                var left = Set(windows.map(\.id))
                func classify(_ found: [(AXUIElement, CGWindowID)]) {
                    for (element, id) in found where left.contains(id) {
                        left.remove(id)
                        if Self.isStandard(element) {
                            yes.insert(id)
                            newHandles[id] = AXHandle(element: element)
                            var value: CFTypeRef?
                            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
                               let t = value as? String, !t.isEmpty { titles[id] = t }
                        } else {
                            no.insert(id)
                            var sub: CFTypeRef?
                            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
                            reasons.append("\(pid)/\(id): subrole \(sub as? String ?? "none")")
                        }
                    }
                }
                let listed = Self.axWindows(of: pid)
                // The app didn't answer at all: leave its windows to the size rule.
                if listed.isEmpty && !Self.answers(pid) { continue }
                classify(listed)
                // On this desktop, the app lists every window: one it didn't list isn't a real one.
                // (Only when it did list some: a busy app that listed none is asked again next time.)
                for w in windows where !listed.isEmpty && w.isOnScreen && left.contains(w.id) {
                    left.remove(w.id); no.insert(w.id); reasons.append("\(w.appName)/\(w.id): on screen, not listed")
                }
                // On other desktops: look them up, then anything still not found isn't real.
                let offScreen = left.filter { id in windows.contains { $0.id == id && !$0.isOnScreen } }
                if !offScreen.isEmpty { classify(Self.axWindowsAnywhere(of: pid, wanted: offScreen)) }
                let missing = left.filter { id in windows.contains { $0.id == id && !$0.isOnScreen } }
                for id in missing { reasons.append("\(pid)/\(id): not found anywhere") }
                no.formUnion(missing)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.real.formUnion(yes)
                    self.handles.merge(newHandles) { _, new in new }
                    self.handles = self.handles.filter { self.real.contains($0.key) }
                    self.notReal.formUnion(no)
                    for (id, t) in titles { self.titleCache[id] = t }
                    self.scanning = false
                    if !reasons.isEmpty { LedgeLog.shared.write("switcher: not windows: \(reasons)") }
                }
            }
        }
    }

    /// The app answers Accessibility at all (a hung or protected app doesn't).
    nonisolated private static func answers(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value) == .success
    }

    /// A normal window (not a toolbar strip, popover, tooltip or hidden helper).
    nonisolated private static func isStandard(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    /// The app's windows on every desktop. Accessibility normally lists only the ones on the
    /// desktop you're on; the others can still be reached by their element numbers, which is how
    /// AltTab finds them.
    nonisolated private static func axWindowsAnywhere(of pid: pid_t, wanted: Set<CGWindowID>) -> [(AXUIElement, CGWindowID)] {
        var result: [(AXUIElement, CGWindowID)] = []
        var seen = Set<CGWindowID>()
        guard let create = Private.createWithRemoteToken else { return result }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: Int32(pid), toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        for elementID in UInt64(0)..<UInt64(600) {
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == kAXWindowRole else { continue }
            var id: CGWindowID = 0
            guard let getWindow = Private.axGetWindow, getWindow(element, &id) == .success, id != 0,
                  !seen.contains(id) else { continue }
            seen.insert(id)
            result.append((element, id))
            // Stop as soon as every window asked about is found.
            if wanted.isSubset(of: seen) { break }
        }
        return result
    }

    private func noteFront(of pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let id = Self.focusedWindow(of: pid) else { return }
        use(id)
    }

    /// The app's focused window (from Accessibility, so a full-screen one counts too), else its
    /// front window on screen.
    private static func focusedWindow(of pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() {
            var id: CGWindowID = 0
            if let getWindow = Private.axGetWindow, getWindow(element as! AXUIElement, &id) == .success, id != 0 { return id }
        }
        return rawWindows(onScreenOnly: true).first(where: { $0.pid == pid })?.id
    }

    /// This window was just used: it goes to the front of the order.
    func use(_ id: CGWindowID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }
    }

    // MARK: Listing

    /// The windows to show: every desktop, or only what's on screen now.
    func windows(allDesktops: Bool) -> [SwitcherWindow] {
        let t0 = Date()
        defer { LedgeLog.shared.write("switcher: gathering windows took \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        var list = Self.rawWindows(onScreenOnly: !allDesktops)
        // The window you're in right now is always first, so a quick tap goes back to the one before:
        // the active app's focused window, or (if that isn't one of these) its front one here.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let focused = Self.focusedWindow(of: front)
            if let id = focused, list.contains(where: { $0.id == id }) { use(id) }
            else if let first = list.first(where: { $0.pid == front }) { use(first.id) }
            LedgeLog.shared.write("switcher: in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (focused window \(focused.map(String.init) ?? "none"), listed \(focused.map { id in list.contains { $0.id == id } } ?? false))")
        }
        if allDesktops {
            // Off-screen windows that are on some desktop (not leftovers and hidden helpers).
            list = list.filter { $0.isOnScreen || !Spaces.spaces(ofWindow: Int($0.id)).isEmpty }
        }
        // Only real windows: for apps Ledge has already asked, the ones the app calls standard
        // windows (so a browser's hidden helper window or toolbar strip isn't a second entry).
        // An app not asked yet (just opened) shows its windows that are big enough to be real.
        list = list.filter { w in
            if real.contains(w.id) { return true }
            if notReal.contains(w.id) { return false }
            // Not checked yet (just opened): big enough to be a real window.
            return w.bounds.width >= 200 && w.bounds.height >= 150
        }
        // Check the new ones now, for next time.
        DispatchQueue.main.async { self.scan() }
        // Most recently used first; the rest keep the system's front-to-back order.
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = list.enumerated().sorted { a, b in
            let ra = rank[a.element.id], rb = rank[b.element.id]
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        // Titles the window server gave, or last time's: never waiting on apps here (that's what
        // made the switcher slow to show). Fresh ones come in afterwards (`readTitles`).
        return ordered.map { w in
            var w = w
            if w.title.isEmpty { w.title = titleCache[w.id] ?? "" } else { titleCache[w.id] = w.title }
            return w
        }
    }

    /// Each window's title as last seen (for showing the switcher at once).
    private var titleCache: [CGWindowID: String] = [:]

    /// Reads the titles the window server didn't give (from Accessibility), in the background.
    /// `done` runs on the main thread with what it found.
    func readTitles(for list: [SwitcherWindow], done: @escaping ([CGWindowID: String]) -> Void) {
        let pids = Array(Set(list.map(\.pid)))
        DispatchQueue.global(qos: .userInitiated).async {
            var titles: [CGWindowID: String] = [:]
            for pid in pids {
                for (element, id) in Self.axWindows(of: pid) {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
                       let title = value as? String, !title.isEmpty { titles[id] = title }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (id, t) in titles { self.titleCache[id] = t }
                    done(titles)
                }
            }
        }
    }

    func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = image
        return image
    }

    /// Windows from the window server: normal app windows only (no menus, panels or Ledge).
    private static func rawWindows(onScreenOnly: Bool) -> [SwitcherWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var regular: [pid_t: (Bool, String)] = [:]
        func app(_ pid: pid_t) -> (Bool, String) {
            if let known = regular[pid] { return known }
            let a = NSRunningApplication(processIdentifier: pid)
            let value = (a?.activationPolicy == .regular, a?.localizedName ?? "")
            regular[pid] = value
            return value
        }
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"], width >= 100, height >= 60 else { return nil }
            let (isRegular, name) = app(pid)
            guard isRegular else { return nil }
            // Notes (or Reminders) running hidden in the background for Ledge: not a window of yours.
            if let running = NSRunningApplication(processIdentifier: pid), AppleScriptBridge.isBackgroundHelper(running) { return nil }
            return SwitcherWindow(id: id, pid: pid, appName: name,
                                  title: w[kCGWindowName as String] as? String ?? "",
                                  bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: width, height: height),
                                  isOnScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    // MARK: Switching

    /// Brings the window to the front (and its desktop, if it's on another one), and makes it
    /// the one that has the keyboard.
    func focus(_ window: SwitcherWindow) {
        use(window.id)
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        // On another desktop (or behind a full-screen app): only the window server's "bring this
        // window forward", like AltTab and Mission Control. That moves to its desktop; making an
        // app active the normal way first keeps you where you are instead.
        let onScreenNow = Self.rawWindows(onScreenOnly: true).contains { $0.id == window.id }
        // Another window of the app you're already in, on another desktop (two Firefox windows,
        // each full screen): making the app active does nothing, so raise that exact window, which
        // takes macOS to its desktop.
        if !onScreenNow, NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid {
            let forward = Self.bringForward(pid: window.pid, window: window.id)
            let element = handles[window.id]?.element
                ?? Self.axWindowsAnywhere(of: window.pid, wanted: [window.id]).first(where: { $0.1 == window.id })?.0
            var raised = false
            if let element {
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            LedgeLog.shared.write("switcher: to another \(window.appName) window on another desktop (window server \(forward), raised \(raised))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let visible = Self.rawWindows(onScreenOnly: true).contains { $0.id == window.id }
                LedgeLog.shared.write("switcher: \(window.appName)'s window \(visible ? "is on screen now" : "still isn't on screen")")
            }
            return
        }
        if !onScreenNow {
            // The window server's "bring this window forward" (that's how it gets into full screen)…
            let forward = Self.bringForward(pid: window.pid, window: window.id)
            // …and making its app active the way the Dock does, which moves to its desktop (that's
            // how it gets out of full screen). Since macOS 14 only the active app can hand that over.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.yieldActivation(to: app)
            app.activate(options: [.activateAllWindows])
            LedgeLog.shared.write("switcher: to \(window.appName) on another desktop (window server \(forward))")
            // Once its desktop is showing: that exact window in front (two Chromes on different
            // desktops: the one you picked, not the other).
            let handle = handles[window.id]?.element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let element = handle ?? Self.axWindows(of: window.pid).first(where: { $0.1 == window.id })?.0 {
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
                let visible = Self.rawWindows(onScreenOnly: true).contains { $0.id == window.id }
                LedgeLog.shared.write("switcher: \(window.appName)'s window \(visible ? "is on screen now" : "still isn't on screen")")
            }
            return
        }
        // Since macOS 14 an app can only make another app active if it's the active one itself
        // and hands over: so Ledge steps in front for a moment, then gives way to the window's app.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.yieldActivation(to: app)
        // The window server's way: works on other desktops too (what macOS's own Mission Control does).
        let forward = Self.bringForward(pid: window.pid, window: window.id)
        // And Accessibility's "raise", which puts that exact window in front of the app's others.
        var raised = false
        if let element = Self.axWindows(of: window.pid).first(where: { $0.1 == window.id })?.0 {
            raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        let activated = app.activate(from: NSRunningApplication.current, options: [])
            || app.activate(options: [.activateAllWindows])
        LedgeLog.shared.write("switcher: to \(window.appName) (window server \(forward), raised \(raised), activated \(activated))")
        // Check a moment later that it really came to the front, and say so if it didn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front != window.pid {
                LedgeLog.shared.write("switcher: \(window.appName) didn't come to the front (front is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
                // One more try, now that Ledge isn't in the middle of anything.
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    /// The app's windows from Accessibility, each with its window server number.
    nonisolated private static func axWindows(of pid: pid_t) -> [(AXUIElement, CGWindowID)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.compactMap { e in
            var id: CGWindowID = 0
            guard let getWindow = Private.axGetWindow, getWindow(e, &id) == .success, id != 0 else { return nil }
            return (e, id)
        }
    }

    /// The window server's private calls for "bring this exact window to the front".
    @discardableResult
    private static func bringForward(pid: pid_t, window: CGWindowID) -> String {
        guard let getPSN = Private.getProcessForPID else { return "no GetProcessForPID" }
        guard let setFront = Private.setFrontProcess else { return "no SetFrontProcess" }
        guard let post = Private.postEventRecord else { return "no PostEventRecord" }
        var psn = ProcessSerialNumber()
        let status = getPSN(pid, &psn)
        guard status == noErr else { return "GetProcessForPID \(status)" }
        let front = setFront(&psn, window, 0x200) // kCPSUserGenerated
        // Make it the key window: two synthetic "window activated" records, as the system sends.
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        var wid = window
        withUnsafeBytes(of: &wid) { raw in for i in 0..<4 { bytes[0x3C + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
        return front == .success ? "ok" : "SetFront \(front.rawValue)"
    }

    // MARK: Previews

    /// Screen Recording is allowed (window previews and titles need it).
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for Screen Recording (macOS shows its prompt once; after that it's in System Settings).
    static func askForCapture() {
        // macOS only shows its own prompt the first time; after that it's a switch in System Settings,
        // so that page opens too.
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Takes fresh previews of these windows in the background; `done` runs on the main
    /// thread for each one as it comes in.
    func refreshPreviews(of windows: [SwitcherWindow], done: @escaping (CGWindowID) -> Void) {
        // Only windows on screen: macOS can't capture ones on another desktop (it refuses every
        // time). Those keep the preview taken when you last left them (see `captureOnLeave`).
        let visible = windows.filter(\.isOnScreen)
        guard !visible.isEmpty else { return }
        guard Self.canCapture else {
            LedgeLog.shared.write("switcher: no previews (Screen Recording isn't allowed for Ledge)")
            return
        }
        let wanted = Set(visible.map(\.id))
        Task { @MainActor in
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            catch {
                LedgeLog.shared.write("switcher: previews failed: \(error.localizedDescription)")
                return
            }
            let matches = content.windows.filter { wanted.contains($0.windowID) }
            for w in matches {
                let config = SCStreamConfiguration()
                let scale: CGFloat = 2
                // The biggest preview the switcher draws is 420 pt wide: no need for more.
                let fit = min(1, 440 / max(w.frame.width, 1))
                config.width = Int(w.frame.width * fit * scale)
                config.height = Int(w.frame.height * fit * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let id = w.windowID
                Task { @MainActor in
                    let image: CGImage
                    do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
                    catch {
                        LedgeLog.shared.write("switcher: preview of window \(id) failed: \(error.localizedDescription)")
                        return
                    }
                    self.previews[id] = image
                    done(id)
                }
            }
        }
    }
}

/// Private calls (looked up at run time, so Ledge still runs if one is missing).
private enum Private {
    typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    static let createWithRemoteToken: CreateWithToken? = sym("_AXUIElementCreateWithRemoteToken", "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    static let axGetWindow: AXGetWindow? = sym("_AXUIElementGetWindow", "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    static let getProcessForPID: GetPSN? = sym("GetProcessForPID", "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    static let setFrontProcess: SetFront? = sym("_SLPSSetFrontProcessWithOptions", "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    static let postEventRecord: PostRecord? = sym("SLPSPostEventRecordTo", "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")

    private static func sym<T>(_ name: String, _ path: String) -> T? {
        guard let handle = dlopen(path, RTLD_NOW), let s = dlsym(handle, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
}

/// An Accessibility handle for a window, passed between the scan's queue and the main thread.
struct AXHandle: @unchecked Sendable {
    let element: AXUIElement
}
