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

/// Owns the panel, keeps it on the notched screen, and turns pointer
/// movement into hover, clicks-through and swipes.
@MainActor
final class IslandController {
    let model: IslandModel
    let calendar: CalendarStore
    let notes: NotesStore
    private var panel: IslandPanel?
    private var notchRect: NSRect = .zero // in global screen coordinates
    private var monitors: [Any] = []
    private var swipe = SwipeDetector()
    private var cancellables = Set<AnyCancellable>()
    private let openSettings: () -> Void

    init(model: IslandModel, calendar: CalendarStore, notes: NotesStore, openSettings: @escaping () -> Void) {
        self.model = model
        self.calendar = calendar
        self.notes = notes
        self.openSettings = openSettings
    }

    func start() {
        layout()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        // Re-check the pointer when the shape changes (e.g. the island collapses under a still pointer).
        model.$shape
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updatePointer() } }
            .store(in: &cancellables)
        installMonitors()

        // Leaving Notes or closing: hand keyboard focus back to the app you were in.
        model.onEndTyping = { [weak self] in
            guard let panel = self?.panel, panel.isKeyWindow else { return }
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Screen

    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    private func layout() {
        guard let screen = Self.notchedScreen(),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            // No notch visible (e.g. lid closed on an external display): stay hidden.
            panel?.orderOut(nil)
            return
        }
        let frame = screen.frame
        let notchWidth = frame.width - left.width - right.width
        let metrics = NotchMetrics(width: notchWidth, height: screen.safeAreaInsets.top)
        model.notch = metrics
        notchRect = NSRect(x: frame.minX + left.width, y: frame.maxY - metrics.height,
                           width: notchWidth, height: metrics.height)

        let size = IslandLayout.panelSize(notch: metrics)
        let panelFrame = NSRect(x: notchRect.midX - size.width / 2, y: frame.maxY - size.height,
                                width: size.width, height: size.height)
        if panel == nil {
            let p = IslandPanel(frame: panelFrame)
            p.allowsKey = { [weak self] in
                MainActor.assumeIsolated { self?.model.isExpanded == true && self?.model.page == .notes }
            }
            // Clicking anywhere else ends typing, and the island closes.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.isTyping = false }
            }
            let root = IslandRootView(model: model, calendar: calendar, notes: notes, openSettings: openSettings)
            let host = FirstMouseHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            p.contentView = host
            panel = p
        }
        panel?.setFrame(panelFrame, display: true)
        panel?.orderFrontRegardless()
    }

    /// The area that currently counts as "the island" for the pointer.
    private func hitRect() -> NSRect {
        guard notchRect != .zero else { return .zero }
        let size = IslandLayout.size(for: model.shape, notch: model.notch)
        let w = max(size.width, notchRect.width)
        let h = max(size.height, notchRect.height)
        let top = notchRect.maxY
        // A little slack on the sides, and an extra point above so the very top edge counts.
        return NSRect(x: notchRect.midX - w / 2 - 6, y: top - h - 4, width: w + 12, height: h + 5)
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
        // Esc closes the open island (e.g. when done typing a note).
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.isExpanded else { return false }
                self.model.close()
                return true
            }
            return handled ? nil : e
        }) { monitors.append(k) }
    }

    private func updatePointer() {
        guard let panel, panel.isVisible else { return }
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
