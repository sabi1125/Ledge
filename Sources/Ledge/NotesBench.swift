#if DEBUG
import AppKit
import SwiftUI
import LedgeCore

/// Debug only: `Ledge --bench-notes` types into the real note editor (off screen) and prints how
/// long each keystroke takes, styling, layout and drawing included.
enum NotesBench {
    @MainActor static func run() {
        var sample = ""
        for i in 1...14 {
            sample += "## Section \(i)\n"
            sample += "Some **bold** words, some *italic* ones, a `code` bit and a [link](https://example.com/\(i)).\n"
            sample += "- [ ] a step to do \(i)\n- [x] a step done\n    - nested bullet\n"
            sample += "> a quote line\n1. first\n2. second\n\n"
        }
        sample += "```\nlet x = 1\n```\n---\nThe end line where typing happens.\n"
        print("sample: \(sample.utf16.count) characters")

        let window: NSWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        var t = Date()
        var text = sample
        let editor = MarkdownEditor(text: Binding(get: { text }, set: { text = $0 }), wantsFocus: false, blurRequest: 0) { _ in }
        let host = NSHostingView(rootView: editor.frame(width: 520, height: 400))
        host.frame = window.contentLayoutRect
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let view = Self.find(in: host) else { print("no text view"); return }
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        t = Date()
        for _ in 0..<50 { _ = MarkdownStyle.spans(in: sample) }
        print(String(format: "parse only: %.2f ms", Date().timeIntervalSince(t) * 1000 / 50))
        t = Date()
        for _ in 0..<50 {
            let scratch = NSMutableAttributedString(string: sample)
            NotesMarkdown.style(scratch, selection: NSRange(location: 10, length: 0))
        }
        print(String(format: "style a copy (no layout): %.2f ms", Date().timeIntervalSince(t) * 1000 / 50))
        // A full restyle on its own.
        var t0 = Date()
        for _ in 0..<50 { view.restyle() }
        print(String(format: "restyle: %.2f ms", Date().timeIntervalSince(t0) * 1000 / 50))
        t0 = Date()
        for _ in 0..<20 { view.restyle(); view.layoutManager?.ensureLayout(for: view.textContainer!) }
        print(String(format: "restyle + full layout: %.2f ms", Date().timeIntervalSince(t0) * 1000 / 20))

        // Keystrokes: insert a letter, then lay out and draw as the screen would.
        let keys = Array("the quick brown fox jumps over the lazy dog ")
        var times: [Double] = []
        var parts = [0.0, 0.0, 0.0]
        for k in keys + keys {
            t = Date()
            view.insertText(String(k), replacementRange: view.selectedRange())
            let a = Date()
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            let b = Date()
            view.displayIfNeeded()
            let c = Date()
            parts[0] += a.timeIntervalSince(t); parts[1] += b.timeIntervalSince(a); parts[2] += c.timeIntervalSince(b)
            times.append(Date().timeIntervalSince(t) * 1000)
        }
        let n = Double(times.count)
        print(String(format: "  per key: edit+style %.2f ms, layout %.2f ms, draw %.2f ms", parts[0] * 1000 / n, parts[1] * 1000 / n, parts[2] * 1000 / n))
        // A second copy of the note that isn't being typed in (a pill's twin window) following each key.
        let twin = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        twin.string = view.string
        twin.restyle()
        var twinText = view.string
        var whole = 0.0, diff = 0.0
        for k in keys {
            twinText.append(k)
            let t1 = Date()
            twin.string = twinText; twin.restyle(); twin.layoutManager?.ensureLayout(for: twin.textContainer!)
            whole += Date().timeIntervalSince(t1)
            twinText.append(k)
            let t2 = Date()
            twin.replaceDifference(with: twinText); twin.restyle(); twin.layoutManager?.ensureLayout(for: twin.textContainer!)
            diff += Date().timeIntervalSince(t2)
        }
        print(String(format: "twin copy per key: replace all %.2f ms, replace difference %.2f ms",
                     whole * 1000 / Double(keys.count), diff * 1000 / Double(keys.count)))
        // Same look as styling everything from scratch (the old way)?
        let fresh = NSMutableAttributedString(string: view.string)
        NotesMarkdown.style(fresh, selection: view.hasFocus ? view.selectedRange() : nil)
        fresh.fixParagraphStyleAttribute(in: NSRange(location: 0, length: fresh.length))
        print("after typing, same look as a full restyle: \(fresh.isEqual(to: view.textStorage!))")
        let twinFresh = NSMutableAttributedString(string: twin.string)
        NotesMarkdown.style(twinFresh, selection: nil)
        twinFresh.fixParagraphStyleAttribute(in: NSRange(location: 0, length: twinFresh.length))
        print("twin copy, same text: \(twin.string == twinText), same look: \(twinFresh.isEqual(to: twin.textStorage!))")
        // Cursor moves: to another line (marks there show, the old line's hide), then within it.
        var moves = true
        for at in [20, 25, 400, 404, 1200, 5] {
            view.setSelectedRange(NSRange(location: at, length: 0))
            let check = NSMutableAttributedString(string: view.string)
            NotesMarkdown.style(check, selection: view.selectedRange())
            check.fixParagraphStyleAttribute(in: NSRange(location: 0, length: check.length))
            if !check.isEqual(to: view.textStorage!) { moves = false; print("differs after moving to \(at)") }
        }
        print("cursor moves keep the right look: \(moves) (focus \(view.hasFocus))")
        // Typing helpers still work with the quick path: "[] " → checkbox, return continues it.
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        for k in ["\n", "[", "]", " ", "b", "u", "y", "\n"] {
            view.insertText(k, replacementRange: view.selectedRange())
        }
        let tail = String(view.string.suffix(20))
        print("typed: \(tail.debugDescription)")
        view.insertText("\n", replacementRange: view.selectedRange())
        print("return on an empty box: \(String(view.string.suffix(12)).debugDescription)")
        times.sort()
        print(String(format: "keystroke: median %.2f ms, p90 %.2f ms, max %.2f ms (%d keys)",
                     times[times.count / 2], times[times.count * 9 / 10], times.last!, times.count))
    }

