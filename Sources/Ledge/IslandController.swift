import AppKit
import Combine
import LedgeCore
import SwiftUI

/// A borderless panel that floats above the menu bar, centered on the notch.
final class IslandPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // No .fullScreenAuxiliary: the island stays out of full-screen apps and videos.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// Only takes keyboard focus for typing in Notes, so clicking music buttons never
    /// pulls focus away from the app you're working in.
    var allowsKey: () -> Bool = { false }
    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
    // Allow the window to sit over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks work on the first press, without needing to focus the panel first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns one screen's island panel, and turns pointer movement into hover,
/// clicks-through and swipes. `IslandManager` keeps one per screen.
@MainActor
final class IslandController {
    let displayID: CGDirectDisplayID
    let model: IslandModel
    let calendar: CalendarStore
    let notes: NotesStore
    let timer: TimerStore
    let awake: AwakeStore
    let settings: SettingsState
    let updater: Updater
    private var panel: IslandPanel?
    /// The resting island (the notch, or the idle pill), in global screen coordinates.
    private var anchorRect: NSRect = .zero
    private var screenTop: CGFloat = 0
    private var monitors: [Any] = []
    private var swipe = SwipeDetector()
    private var cancellables = Set<AnyCancellable>()
    private let openSettings: () -> Void

    init(displayID: CGDirectDisplayID, model: IslandModel, calendar: CalendarStore, notes: NotesStore,
         timer: TimerStore, awake: AwakeStore, settings: SettingsState, updater: Updater,
         openSettings: @escaping () -> Void) {
        self.timer = timer
        self.awake = awake
        self.settings = settings
        self.updater = updater
        self.displayID = displayID
        self.model = model
        self.calendar = calendar
        self.notes = notes
        self.openSettings = openSettings
    }

