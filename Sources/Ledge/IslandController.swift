import AppKit
import Carbon
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
        // No .fullScreenAuxiliary here: floating pills stay out of full-screen desktops (they're
        // revealed from the top edge). The notch island adds it in `start(on:)`.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// Only takes keyboard focus for typing (Notes, quick add) and settings, so clicking music buttons never
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
    private var revealPanel: IslandPanel?
    /// The enlarged note: a big panel in the middle of this screen (made the first time it's used).
    private var notePanel: IslandPanel?
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

        // ⌘T adds a to-do while the island is open on the to-do list. It's taken from other apps
        // only during that time (while you're looking at Ledge), and given back as soon as it closes.
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateTodoShortcut() } }
            .store(in: &cancellables)

        // The tray hides again whenever the island closes: it only shows when you ask (⌃⌥F).
        model.$isExpanded
            .dropFirst()
            .filter { !$0 }
            .sink { _ in TrayStore.shared.isShown = false }
            .store(in: &cancellables)

        // Leaving Notes or closing: hand keyboard focus back to the app you were in.
        model.onEndTyping = { [weak self] in self?.giveBackFocus() }
        // Quick add (and an opened to-do) take the keyboard right away. Ledge becomes the active
        // app while you type, like Spotlight does, so every key comes to it: ⌘N, ⌘↩, ⌘C, Esc…
        // (A floating window that only borrows the keyboard doesn't reliably get command keys,
        // especially on a full-screen desktop.) When you're done, the app you were in gets it back.
        model.onBeginTyping = { [weak self] in self?.takeKeyboard() }
        // Opening a note or to-do in its own app: that app takes over, so don't switch back.
        model.onHandOff = { [weak self] in self?.previousApp = nil }
        // Settings takes keyboard focus while open (for Esc), and gives it back after.
        model.onSettingsShown = { [weak self] shown in
            if shown { self?.takeKeyboard() } else { self?.giveBackFocus() }
        }
        // The enlarged note's panel comes and goes with the model.
        model.onNoteEnlarged = { [weak self] change in
            switch change {
            case .open: self?.showNotePanel()
            case .backToIsland: self?.returnNoteToIsland()
            case .close: self?.hideNotePanel()
            }
        }
    }

    // MARK: Enlarged note

    private let enlargeMotion = EnlargeMotion()
    /// Room around the card for its shadow.
    private let noteMargin: CGFloat = 50

    /// The open island on the Notes page, in screen coordinates: where the card starts and ends.
    private func islandNotesRect() -> NSRect {
        let size = IslandLayout.size(for: .expandedNotes, notch: model.notch, style: model.style, tray: model.trayArea)
        let top = screenTop - IslandLayout.topGap(style: model.style)
        return NSRect(x: anchorRect.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    /// The card in the middle of this screen: about 60% × 70% of it, at most 1000 × 720.
    private func noteCardRect() -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == displayID }) else { return nil }
        let area = screen.visibleFrame
        let size = CGSize(width: min(1000, area.width * 0.6), height: min(720, area.height * 0.7))
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Big enough for the card's whole trip (island to middle), clipped to the screen's top.
    private func travelFrame(_ from: NSRect, _ to: NSRect) -> NSRect {
        var f = from.union(to).insetBy(dx: -noteMargin, dy: -noteMargin)
        f.size.height = min(f.maxY, screenTop) - f.minY
        return f
    }

    /// Moves the panel and tells the card where the island and the middle are in it, in one go.
    private func place(_ p: IslandPanel, frame: NSRect, from: NSRect, to: NSRect) {
        func local(_ r: NSRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            enlargeMotion.from = local(from)
            enlargeMotion.to = local(to)
        }
        p.disableScreenUpdatesUntilFlush()
        p.setFrame(frame, display: true)
    }

    /// The card appears exactly over the open island, then grows into the middle of the screen.
    private func showNotePanel() {
        guard let to = noteCardRect() else { return }
        let from = islandNotesRect()
        let p = notePanel ?? makeNotePanel()
        notePanel = p
        enlargeMotion.fromTopRadius = model.style == .notch ? 0 : IslandLayout.topRadius(for: .expandedNotes, notch: model.notch, style: model.style)
        enlargeMotion.fromBottomRadius = IslandLayout.bottomRadius(for: .expandedNotes, notch: model.notch, style: model.style)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { enlargeMotion.expanded = false }
        // Fresh contents each time (the text boxes start out of the way, see `NotesPage`).
        let host = FirstMouseHostingView(rootView: EnlargedNoteView(model: model, notes: notes, motion: enlargeMotion))
        // The panel's size is ours: SwiftUI must not resize the window to fit the note's text.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        let frame = travelFrame(from, to)
        place(p, frame: frame, from: from, to: to)
        host.frame = NSRect(origin: .zero, size: frame.size)
        p.alphaValue = 1
        p.orderFrontRegardless()
        // Next turn, once it's on screen at the island's shape: grow.
        DispatchQueue.main.async { [weak self] in self?.enlargeMotion.expanded = true }
        // Arrived: the window shrinks to the card, so the rest of the screen (the menu bar too)
        // takes clicks normally again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.model.isNoteEnlarged, let p = self.notePanel else { return }
            self.place(p, frame: to.insetBy(dx: -self.noteMargin, dy: -self.noteMargin), from: from, to: to)
        }
        takeKeyboard()
    }

    /// Esc, ⌘E or shrink: the note fades, the card shrinks back up into the island's shape, and
    /// the island takes over right there.
    private func returnNoteToIsland() {
        guard let p = notePanel, let to = noteCardRect() else { model.finishReturningNote(); return }
        let from = islandNotesRect()
        place(p, frame: travelFrame(from, to), from: from, to: to)
        enlargeMotion.expanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self else { return }
            self.model.finishReturningNote()
            // A moment later, so the island is drawn before the card goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !self.model.isNoteEnlarged, let p = self.notePanel else { return }
                p.orderOut(nil)
                p.contentView = nil
            }
        }
    }

    /// Debug only: saves the enlarged note's panel as an image.
    func debugCaptureNote(to path: String) {
        guard let view = notePanel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func hideNotePanel() {
        guard let p = notePanel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Unless it was enlarged again meanwhile.
                if self?.model.isNoteEnlarged != true {
                    p.orderOut(nil)
                    p.contentView = nil // saved when the page goes; nothing left running
                }
            }
        })
    }

    private func makeNotePanel() -> IslandPanel {
        let p = IslandPanel(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        p.ignoresMouseEvents = false
        p.allowsKey = { true }
        // Same level as the island: the card starts right over it (and the menu bar).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // On whichever desktop you're on, full-screen ones included.
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        // Another app taking over (a click elsewhere, ⌘Tab) leaves it open, like the island:
        // only ⌘L or Esc close it.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isNoteEnlarged, !NSApp.isActive || NSApp.keyWindow == nil else { return }
                LedgeLog.shared.write("notes: enlarged note lost the keyboard (stays open)")
            }
        }
        return p
    }

    /// Debug only: saves the island as images every few milliseconds, to check animations.
    func recordFrames(to dir: String, seconds: TimeInterval = 2.4, every interval: TimeInterval = 0.04, note: Bool = false) {
        guard let view = (note ? notePanel : panel)?.contentView else { LedgeLog.shared.write("record: no panel"); return }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { LedgeLog.shared.write("record: can't make \(dir): \(error.localizedDescription)") }
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

    /// The shortcuts this island holds while it's open, by name.
    private var shortcuts: [String: HotKey] = [:]
    /// A shortcut was refused (another island hadn't let go of it yet): try again shortly.
    private var shortcutRetry: DispatchWorkItem?
    private var shortcutRetries = 0

    /// Esc that belongs to the text box you're typing in: a Japanese (or other) input method
    /// cancelling a conversion, or Vim going back to normal mode. The Esc hot key catches Esc
    /// before the window sees it, so it's handed to the text box here. True when it took it.
    private func giveEscapeToTextBox() -> Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView else { return false }
        let wanted = editor.hasMarkedText() || (editor as? MarkdownTextView)?.vimWantsEscape == true
        guard wanted, let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)) else { return false }
        editor.keyDown(with: escape)
        return true
    }

    /// Esc steps back one level: notes → title line → cancel quick add; an open to-do → the list;
    /// settings or the open island → closed.
    @discardableResult
    private func handleEscape() -> Bool {
        let m = model
        // The enlarged note goes back into the island, at its normal size.
        if m.isNoteEnlarged { m.shrinkNote(); return true }
        if m.isShowingSettings { m.closeSettings(); return true }
        if m.isQuickAdding {
            if m.quickAddSuggestsLists && !m.quickAddShowsNotes && !m.quickAddIsConfirming {
                m.quickAddKeys.send(.hideListSuggestions)
            } else if m.quickAddShowsNotes && !m.quickAddIsConfirming { m.quickAddShowsNotes = false }
            else { m.cancelQuickAdd() }
            return true
        }
        if m.openTodoID != nil { m.closeTodo(); return true }
        guard m.isExpanded else { return false }
        m.close()
        return true
    }

    /// Tab / ⇧Tab in a notes box (not a one-line field): indent or outdent the line by 4 spaces.
    private static func indentNotes(for e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let window = e.window as? IslandPanel, window.isKeyWindow,
              let editor = window.firstResponder as? NSTextView, !editor.isFieldEditor else { return false }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange)
        func replace(_ range: NSRange, with string: String) {
            guard editor.shouldChangeText(in: range, replacementString: string) else { return }
            editor.replaceCharacters(in: range, with: string)
            editor.didChangeText()
        }
        if flags.contains(.shift) {
            let spaces = line.prefix(4).prefix { $0 == " " }.count
            let remove = spaces > 0 ? spaces : (line.hasPrefix("\t") ? 1 : 0)
            guard remove > 0 else { return true }
            replace(NSRange(location: lineRange.location, length: remove), with: "")
            editor.setSelectedRange(NSRange(location: max(lineRange.location, selection.location - remove), length: selection.length))
        } else if Checklist.isListLine(line) {
            // The whole list item moves in, wherever the cursor is in it.
            replace(NSRange(location: lineRange.location, length: 0), with: "    ")
            editor.setSelectedRange(NSRange(location: selection.location + 4, length: selection.length))
        } else {
            replace(selection, with: "    ")
        }
        return true
    }

    /// In a notes box (not a one-line field): "[" types "[]" with the cursor between them; "]"
    /// right before a "]" just steps over it; a space inside "[]" at the start of a line makes the
    /// checkbox straight away. Left alone with a Japanese (or any non-Latin) input mode on.
    private static func pairBrackets(for e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let typed = e.characters, typed == "[" || typed == "]" || typed == " ",
              let window = e.window as? IslandPanel, window.isKeyWindow,
              let editor = window.firstResponder as? NSTextView, !editor.isFieldEditor,
              !editor.hasMarkedText(),
              Self.typesLatin(editor.inputContext?.selectedKeyboardInputSource)
        else { return false }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let next = selection.location < text.length ? text.substring(with: NSRange(location: selection.location, length: 1)) : ""
        switch typed {
        case "[":
            editor.insertText("[]", replacementRange: selection)
            editor.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        case "]":
            guard selection.length == 0, next == "]" else { return false }
            editor.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        default:
            // A space between an empty "[]" at the start of a line: that's a checkbox.
            guard selection.length == 0, next == "]", selection.location >= 1 else { return false }
            let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            guard before.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) == "[" else { return false }
            // "[] " at the start of a line turns into a checkbox (see `Checklist.autoFormat`).
            editor.insertText("[] ", replacementRange: NSRange(location: selection.location - 1, length: 2))
            return true
        }
    }

    /// In a notes box: the third "`" of an opening "```" also types the closing "```" on the line
    /// below. The cursor stays right after the opening one, to type a language ("bash") or return.
    private static func closeCodeFence(for e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]), e.characters == "`",
              let window = e.window as? IslandPanel, window.isKeyWindow,
              let editor = window.firstResponder as? NSTextView, !editor.isFieldEditor,
              !editor.hasMarkedText(),
              Self.typesLatin(editor.inputContext?.selectedKeyboardInputSource)
        else { return false }
        let selection = editor.selectedRange()
        guard selection.length == 0,
              let indent = MarkdownStyle.fenceToClose(typingBacktickAt: selection.location, in: editor.string)
        else { return false }
        editor.insertText("`\n" + indent + "```", replacementRange: selection)
        editor.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        return true
    }

    /// In a notes box: backspace right where a list item's or quote's text starts removes the
    /// whole marker ("- ", "- [ ] ", "1. ", "> "), so the line becomes plain text, like Notion.
    private static func removeListMarker(for e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option, .shift]),
              let window = e.window as? IslandPanel, window.isKeyWindow,
              let editor = window.firstResponder as? NSTextView, !editor.isFieldEditor,
              !editor.hasMarkedText()
        else { return false }
        let selection = editor.selectedRange()
        guard selection.length == 0,
              let marker = MarkdownStyle.markerToRemove(backspaceAt: selection.location, in: editor.string)
        else { return false }
        guard editor.shouldChangeText(in: marker, replacementString: "") else { return true }
        editor.replaceCharacters(in: marker, with: "")
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: marker.location, length: 0))
        return true
    }

    /// A plain keyboard layout, or an input method's Latin mode (e.g. Japanese 英数 "Roman").
    private static func typesLatin(_ source: String?) -> Bool {
        guard let source else { return true }
        return source.hasPrefix("com.apple.keylayout") || source.hasSuffix(".Roman")
    }

    /// After a click outside, the open island stays open but steps back: ⌘N, ⌘T, ⌘1–⌘4, ⌘, and
    /// Esc go back to the app you clicked into. Pointing at the island (or opening it again)
    /// brings them back. ⌘L always works.
    private var steppedBack = false

    private func updateTodoShortcut() {
        let m = model
        if !m.isExpanded && !m.isShowingSettings && !m.isNoteEnlarged { steppedBack = false }
        if m.isHovering { steppedBack = false }
        let active = !steppedBack
        let id = UInt32(displayID % 1000)

        // Every shortcut this island can take, and whether it wants it right now.
        struct Want { let name: String; let wanted: Bool; let key: Int; let mods: Int; let id: UInt32; let action: () -> Void }
        var wants: [Want] = []
        // ⌘T on the to-do list: a new to-do.
        wants.append(Want(name: "todo", wanted: active && m.isExpanded && m.page == .calendar && m.calendarMode == .todos
                            && !m.isQuickAdding && m.openTodoID == nil && !m.isShowingSettings,
                          key: kVK_ANSI_T, mods: cmdKey, id: 100 + id) { [weak self] in self?.model.beginQuickAdd() })
        // ⌘N on the Calendar page: a new event (or a new to-do in To-dos mode), like the +.
        // (While quick add is open, ⌘N switches to its notes instead: that's handled by the window.)
        wants.append(Want(name: "newItem", wanted: active && m.isExpanded && m.page == .calendar && !m.isQuickAdding
                            && m.openTodoID == nil && !m.isShowingSettings,
                          key: kVK_ANSI_N, mods: cmdKey, id: 5000 + id) { [weak self] in self?.model.beginQuickAdd() })
        // ⌘N on the Notes page (or the enlarged note): a new note.
        wants.append(Want(name: "newNote", wanted: active && (m.isExpanded && m.page == .notes || m.isNoteEnlarged) && !m.isShowingSettings,
                          key: kVK_ANSI_N, mods: cmdKey, id: 3000 + id) { [weak self] in
            guard let self else { return }
            self.model.beginNotesTyping()
            self.notes.newNote()
        })
        // ⌘, opens settings while the island is open.
        wants.append(Want(name: "settings", wanted: active && m.isExpanded && !m.isShowingSettings,
                          key: kVK_ANSI_Comma, mods: cmdKey, id: 6000 + id) { [weak self] in self?.model.openSettings() })
        // ⌘1–⌘4 switch pages while the island is open (in the order of the dots).
        for (i, key) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].enumerated() {
            wants.append(Want(name: "page\(i)", wanted: active && m.isExpanded && !m.isShowingSettings,
                              key: key, mods: cmdKey, id: 4000 + UInt32(displayID % 100) * 10 + UInt32(i)) { [weak self] in
                self?.model.showPage(number: i + 1)
            })
        }
        // Esc while an island is open: it closes or steps back even when you only hovered it open.
        wants.append(Want(name: "escape", wanted: active && (m.isExpanded || m.isShowingSettings || m.isNoteEnlarged),
                          key: kVK_Escape, mods: 0, id: 2000 + id) { [weak self] in
            guard let self, !self.giveEscapeToTextBox() else { return }
            _ = self.handleEscape()
        })

        // First let go of everything not wanted (⌘N on Notes, before ⌘N on Calendar takes it)…
        for w in wants where !w.wanted { shortcuts[w.name] = nil }
        // …then take what is.
        var refused = false
        for w in wants where w.wanted && shortcuts[w.name] == nil {
            let hotKey = HotKey(keyCode: w.key, modifiers: w.mods, id: w.id, action: w.action)
            if hotKey.isRegistered { shortcuts[w.name] = hotKey } else { refused = true }
        }
        // Refused: usually the island on the other screen hasn't let go yet. Ask again shortly.
        shortcutRetry?.cancel()
        if refused && shortcutRetries < 10 {
            shortcutRetries += 1
            let work = DispatchWorkItem { [weak self] in self?.updateTodoShortcut() }
            shortcutRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        } else if !refused {
            shortcutRetries = 0
        }
    }

    /// The app you were in when quick add took the keyboard.
    private var previousApp: NSRunningApplication?

    /// Takes the keyboard: Ledge becomes the active app (remembering the one you were in) and
    /// the island's window becomes the key window.
    private func takeKeyboard() {
        // The enlarged note's panel while it's showing, otherwise the island's window.
        let target = model.isNoteEnlarged ? notePanel : (activePanel ?? panel)
        guard let panel = target else { return }
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKey()
    }

    /// Hands the keyboard back to the app you were in, by making that app active again. The
    /// island's window stays exactly where it is (taking it off screen and back made the whole
    /// island blink out and in, and cut its closing animation short).
    private func giveBackFocus() {
        if let app = previousApp {
            previousApp = nil
            if NSApp.isActive { app.activate() }
        } else if NSApp.isActive {
            // (After a hand-off this does nothing visible: Notes or Reminders is coming to the front.)
            NSApp.deactivate()
        } else if let window = [panel, revealPanel].compactMap({ $0 }).first(where: \.isKeyWindow) {
            // Rare: the window has the keyboard without Ledge being active. Last resort.
            window.orderOut(nil)
            if window === panel ? !isHidden : revealedSpace != nil { window.orderFrontRegardless() }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        cancellables = []
        // Let go of ⌘N, ⌘1–⌘4, Esc… now, not whenever this island is freed: a screen unplugged
        // while its island was open mustn't keep those keys from every app.
        shortcutRetry?.cancel()
        shortcutRetry = nil
        shortcuts = [:]
        model.endSwitcher()
        notePanel?.orderOut(nil)
        notePanel?.contentView = nil
        notePanel?.close()
        notePanel = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        revealPanel?.close()
        revealPanel = nil
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
        // Edges included: a pointer flung to the top is pinned exactly on the top edge line,
        // which `NSRect.contains` would leave out.
        let f = screen.frame
        return point.x >= f.minX && point.x <= f.maxX && point.y >= f.minY && point.y <= f.maxY
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
        if panel == nil { panel = makePanel(frame: panelFrame, size: size) }
        // Floating pills hide during Mission Control (the notch island can stay). The notch island
        // also stays on full-screen desktops (a full-screen browser or video): there the strip
        // beside the notch is black, so the closed island just looks like the notch, as usual.
        if style == .floating {
            panel?.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        } else {
            panel?.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        }
        panel?.setFrame(panelFrame, display: true)
        if !isHidden { panel?.orderFrontRegardless() }
        // Floating pills get an invisible twin that lives only on full-screen desktops; showing
        // the pill there is then just a fade (macOS needs no time to set anything up).
        if style == .floating {
            if revealPanel == nil {
                let r = makePanel(frame: panelFrame, size: size, isTwin: true)
                r.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
                r.alphaValue = 0
                r.ignoresMouseEvents = true
                r.contentView?.isHidden = true // draws nothing until it's revealed
                revealPanel = r
            }
            revealPanel?.setFrame(panelFrame, display: true)
            revealPanel?.orderFrontRegardless()
        } else {
            revealPanel?.close()
            revealPanel = nil
        }
    }

    /// `isTwin`: the full-screen twin of a floating pill.
    private func makePanel(frame: NSRect, size: CGSize, isTwin: Bool = false) -> IslandPanel {
        let p = IslandPanel(frame: frame)
        p.allowsKey = { [weak self] in
            MainActor.assumeIsolated {
                guard let m = self?.model else { return false }
                return m.isShowingSettings || (m.isExpanded && (m.page == .notes || m.isQuickAdding || m.openTodoID != nil))
            }
        }
        // Clicking anywhere else ends typing, and the island closes.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The enlarged note took the keyboard from the island: typing goes on there.
                if self?.model.isNoteEnlarged == true { return }
                if self?.model.isTyping == true { LedgeLog.shared.write("keys: island window lost the keyboard") }
                self?.model.isTyping = false
            }
        }
        let root = IslandRootView(model: model, calendar: calendar, notes: notes, timer: timer, awake: awake,
                                  settings: settings, updater: updater, openSettings: openSettings)
        let host = FirstMouseHostingView(rootView: root.environment(\.isTwinWindow, isTwin))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// The window the pointer is working with: the full-screen twin while it's revealed.
    private var activePanel: IslandPanel? { revealedSpace != nil ? revealPanel : panel }

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
        fullScreenSpace = spaces.currentIsFullScreen ? spaces.current : nil
        // Left the full-screen desktop while the pill was revealed there: tidy up.
        if let revealed = revealedSpace, revealed != fullScreenSpace { endReveal(animated: false) }
        let current = Spaces.spaces(ofWindow: panel.windowNumber)
        let onFullScreen = current.filter { spaces.fullScreen.contains($0) }
        let missingNormal = spaces.normal.filter { !current.contains($0) }
        if !onFullScreen.isEmpty || !missingNormal.isEmpty {
            Spaces.pin(window: panel.windowNumber, to: missingNormal, removeFrom: onFullScreen)
            if !loggedPin || !onFullScreen.isEmpty {
                loggedPin = true
                LedgeLog.shared.write("spaces: pill on display \(displayID) taken off full-screen desktops \(onFullScreen); now on \(Spaces.spaces(ofWindow: panel.windowNumber))")
            }
        }
        if let twin = revealPanel {
            let twinOn = Spaces.spaces(ofWindow: twin.windowNumber)
            let offNormal = twinOn.filter { spaces.normal.contains($0) }
            let missingFull = spaces.fullScreen.filter { !twinOn.contains($0) }
            if !offNormal.isEmpty || !missingFull.isEmpty {
                Spaces.pin(window: twin.windowNumber, to: missingFull, removeFrom: offNormal)
            }
        }
        // This runs several times a second on full-screen desktops, so a pointer resting at the
        // top edge is noticed even when it stops moving (macOS sends no more movement then).
        checkFullScreenReveal()
    }

    /// The area that currently counts as "the island" for the pointer.
    private func hitRect() -> NSRect {
        guard anchorRect != .zero else { return .zero }
        let size = IslandLayout.size(for: model.shape, notch: model.notch, style: model.style, compactWidth: model.compactWidth,
                                     switcherSize: model.switcher?.size, tray: model.trayArea)
        let w = max(size.width, anchorRect.width)
        let h = max(size.height, anchorRect.height) + IslandLayout.topGap(style: model.style)
        // A little slack on the sides, and an extra point above so the very top edge counts.
        return NSRect(x: anchorRect.midX - w / 2 - 6, y: screenTop - h - 4, width: w + 12, height: h + 5)
    }

    // MARK: Pointer

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] e in
            let type = e.type
            MainActor.assumeIsolated {
                if type == .leftMouseDragged { self?.trackFileDrag(.leftMouseDragged) }
                self?.updatePointer()
            }
        }) { monitors.append(g) }
        // Presses and releases in other apps: where a Finder drag starts and ends (for the tray).
        if let d = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] e in
            let type = e.type
            MainActor.assumeIsolated { self?.trackFileDrag(type) }
        }) { monitors.append(d) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updatePointer() }
            return e
        }) { monitors.append(l) }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handleScroll(e) }
            return e
        }) { monitors.append(s) }
        // Esc closes the open island or settings (e.g. when done typing a note).
        // Quick add's ⌘N (notes) and ⌘return (save) are seen here, before the text fields take them.
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            // Every island has a monitor like this; each one only handles keys typed into its own
            // window, so islands on other screens never take them.
            let mine = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = e.window else { return false }
                return window === self.panel || window === self.revealPanel || window === self.notePanel
            }
            guard mine else { return e }
            // Esc and Tab while a Japanese (or other) input method is still composing belong to it:
            // Esc cancels the conversion, Tab picks a suggestion. Don't close the island or indent.
            if e.keyCode == 53 || e.keyCode == 48,
               MainActor.assumeIsolated({ ((e.window?.firstResponder as? NSTextView)?.hasMarkedText()) == true }) {
                return e
            }
            // Vim keys in the note go straight to it, ahead of the typing helpers below (Tab, "[",
            // "`", backspace) and of Esc closing the island. Esc in normal mode still closes it.
            if MainActor.assumeIsolated({ (e.window?.firstResponder as? MarkdownTextView)?.takesVimKey(e) == true }) {
                return e
            }
            // Copy, paste, cut, select all, undo and redo while typing. Ledge has no Edit menu (it
            // runs without a menu bar), so these are passed to the text field directly.
            let edited = MainActor.assumeIsolated { () -> Bool in
                guard let action = Self.editAction(for: e), let window = e.window as? IslandPanel, window.isKeyWindow,
                      let responder = window.firstResponder, responder is NSText else { return false }
                return responder.tryToPerform(action, with: nil)
            }
            if edited { return nil }
            // ⌘E on the Notes page: enlarge the note, or bring it back into the island.
            let enlargeKeys = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 14, enlargeKeys == [.command],
               MainActor.assumeIsolated({ () -> Bool in
                   guard let m = self?.model else { return false }
                   if m.isNoteEnlarged { m.shrinkNote(); return true }
                   guard m.isExpanded, m.page == .notes else { return false }
                   m.enlargeNote()
                   return true
               }) { return nil }
            // ⌥⌘S on the Notes page shows or hides the list of notes (like the Notes app).
            // (Not in the enlarged note, which has no list.)
            let sidebarKeys = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 1, sidebarKeys == [.command, .option],
               MainActor.assumeIsolated({ self?.model.page == .notes && self?.model.isNoteEnlarged == false }) {
                UserDefaults.standard.set(!Pref.bool(Pref.notesSidebar), forKey: Pref.notesSidebar)
                return nil
            }
            // Tab while quick add suggests lists for a "#list": takes the first one.
            if e.keyCode == 48, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option, .shift]),
               MainActor.assumeIsolated({ () -> Bool in
                   guard let m = self?.model, m.isQuickAdding, m.quickAddSuggestsLists,
                         !m.quickAddShowsNotes, !m.quickAddIsConfirming else { return false }
                   m.quickAddKeys.send(.acceptListSuggestion)
                   return true
               }) { return nil }
            // Tab in a notes box: indents the line by 4 spaces (⇧Tab takes them away), Markdown style.
            if e.keyCode == 48, MainActor.assumeIsolated({ Self.indentNotes(for: e) }) { return nil }
            // "[" in a notes box closes itself: "[]" with the cursor in between.
            if MainActor.assumeIsolated({ Self.pairBrackets(for: e) }) { return nil }
            // "```" in a notes box puts the closing "```" on the line below.
            if MainActor.assumeIsolated({ Self.closeCodeFence(for: e) }) { return nil }
            // Backspace right before a list item's text removes its bullet or box in one go.
            if e.keyCode == 51, MainActor.assumeIsolated({ Self.removeListMarker(for: e) }) { return nil }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = flags.contains(.command)
            var key: QuickAddKey?
            // ⌘N by key position or letter (so it works with any keyboard layout or input mode).
            if command && (e.keyCode == 45 || e.charactersIgnoringModifiers?.lowercased() == "n") { key = .toggleNotes }
            else if command && (e.keyCode == 36 || e.keyCode == 76) { key = .save }
            else if flags.isDisjoint(with: [.command, .control, .option]), e.keyCode != 53,
                    let chars = e.characters, !chars.isEmpty,
                    chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                // Typed before the text field has the cursor (right after ⌘T): kept, not lost.
                key = .typeAhead(chars)
            }
            guard e.keyCode == 53 || key != nil else { return e }
            let pressed = key
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let m = self.model
                if case .typeAhead(let chars)? = pressed {
                    guard m.isQuickAdding, !m.quickAddIsConfirming, !(e.window?.firstResponder is NSText) else { return false }
                    m.appendToDraft(chars)
                    m.quickAddKeys.send(.typeAhead(chars))
                    return true
                }
                if let key = pressed {
                    guard m.isQuickAdding, !m.quickAddIsConfirming else {
                        LedgeLog.shared.write("keys: \(key) ignored (quick add \(m.isQuickAdding ? "confirming" : "closed"))")
                        return false
                    }
                    if case .toggleNotes = key {
                        m.quickAddShowsNotes.toggle()
                    } else {
                        m.quickAddKeys.send(key)
                    }
                    LedgeLog.shared.write("keys: \(key) sent to quick add (notes \(m.quickAddShowsNotes ? "open" : "closed"))")
                    return true
                }
                return self.handleEscape()
            }
            return handled ? nil : e
        }) { monitors.append(k) }
        // A click anywhere else doesn't close anything: only ⌘L and Esc do, so you can work in
        // other apps (or drag files in from Finder) with Ledge open. The island steps back
        // instead: its shortcuts go back to the app you clicked into (see `steppedBack`).
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let m = self.model
                guard m.isExpanded || m.isShowingSettings || m.isNoteEnlarged else { return }
                let p = NSEvent.mouseLocation
                if m.isNoteEnlarged, let f = self.notePanel?.frame, f.contains(p) { return }
                guard !self.hitRect().contains(p), !self.steppedBack else { return }
                LedgeLog.shared.write("keys: clicked outside, island stays open and gives its shortcuts back")
                self.steppedBack = true
                self.updateTodoShortcut()
            }
        }) { monitors.append(c) }
    }

    /// ⌘C ⌘V ⌘X ⌘A ⌘Z ⇧⌘Z: the text editing action for a key press, if it is one.
    nonisolated private static func editAction(for e: NSEvent) -> Selector? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = e.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shift = flags.contains(.shift)
        switch key {
        case "c" where !shift: return #selector(NSText.copy(_:))
        case "v" where !shift: return #selector(NSText.paste(_:))
        case "x" where !shift: return #selector(NSText.cut(_:))
        case "a" where !shift: return #selector(NSText.selectAll(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    // MARK: Full-screen reveal

    /// The full-screen desktop this screen is showing right now (nil on a normal desktop).
    private var fullScreenSpace: UInt64?
    /// While on a full-screen desktop, the pill shows when you move to the top (with the menu bar).
    private var revealedSpace: UInt64?
    private var hideReveal: DispatchWorkItem?
    /// When the pointer arrived at the top edge; the pill waits a moment, like macOS's menu bar.
    private var atTopSince: Date?
    private let revealDelay: TimeInterval = 0.35

    private func checkFullScreenReveal() {
        guard model.style == .floating, let fs = fullScreenSpace else { return }
        let p = NSEvent.mouseLocation
        let onThisScreen = contains(point: p)
        let fromTop = screenTop - p.y
        if revealedSpace == nil {
            // The very top edge is what makes macOS slide the menu bar down. It waits a moment
            // before doing so, so the pill waits the same amount and arrives with it.
            guard onThisScreen && fromTop <= 3 else { atTopSince = nil; return }
            let since = atTopSince ?? Date()
            atTopSince = since
            if Date().timeIntervalSince(since) >= revealDelay {
                atTopSince = nil
                beginReveal(on: fs)
            } else {
                // Look again right when the wait is over (the pointer may not move again).
                DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay - Date().timeIntervalSince(since) + 0.01) { [weak self] in
                    self?.checkFullScreenReveal()
                }
            }
        } else {
            // Stays while you're up in the menu bar or on the pill, and while the island is open
            // (it closes with ⌘L or Esc, like on a normal desktop; ⌘L may have opened
            // it with the pointer on another screen).
            let showingAlert = alertUntil.map { Date() < $0 } ?? false
            let inUse = model.isExpanded || model.isShowingSettings || model.isTyping || model.switcher != nil
            let keep = showingAlert || inUse || onThisScreen && (fromTop <= 26 || hitRect().contains(p))
            if keep {
                hideReveal?.cancel()
                hideReveal = nil
            } else if hideReveal == nil {
                let work = DispatchWorkItem { [weak self] in self?.endReveal(animated: true) }
                hideReveal = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }
    }

    /// Until when an alert (timer done, pomodoro phase change) keeps the pill shown on a full-screen desktop.
    private var alertUntil: Date?

    /// Shows an alert pop. On a full-screen desktop, where the pill is normally hidden,
    /// it slides in just for the pop and goes away again afterwards.
    func alert(_ hud: HUD) {
        model.show(hud)
        guard model.style == .floating, let fs = fullScreenSpace else { return }
        alertUntil = Date().addingTimeInterval(IslandModel.duration(of: hud))
        if revealedSpace == nil {
            LedgeLog.shared.write("fullscreen: showing an alert on display \(displayID)")
            beginReveal(on: fs)
        }
    }

    /// Debug only: reveals the pill now if this screen is showing a full-screen desktop.
    func debugReveal() {
        if let fs = fullScreenSpace, revealedSpace == nil { beginReveal(on: fs) }
    }

    /// A shortcut (⌘L, quick add, settings) is about to open this island: on a full-screen
    /// desktop, where the pill is hidden, bring it in first so there's something to open.
    /// `instant`: shown at once, not faded in with the menu bar (the window switcher).
    func revealForShortcut(instant: Bool = false) {
        guard model.style == .floating, let fs = fullScreenSpace, revealedSpace == nil else { return }
        LedgeLog.shared.write("fullscreen: a shortcut opened the pill on display \(displayID)")
        beginReveal(on: fs, instant: instant)
    }

    private func beginReveal(on space: UInt64, instant: Bool = false) {
        guard let twin = revealPanel else { return }
        revealedSpace = space
        model.twinIsShowing = true
        LedgeLog.shared.write("fullscreen: pointer at the top of display \(displayID), showing the pill")
        twin.contentView?.isHidden = false
        twin.orderFrontRegardless()
        if instant {
            twin.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22 // about as long as the menu bar takes to slide down
            twin.animator().alphaValue = 1
        }
    }

    private func endReveal(animated: Bool) {
        guard revealedSpace != nil, let twin = revealPanel else { return }
        hideReveal?.cancel()
        hideReveal = nil
        if model.isExpanded { model.close() }
        if model.isShowingSettings { model.closeSettings() }
        LedgeLog.shared.write("fullscreen: hiding the pill again on display \(displayID)")
        revealedSpace = nil
        model.twinIsShowing = false
        twin.ignoresMouseEvents = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                twin.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Stop drawing once it's faded out (unless it was revealed again meanwhile).
                    if self?.revealedSpace == nil { twin.contentView?.isHidden = true }
                }
            })
        } else {
            twin.alphaValue = 0
            twin.contentView?.isHidden = true
        }
    }

    private func updatePointer() {
        checkFullScreenReveal()
        guard let panel = activePanel, panel.isVisible, !isHidden else { return }
        // Files are being dragged here: the island takes the drop while the pointer is over it
        // (and doesn't open on hover meanwhile).
        if model.fileDrag != nil {
            let over = hitRect().insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
            return
        }
        var inside = hitRect().contains(NSEvent.mouseLocation)
        // While a mouse button is held (dragging a window, selecting text, resizing), passing
        // over the notch shouldn't open the island. A drag that started on the island
        // (like scrubbing) keeps working.
        if NSEvent.pressedMouseButtons != 0 && !model.isHovering { inside = false }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside { model.pointerEntered() } else { model.pointerExited() }
    }

    // MARK: Tray drops

    /// The drag pasteboard's count when the mouse went down: a change means a drag started.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    /// What the drag in progress carries (nil: no file drag, or not looked at yet).
    private var draggedFiles: (files: Int, folders: Int)?

    /// Watches drags in other apps (Finder, the desktop, Mail…). When one carrying files comes
    /// near the top of this screen (or over the open island), the island shows its drop target.
    private func trackFileDrag(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragBaseline = NSPasteboard(name: .drag).changeCount
            draggedFiles = nil
        case .leftMouseUp:
            guard draggedFiles != nil || model.fileDrag != nil else { return }
            draggedFiles = nil
            // The drop arrives around now; leave the target up a moment so it can land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.model.setFileDrag(nil)
            }
        case .leftMouseDragged:
            guard Pref.bool(Pref.trayEnabled), !isHidden, !model.isShowingSettings, !model.isNoteEnlarged else { return }
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragBaseline else { return }
            if draggedFiles == nil {
                let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                guard !urls.isEmpty else {
                    dragBaseline = pb.changeCount // text, a picture from a browser…: not for the tray
                    return
                }
                let folders = urls.filter {
                    let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return v?.isDirectory == true && v?.isPackage != true
                }.count
                draggedFiles = (urls.count - folders, folders)
                LedgeLog.shared.write("tray: a drag with \(urls.count) file(s) started")
            }
            guard let d = draggedFiles else { return }
            let p = NSEvent.mouseLocation
            let near: Bool
            if !contains(point: p) {
                near = false
            } else if model.fileDrag != nil || model.isExpanded {
                near = hitRect().insetBy(dx: -24, dy: -24).contains(p)
            } else {
                near = screenTop - p.y <= 60 && abs(p.x - anchorRect.midX) <= 260
            }
            if near, model.fileDrag == nil {
                model.setFileDrag(FileDrag(files: d.files, folders: d.folders))
            } else if !near, model.fileDrag != nil {
                model.setFileDrag(nil)
            }
        default:
            break
        }
    }

    private func handleScroll(_ e: NSEvent) {
        let open = model.shape.isOpen
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