    @MainActor private static func find(in view: NSView) -> MarkdownTextView? {
        if let v = view as? MarkdownTextView { return v }
        for sub in view.subviews { if let v = find(in: sub) { return v } }
        return nil
    }
}
#endif

#if DEBUG
import LedgeCore
/// Debug only: `Ledge --render-notes DIR` draws a note with inline code, with the cursor away
/// from the code lines and on one of them, to check how it looks.
enum NotesRender {
    @MainActor static func run(to dir: String) {
        let sample = """
        Run `swift build` then `./scripts/install.sh` to update.
        A line with `code` in the middle and `two` of them.
        Plain line under it.
        - [ ] check `git status` first
        `starts with code` and ends
        """
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, cursor) in [("away", (sample as NSString).length), ("on-line-1", 8)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            var text = sample
            let editor = MarkdownEditor(text: Binding(get: { text }, set: { text = $0 }), wantsFocus: false, blurRequest: 0) { _ in }
            let host = NSHostingView(rootView: editor.frame(width: 440, height: 150).padding(10).background(Color.black))
            host.frame = window.contentLayoutRect
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let view = find(in: host) else { return }
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: cursor, length: 0))
            view.restyle()
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        // The stand-in shown while the island moves, next to the real editor, for a note with a code block.
        let block = "Notes about `ledge`:\n```swift\nlet x = 1\nprint(x)\n```\nAfter the block.\n- [ ] a `todo` item"
        func save(_ view: NSView, _ name: String) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            view.frame = window.contentLayoutRect
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        save(NSHostingView(rootView: MarkdownPreview(text: block).frame(width: 440, height: 180, alignment: .topLeading).padding(10).background(Color.black)), "block-standin")
        var blockText = block
        let blockEditor = MarkdownEditor(text: Binding(get: { blockText }, set: { blockText = $0 }), wantsFocus: false, blurRequest: 0) { _ in }
        save(NSHostingView(rootView: blockEditor.frame(width: 440, height: 180).padding(10).background(Color.black)), "block-editor")
        print("rendered to \(dir)")
    }

    @MainActor private static func find(in view: NSView) -> MarkdownTextView? {
        if let v = view as? MarkdownTextView { return v }
        for sub in view.subviews { if let v = find(in: sub) { return v } }
        return nil
    }
}
#endif

#if DEBUG
/// Debug only: `Ledge --try-lists` sends real key presses to the note editor (Vim on) and prints
/// what the note becomes, for making new list lines.
enum ListTrial {
    @MainActor static func run() {
        let start = "this that\n\n- [ ] this is a test\n    - [ ] this is also a test"
        let cases: [(String, Int, [String])] = [
            ("vim o on the top item", 17, ["o", "x"]),
            ("vim o on the nested item", 50, ["o", "x"]),
            ("vim A then return, top item", 17, ["A", "\r", "x"]),
            ("vim A then return, nested item", 50, ["A", "\r", "x"]),
            ("vim i at the text start then return", 17, ["i", "\r"]),
            ("vim O on the top item", 17, ["O", "x"]),
            ("A, return, return (ends list), then '- ' for a bullet", 50, ["A", "\r", "\r", "-", " ", "x"]),
            ("A, return, Tab (indent the new one)", 17, ["A", "\r", "\t", "x"]),
            ("A, return, shift-Tab on nested", 50, ["A", "\r", "⇧\t", "x"]),
            ("nested: A, return, return (moves out a level)", 50, ["A", "\r", "\r", "x"]),
            ("top: A, return, return (ends the list)", 17, ["A", "\r", "\r", "x"]),
            ("checkbox to bullet: A, return, backspace, '- '", 17, ["A", "\r", "\u{7f}", "-", " ", "x"]),
            ("vim O on the nested item", 50, ["O", "x"]),
        ]
        for (name, cursor, keys) in cases {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            var text = start
            let editor = MarkdownEditor(text: Binding(get: { text }, set: { text = $0 }), wantsFocus: false, blurRequest: 0, vimMotions: true) { _ in }
            let host = NSHostingView(rootView: editor.frame(width: 440, height: 180))
            host.frame = window.contentLayoutRect
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let view = find(in: host) else { return }
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: cursor, length: 0))
            for key in keys {
                let shift = key.hasPrefix("⇧")
                let chars = shift ? String(key.dropFirst()) : key
                let code: UInt16 = chars == "\r" ? 36 : chars == "\t" ? 48 : chars == "\u{7f}" ? 51 : 0
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: chars, charactersIgnoringModifiers: chars,
                                                   isARepeat: false, keyCode: code) else { continue }
                // What the island's key monitor does first (see IslandController).
                if code == 48, view.vimMode == "insert" || !view.vimEnabled, IslandController.indent(view, out: shift) { continue }
                if chars == "\u{7f}", IslandController.removeMarker(view) { continue }
                view.keyDown(with: event)
            }
            let after = (view.string as NSString).substring(from: 11)
            print("\(name):\n  \(after.debugDescription)  [binding matches: \(text == view.string)]")
        }
    }

    @MainActor private static func find(in view: NSView) -> MarkdownTextView? {
        if let v = view as? MarkdownTextView { return v }
        for sub in view.subviews { if let v = find(in: sub) { return v } }
        return nil
    }
}
#endif
