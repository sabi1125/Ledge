import AppKit
import CoreGraphics

/// Notices which screens have a full-screen app or video on them, so the floating pill on
/// that screen can step out of the way. Other screens keep their pill.
@MainActor
final class FullScreenWatcher {
    /// Called with the screens that currently have something full screen.
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    private(set) var fullScreenDisplays = Set<CGDirectDisplayID>()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// When each screen last had something full screen; its pill comes back only after a moment.
    private var lastSeen: [CGDirectDisplayID: Date] = [:]
    private let showAgainAfter: TimeInterval = 0.3
    /// Apps seen in full screen; watched until they leave it, even after you switch to another app.
    private var watchedPIDs = Set<pid_t>()

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Check right away, then keep checking quickly through the full-screen animation.
                MainActor.assumeIsolated { self?.check() }
                for delay in [0.15, 0.35, 0.6, 1.0, 1.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.check() }
                }
            })
        }
        // Videos can go full screen without switching apps or Spaces, so also look often.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func check() {
        let found = findFullScreen()
        let now = Date()
        for (display, _) in found { lastSeen[display] = now }
        // Hide at once; show again only once full screen has clearly ended (no flicker on the way out).
        let active = Set(lastSeen.filter { now.timeIntervalSince($0.value) < showAgainAfter }.keys)
        guard active != fullScreenDisplays else { return }
        for display in active.subtracting(fullScreenDisplays) {
            LedgeLog.shared.write("fullscreen: \(found[display] ?? "an app") is full screen on display \(display), hiding its pill")
        }
        for display in fullScreenDisplays.subtracting(active) {
            LedgeLog.shared.write("fullscreen: display \(display) back to normal, showing its pill")
        }
        fullScreenDisplays = active
        onChange?(active)
    }

    // MARK: Finding full-screen windows

    /// Screens with something full screen, and the app's name.
    private func findFullScreen() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        if AXIsProcessTrusted() {
            // A full-screen window stays full screen when you swipe to another desktop; it only
            // counts while it's actually on screen.
            let visible = Self.onScreenWindows()
            // Ask macOS directly: the front app, plus apps that were full screen recently.
            var candidates = watchedPIDs
            if let front = NSWorkspace.shared.frontmostApplication { candidates.insert(front.processIdentifier) }
            for pid in candidates {
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    watchedPIDs.remove(pid); continue
                }
                let frames = Self.fullScreenWindowFrames(pid)
                if frames.isEmpty { watchedPIDs.remove(pid); continue }
                watchedPIDs.insert(pid)
                for frame in frames {
                    let showing = visible.contains { $0.pid == pid && Self.sameRect($0.bounds, frame) }
                    if showing, let display = Self.display(containingTopLeftRect: frame) {
                        result[display] = app.localizedName ?? "an app"
                    }
                }
            }
        }
        // Backup: another app's window exactly covering a screen.
        for (display, owner) in Self.screenCoveringWindows() where result[display] == nil {
            // On a screen without a menu bar, a maximized window covers it too; with Accessibility,
            // only count it if macOS says that app really is full screen.
            if !AXIsProcessTrusted() || !Self.fullScreenWindowFrames(owner.pid).isEmpty {
                result[display] = owner.name
            }
        }
        return result
    }

    /// Ordinary windows on the desktops currently showing (top-left origin).
    private static func onScreenWindows() -> [(pid: pid_t, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"] else { return nil }
            return (pid, CGRect(x: x, y: y, width: wd, height: ht))
        }
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    /// Frames (top-left origin) of an app's windows that are in full-screen mode.
    static func fullScreenWindowFrames(_ pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var frames: [CGRect] = []
        for window in windows {
            var full: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success,
                  (full as? Bool) == true else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            frames.append(CGRect(origin: p, size: s))
        }
        return frames
    }

    /// Screens in top-left coordinates (the system used by window lists and Accessibility).
    private static func screensTopLeft() -> [(CGDirectDisplayID, CGRect)] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { s in
            guard let id = IslandController.displayID(of: s) else { return nil }
            return (id, CGRect(x: s.frame.minX, y: primary.frame.maxY - s.frame.maxY,
                               width: s.frame.width, height: s.frame.height))
        }
    }

    private static func display(containingTopLeftRect r: CGRect) -> CGDirectDisplayID? {
        let center = CGPoint(x: r.midX, y: r.midY)
        return screensTopLeft().first { $0.1.contains(center) }?.0
    }

    /// Other apps' windows that exactly cover a screen, by screen.
    private static func screenCoveringWindows() -> [CGDirectDisplayID: (pid: pid_t, name: String)] {
        let screens = screensTopLeft()
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [CGDirectDisplayID: (pid_t, String)] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"] else { continue }
            for (id, s) in screens where abs(s.minX - x) < 2 && abs(s.minY - y) < 2
                && abs(s.width - wd) < 2 && abs(s.height - ht) < 2 {
                result[id] = (pid, w[kCGWindowOwnerName as String] as? String ?? "an app")
            }
        }
        return result
    }
}
