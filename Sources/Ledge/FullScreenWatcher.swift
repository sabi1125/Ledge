import AppKit
import CoreGraphics

/// Keeps track of each screen's desktops (normal and full-screen), straight from macOS.
/// The floating pills are pinned to their screen's normal desktops only, so macOS never
/// draws them on a full-screen desktop, not even mid-swipe.
@MainActor
final class FullScreenWatcher {
    /// Called whenever a screen's desktops change (one added or closed, or a different one showing).
    var onChange: (() -> Void)?
    private(set) var spaces: [Spaces.DisplaySpaces] = []
    /// Screens currently showing a full-screen desktop.
    private(set) var fullScreenDisplays = Set<CGDirectDisplayID>()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        // A new full-screen desktop is created the moment an app starts going full screen;
        // catch it quickly so the pill is taken off it during the animation (each check is one
        // tiny system call).
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func check() {
        let all = Spaces.all()
        var full = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = IslandController.displayID(of: screen),
                  let s = Spaces.spaces(for: id, in: all), s.currentIsFullScreen else { continue }
            full.insert(id)
        }
        let changed = full != fullScreenDisplays || all.map(\.normal) != spaces.map(\.normal)
            || all.map(\.fullScreen) != spaces.map(\.fullScreen)
        spaces = all
        if changed && full != fullScreenDisplays {
            LedgeLog.shared.write("spaces: full-screen desktop showing on displays \(full.sorted())")
        }
        fullScreenDisplays = full
        // Always apply: macOS adds "all desktops" windows to every new full-screen desktop.
        onChange?()
    }
}