    func start(on screen: NSScreen) {
        layout(on: screen)
        // Re-check the pointer when the shape changes (e.g. the island collapses under a still pointer).
        model.$shape
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updatePointer() } }
            .store(in: &cancellables)
        installMonitors()

        // Leaving Notes or closing: hand keyboard focus back to the app you were in.
        model.onEndTyping = { [weak self] in self?.giveBackFocus() }
        // Settings takes keyboard focus while open (for Esc), and gives it back after.
        model.onSettingsShown = { [weak self] shown in
            guard let self, let panel = self.panel else { return }
            if shown { panel.makeKey() } else { self.giveBackFocus() }
        }
    }

    /// Debug only: saves the island as images every few milliseconds, to check animations.
    func recordFrames(to dir: String, seconds: TimeInterval = 2.4, every interval: TimeInterval = 0.04) {
        guard let view = panel?.contentView else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = Date()
        var index = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            MainActor.assumeIsolated {
                guard Date().timeIntervalSince(start) < seconds,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { t.invalidate(); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: String(format: "%@/%03d.png", dir, index)))
                index += 1
            }
        }
    }

    private func giveBackFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if !isHidden { panel.orderFrontRegardless() }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        cancellables = []
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: Screen

    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { hasNotch($0) }
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    func contains(point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == displayID }) else { return false }
        return screen.frame.contains(point)
    }

    /// Places the island: in the notch on the MacBook screen, as a pill in the middle of the
    /// menu bar on any other screen.
    func layout(on screen: NSScreen) {
        let frame = screen.frame
        let style: IslandStyle
        let metrics: NotchMetrics
        if Self.hasNotch(screen), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            style = .notch
            let notchWidth = frame.width - left.width - right.width
            metrics = NotchMetrics(width: notchWidth, height: screen.safeAreaInsets.top)
            anchorRect = NSRect(x: frame.minX + left.width, y: frame.maxY - metrics.height,
                                width: notchWidth, height: metrics.height)
        } else {
            style = .floating
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            metrics = .floatingPill(menuBarHeight: menuBar)
            let gap = IslandLayout.topGap(style: .floating)
            anchorRect = NSRect(x: frame.midX - metrics.width / 2, y: frame.maxY - gap - metrics.height,
                                width: metrics.width, height: metrics.height)
        }
        screenTop = frame.maxY
        if model.style != style { model.style = style }
        if model.notch != metrics { model.notch = metrics }

        let size = IslandLayout.panelSize(notch: metrics, style: style)
        let panelFrame = NSRect(x: anchorRect.midX - size.width / 2, y: frame.maxY - size.height,
                                width: size.width, height: size.height)
        if panel == nil {
            let p = IslandPanel(frame: panelFrame)
            p.allowsKey = { [weak self] in
                MainActor.assumeIsolated {
                    guard let m = self?.model else { return false }
                    return m.isShowingSettings || (m.isExpanded && m.page == .notes)
                }
            }
            // Clicking anywhere else ends typing, and the island closes.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.isTyping = false }
            }
            let root = IslandRootView(model: model, calendar: calendar, notes: notes, timer: timer, awake: awake,
                                      settings: settings, updater: updater, openSettings: openSettings)
            let host = FirstMouseHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            p.contentView = host
            panel = p
        }
        panel?.setFrame(panelFrame, display: true)
        if !isHidden { panel?.orderFrontRegardless() }
    }

    /// Hidden while something is full screen on this screen. Only used when pinning to
    /// desktops isn't available; with pinning, macOS itself keeps the pill off full-screen desktops.
    private(set) var isSuppressed = false
    private var isHidden: Bool { isSuppressed }
    private var loggedPin = false

    func setSuppressed(_ hidden: Bool) {
        guard hidden != isSuppressed, let panel else { return }
        isSuppressed = hidden
        if hidden {
            if model.isExpanded { model.close() }
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Keeps the pill off this screen's full-screen desktops. The pill stays an "all desktops"
    /// window, so it stays perfectly still when you swipe between normal desktops; macOS just
    /// leaves it out of the full-screen ones, including while you swipe into them.
    func keepOff(fullScreen spaces: Spaces.DisplaySpaces) {
        guard let panel else { return }
        let current = Spaces.spaces(ofWindow: panel.windowNumber)
        let onFullScreen = current.filter { spaces.fullScreen.contains($0) }
        let missingNormal = spaces.normal.filter { !current.contains($0) }
        guard !onFullScreen.isEmpty || !missingNormal.isEmpty else { return }
        Spaces.pin(window: panel.windowNumber, to: missingNormal, removeFrom: onFullScreen)
        if !loggedPin || !onFullScreen.isEmpty {
            loggedPin = true
            LedgeLog.shared.write("spaces: pill on display \(displayID) taken off full-screen desktops \(onFullScreen); now on \(Spaces.spaces(ofWindow: panel.windowNumber))")
        }
    }

    /// The area that currently counts as "the island" for the pointer.
    private func hitRect() -> NSRect {
        guard anchorRect != .zero else { return .zero }
        let size = IslandLayout.size(for: model.shape, notch: model.notch, style: model.style, compactWidth: model.compactWidth)
        let w = max(size.width, anchorRect.width)
        let h = max(size.height, anchorRect.height) + IslandLayout.topGap(style: model.style)
        // A little slack on the sides, and an extra point above so the very top edge counts.
        return NSRect(x: anchorRect.midX - w / 2 - 6, y: screenTop - h - 4, width: w + 12, height: h + 5)
    }

    // MARK: Pointer

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updatePointer() }
            return e
        }) { monitors.append(l) }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handleScroll(e) }
            return e
        }) { monitors.append(s) }
        // Esc closes the open island or settings (e.g. when done typing a note).
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.model.isShowingSettings { self.model.closeSettings(); return true }
                guard self.model.isExpanded else { return false }
                self.model.close()
                return true
            }
            return handled ? nil : e
        }) { monitors.append(k) }
        // A click anywhere else closes settings.
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isShowingSettings,
                      !self.hitRect().contains(NSEvent.mouseLocation) else { return }
                self.model.closeSettings()
            }
        }) { monitors.append(c) }
    }

    private func updatePointer() {
        guard let panel, panel.isVisible, !isHidden else { return }
        var inside = hitRect().contains(NSEvent.mouseLocation)
        // While a mouse button is held (dragging a window, selecting text, resizing), passing
        // over the notch shouldn't open the island. A drag that started on the island
        // (like scrubbing) keeps working.
        if NSEvent.pressedMouseButtons != 0 && !model.isHovering { inside = false }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside { model.pointerEntered() } else { model.pointerExited() }
    }

    private func handleScroll(_ e: NSEvent) {
        let open = model.shape == .expanded
        // While typing, the pointer may be anywhere; only swipe when it's over the island.
        guard open || model.hasMedia, hitRect().contains(NSEvent.mouseLocation), e.momentumPhase == [] else { return }
        let phase: SwipeDetector.Phase
        if e.phase.contains(.began) { phase = .began }
        else if e.phase.contains(.ended) || e.phase.contains(.cancelled) { phase = .ended }
        else if e.phase.contains(.changed) { phase = .changed }
        else { return } // mouse wheels: no swipes
        // Physical finger direction, whatever the "natural scrolling" setting.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let dy = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
        // Open island: swipe between Music, Calendar and Notes. Small music view: skip tracks.
        switch swipe.handle(dx: dx, dy: dy, phase: phase) {
        case .left: open ? model.swipePage(forward: true) : model.onCommand?(.next)
        case .right: open ? model.swipePage(forward: false) : model.onCommand?(.previous)
        case nil: break
        }
    }
}
