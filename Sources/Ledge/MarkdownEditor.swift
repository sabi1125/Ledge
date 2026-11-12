import AppKit
import LedgeCore
import SwiftUI

// MARK: - The look

/// How the notes box draws Markdown, after Notion and render-markdown.nvim. Headings, bold,
/// code and links show their style with the marks ("##", "**", "`", "](url)") hidden; the marks
/// come back on the line the cursor is on, so you can edit them. Bullets, checkboxes, quote bars,
/// code boxes and "---" lines are drawn and always look finished.
/// The text itself stays plain Markdown, so the Notes app shows the same note.
@MainActor
enum NotesMarkdown {
    // MARK: Type and spacing

    static let baseFont = NSFont.systemFont(ofSize: 13)
    /// Extra space between lines, for an airier page (Notion uses 1.5 line height).
    static let lineSpacing: CGFloat = 3
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: baseFont)
    /// How far code sits in from its box's edges.
    static let codeInset: CGFloat = 12
    /// Extra width after a list marker, for its bullet.
    static let bulletRoom: CGFloat = 4

    static let baseParagraph = paragraph { _ in }
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont, .foregroundColor: textColor, .paragraphStyle: baseParagraph,
    ]

    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let codeTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: codeFont, .foregroundColor: codeBlockColor, .paragraphStyle: codeParagraph,
    ]
    private static let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    /// For marks that are hidden: practically no width, and no color.
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.1)

    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 21, weight: .bold)
        case 2: return .systemFont(ofSize: 17, weight: .bold)
        case 3: return .systemFont(ofSize: 15, weight: .semibold)
        default: return .systemFont(ofSize: 13, weight: .semibold)
        }
    }

    /// Room above a heading, so sections read as sections.
    private static func headingSpace(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 10
        case 2: return 8
        default: return 5
        }
    }

    /// A paragraph style with the page's line spacing; `change` adds the rest.
    static func paragraph(_ change: (NSMutableParagraphStyle) -> Void) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        // A line whose marks are all hidden ("## " while typing a heading) keeps its height.
        style.minimumLineHeight = lineHeight
        change(style)
        return style
    }

    private static let codeParagraph = paragraph {
        $0.firstLineHeadIndent = codeInset
        $0.headIndent = codeInset
        $0.tailIndent = -codeInset
    }

    /// The ``` lines: the box's top and bottom padding, and where the language label sits.
    private static let fenceParagraph = paragraph {
        $0.firstLineHeadIndent = codeInset
        $0.headIndent = codeInset
        $0.minimumLineHeight = 22
    }

    // MARK: Colors

    static let textColor = NSColor(white: 0.96, alpha: 1)
    /// Marks shown on the cursor's line: present but quiet.
    static let markColor = NSColor(white: 1, alpha: 0.35)
    static let ruleColor = NSColor(white: 1, alpha: 0.2)
    /// ``` blocks: a white card with dark text.
    static let codeBoxColor = NSColor(white: 0.95, alpha: 1)
    static let inlineCodeBoxColor = NSColor(white: 1, alpha: 0.12)
    static let quoteBarColor = NSColor(red: 0.62, green: 0.56, blue: 0.98, alpha: 1)
    static let bulletColor = NSColor(white: 1, alpha: 0.72)
    static let checkboxColor = NSColor(white: 1, alpha: 0.5)
    /// A ticked box: the Notes yellow.
    static let checkedColor = NSColor(red: 1.0, green: 0.80, blue: 0.22, alpha: 1)

    private static let codeColor = NSColor(red: 1.0, green: 0.56, blue: 0.48, alpha: 1)
    static let codeBlockColor = NSColor(white: 0.1, alpha: 1)
    /// The ``` and the language label, on the white card.
    private static let codeMarkColor = NSColor(white: 0, alpha: 0.38)
    private static let linkColor = NSColor(red: 0.45, green: 0.68, blue: 1.0, alpha: 1)
    private static let quoteTextColor = NSColor(white: 1, alpha: 0.82)
    private static let quietTextColor = NSColor(white: 1, alpha: 0.42)
    private static let numberColor = NSColor(white: 1, alpha: 0.6)

    // MARK: Styling

    /// What the text view draws itself, beyond the styled characters.
    struct Decorations {
        /// "---" lines: a line across.
        var rules: [NSRange] = []
        /// The ">" of quote lines: a bar.
        var quoteBars: [NSRange] = []
        /// ``` blocks: a box behind.
        var codeBoxes: [NSRange] = []
        /// `code` in a line: a small rounded box behind.
        var inlineCode: [NSRange] = []
        /// List markers: a bullet, by level.
        var bullets: [(range: NSRange, level: Int)] = []
        /// "[ ]" / "[x]": a box, ticked or not.
        var checkboxes: [(range: NSRange, done: Bool)] = []
        /// Where the cursor shouldn't stop (see `MarkdownStyle.Kind.lead`).
        var leads: [NSRange] = []
        /// Link text and where it goes (⌘-click opens it).
        var links: [(range: NSRange, url: String)] = []
    }

    /// Styles the whole text and returns what the text view draws on top. Marks on the lines
    /// the selection touches are shown; with no selection (the box isn't being typed in) all hide.
    @discardableResult
    static func style(_ text: NSMutableAttributedString, selection: NSRange?, preview: Bool = false) -> Decorations {
        let ns = text.string as NSString
        text.setAttributes(baseAttributes, range: NSRange(location: 0, length: ns.length))
        let spans = MarkdownStyle.spans(in: text.string)
        let shownLines = selection.map { ns.lineRange(for: $0) }
        func isShown(_ range: NSRange) -> Bool {
            guard let lines = shownLines else { return false }
            return range.location >= lines.location
                && (range.location < lines.upperBound || lines.upperBound == ns.length)
        }
        func hide(_ range: NSRange) {
            text.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: range)
            // A hidden backtick still leaves room for the rounded box around its code.
            if ns.substring(with: range) == "`" { text.addAttribute(.kern, value: 3.5, range: range) }
        }

        // Sizes first (headings, code), then bold and italic on top of them.
        for span in spans {
            switch span.kind {
            case .heading(let level):
                text.addAttribute(.font, value: headingFont(level), range: span.range)
                let space = headingSpace(level)
                text.addAttribute(.paragraphStyle, value: paragraph { $0.paragraphSpacingBefore = space }, range: span.range)
            case .code, .codeBlock, .fence:
                text.addAttribute(.font, value: codeFont, range: span.range)
            case .fenceInfo:
                text.addAttributes([.font: labelFont, .foregroundColor: codeMarkColor], range: span.range)
            default:
                break
            }
        }
        for span in spans {
            switch span.kind {
            case .bold: addTrait(.boldFontMask, to: text, in: span.range)
            case .italic: addTrait(.italicFontMask, to: text, in: span.range)
            default: break
            }
        }

        // Colors, and what gets drawn.
        var drawn = Decorations()
        var lastLink: NSRange?
        for span in spans {
            let range = span.range
            switch span.kind {
            case .code:
                text.addAttribute(.foregroundColor, value: codeColor, range: range)
                if preview { text.addAttribute(.backgroundColor, value: inlineCodeBoxColor, range: range) }
                drawn.inlineCode.append(range)
            case .codeBlock:
                text.addAttribute(.foregroundColor, value: codeBlockColor, range: range)
            case .codeArea:
                drawn.codeBoxes.append(range)
            case .link:
                text.addAttributes([
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: linkColor.withAlphaComponent(0.4),
                ], range: range)
                lastLink = range
            case .linkURL:
                if let link = lastLink { drawn.links.append((link, ns.substring(with: range))) }
            case .quote:
                text.addAttribute(.foregroundColor, value: quoteTextColor, range: range)
            case .quoteMark:
                text.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                drawn.quoteBars.append(range)
            case .bullet(let level):
                // A little more room than a "-" takes, so the bullet doesn't touch the text.
                text.addAttributes([.foregroundColor: NSColor.clear, .kern: bulletRoom], range: range)
                drawn.bullets.append((range, level))
            case .number:
                text.addAttribute(.foregroundColor, value: numberColor, range: range)
            case .checkboxLead:
                hide(range)
            case .checkbox(let done):
                text.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                drawn.checkboxes.append((range, done))
            case .strike, .done:
                text.addAttributes([
                    .foregroundColor: quietTextColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
            case .rule:
                text.addAttribute(.foregroundColor, value: isShown(range) ? markColor : NSColor.clear, range: range)
                drawn.rules.append(range)
            case .lead:
                drawn.leads.append(range)
            case .mark, .fence:
                if isShown(range) {
                    text.addAttribute(.foregroundColor, value: span.kind == .fence ? codeMarkColor : markColor, range: range)
                } else {
                    hide(range)
                }
            default:
                break
            }
        }

        // Lines that line up: code inside its box, wrapped list and quote lines under their text.
        for range in drawn.codeBoxes {
            text.addAttribute(.paragraphStyle, value: codeParagraph, range: range)
        }
        for span in spans where span.kind == .fence {
            text.addAttribute(.paragraphStyle, value: fenceParagraph, range: ns.lineRange(for: span.range))
        }
        for span in spans where span.kind == .hang {
            let width = text.attributedSubstring(from: span.range).size().width
            text.addAttribute(.paragraphStyle, value: paragraph { $0.headIndent = width }, range: ns.lineRange(for: span.range))
        }
        return drawn
    }

    /// Makes every font in the range bold (or italic), keeping its size.
    private static func addTrait(_ trait: NSFontTraitMask, to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: part)
        }
    }

    // MARK: Drawing helpers (shared with the text view)

    /// One bullet: ● ○ ◆ ◇ by level, like render-markdown.nvim.
    static func drawBullet(level: Int, center: NSPoint) {
        bulletColor.set()
        let size: CGFloat = level % 4 < 2 ? 5.5 : 6.5
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape: NSBezierPath
        if level % 4 < 2 {
            shape = NSBezierPath(ovalIn: level % 4 == 0 ? rect : rect.insetBy(dx: 0.6, dy: 0.6))
        } else {
            shape = NSBezierPath()
            shape.move(to: NSPoint(x: rect.midX, y: rect.minY))
            shape.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            shape.line(to: NSPoint(x: rect.midX, y: rect.maxY))
            shape.line(to: NSPoint(x: rect.minX, y: rect.midY))
            shape.close()
        }
        if level % 2 == 0 {
            shape.fill()
        } else {
            shape.lineWidth = 1.2
            shape.stroke()
        }
    }

    /// One checkbox: a rounded square, or a yellow one with a tick.
    static func drawCheckbox(done: Bool, in rect: NSRect) {
        if done {
            checkedColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            let s = rect.width
            let tick = NSBezierPath()
            // Flipped view: y grows downwards.
            tick.move(to: NSPoint(x: rect.minX + 0.26 * s, y: rect.minY + 0.53 * s))
            tick.line(to: NSPoint(x: rect.minX + 0.43 * s, y: rect.minY + 0.70 * s))
            tick.line(to: NSPoint(x: rect.minX + 0.75 * s, y: rect.minY + 0.31 * s))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor(white: 0.08, alpha: 1).setStroke()
            tick.stroke()
        } else {
            checkboxColor.setStroke()
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.65, dy: 0.65), xRadius: 3, yRadius: 3)
            box.lineWidth = 1.3
            box.stroke()
        }
    }

    // MARK: The preview (while the island moves)

    /// One line of the note for `MarkdownPreview`.
    enum PreviewLine {
        /// Styled text; `quote` gets a bar, `code` sits in the code box.
        case text(AttributedString, quote: Bool, code: Bool)
        /// A "---" line.
        case rule
    }

    /// The note as SwiftUI lines, styled the same way, for while the island is still moving
    /// (see `IslandModel.isSettled`). Bullets and boxes become characters here.
    static func previewLines(_ text: String) -> [PreviewLine] {
        let styled = NSMutableAttributedString(string: text)
        let drawn = style(styled, selection: nil, preview: true)
        let ns = text as NSString

        // What each line is, read before any characters change.
        var flags: [(rule: Bool, quote: Bool, code: Bool)] = []
        forEachLine(ns) { range in
            flags.append((
                rule: drawn.rules.contains { $0.location == range.location },
                quote: drawn.quoteBars.contains { $0.location >= range.location && $0.location <= range.upperBound },
                code: drawn.codeBoxes.contains { range.location >= $0.location && range.location <= $0.upperBound }
            ))
        }

        // Bullets and boxes as characters, from the end so the earlier ranges stay right.
        var swaps: [(NSRange, String, NSColor)] = drawn.bullets.map { ($0.range, ["●", "○", "◆", "◇"][$0.level % 4], bulletColor) }
        swaps += drawn.checkboxes.map { ($0.range, $0.done ? "☑" : "☐", $0.done ? checkedColor : checkboxColor) }
        for (range, symbol, color) in swaps.sorted(by: { $0.0.location > $1.0.location }) {
            let font = NSFont.systemFont(ofSize: symbol == "●" || symbol == "○" ? 8 : 12)
            styled.replaceCharacters(in: range, with: NSAttributedString(string: symbol, attributes: [.font: font, .foregroundColor: color]))
        }

        var lines: [PreviewLine] = []
        var index = 0
        forEachLine(styled.string as NSString) { range in
            let flag = index < flags.count ? flags[index] : (rule: false, quote: false, code: false)
            index += 1
            if flag.rule {
                lines.append(.rule)
            } else {
                lines.append(.text(swiftUIText(styled.attributedSubstring(from: range)), quote: flag.quote, code: flag.code))
            }
        }
        return lines
    }

    /// Calls `body` with each line's range (without the "\n").
    private static func forEachLine(_ ns: NSString, _ body: (NSRange) -> Void) {
        var start = 0
        while true {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            body(NSRange(location: start, length: end - start))
            if newline.location == NSNotFound { return }
            start = end + 1
        }
    }

    /// AppKit attributes (NSFont, NSColor) turned into ones SwiftUI's Text draws.
    private static func swiftUIText(_ line: NSAttributedString) -> AttributedString {
        guard line.length > 0 else {
            var blank = AttributedString(" ")
            blank.font = Font(baseFont as CTFont)
            return blank
        }
        var out = AttributedString()
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attributes, range, _ in
            var piece = AttributedString(line.attributedSubstring(from: range).string)
            if let font = attributes[.font] as? NSFont { piece.font = Font(font as CTFont) }
            if let color = attributes[.foregroundColor] as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            if let color = attributes[.backgroundColor] as? NSColor { piece.backgroundColor = Color(nsColor: color) }
            if attributes[.strikethroughStyle] != nil { piece.strikethroughStyle = .single }
            if attributes[.underlineStyle] != nil { piece.underlineStyle = .single }
            out += piece
        }
        return out
    }
}

// MARK: - The text box

/// The notes box: a macOS text view that draws Markdown as you type (SwiftUI's TextEditor can
/// only show plain text). The text stays plain Markdown; only how it's drawn changes.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Puts the cursor in the box (now, or as soon as the box is on screen).
    var wantsFocus: Bool
    /// Each change takes the cursor out of the box.
    var blurRequest: Int
    /// The box got (true) or lost (false) the cursor.
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.appearance = NSAppearance(named: .darkAqua)

        let view = MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        // Markdown needs the characters as typed: no curly quotes, no "--" turning into "—".
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.insertionPointColor = .white
        view.typingAttributes = NotesMarkdown.baseAttributes
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.delegate = context.coordinator
        view.onFocusChange = onFocusChange
        view.restyle()
        view.wantsFocus = wantsFocus
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MarkdownTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        view.onFocusChange = onFocusChange
        // Off while the Notes page isn't the one showing (SwiftUI's .disabled doesn't reach AppKit views).
        view.isEditable = context.environment.isEnabled
        view.isSelectable = context.environment.isEnabled
        if view.string != text { coordinator.show(text, in: view) }
        view.wantsFocus = wantsFocus
        if blurRequest != coordinator.blurRequest {
            coordinator.blurRequest = blurRequest
            if view.hasFocus { view.window?.makeFirstResponder(nil) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var blurRequest: Int
        /// Changes made here (not typed) don't go back to the binding.
        private var isApplying = false
        /// The box's own undo history, cleared when another note is shown.
        private let undo = UndoManager()

        init(_ parent: MarkdownEditor) {
            self.parent = parent
            self.blurRequest = parent.blurRequest
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? MarkdownTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            view.restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? MarkdownTextView else { return }
            // While a drag is still selecting, hold the marks still (the text would shift under the
            // pointer); the text view restyles when the button comes up.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            view.restyle()
        }

        /// Keeps the cursor off the hidden "- [ ] " and "> " in front of a line's text.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard !isApplying, new.length == 0, let view = textView as? MarkdownTextView else { return new }
            return NSRange(location: view.allowedCursor(new.location, from: old), length: 0)
        }

        /// Shows text that changed outside the box. While you're typing, that's a typing helper
        /// ("[] " → "- [ ] "): only the changed part is replaced, it can be undone, and the cursor
        /// stays where it belongs. Otherwise it's another note: the whole text, a fresh undo history.
        func show(_ text: String, in view: MarkdownTextView) {
            isApplying = true
            defer { isApplying = false }
            guard view.hasFocus else {
                view.string = text
                undo.removeAllActions()
                view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                view.restyle()
                return
            }
            let old = Array(view.string), new = Array(text)
            let prefix = zip(old, new).prefix { $0 == $1 }.count
            let maxSuffix = min(old.count, new.count) - prefix
            let suffix = zip(old.reversed(), new.reversed()).prefix(maxSuffix).prefix { $0 == $1 }.count
            let start = String(old[..<prefix]).utf16.count
            let removed = String(old[prefix..<(old.count - suffix)]).utf16.count
            let inserted = String(new[prefix..<(new.count - suffix)])
            let changed = NSRange(location: start, length: removed)
            let cursor = view.selectedRange().location
            if view.shouldChangeText(in: changed, replacementString: inserted) {
                view.replaceCharacters(in: changed, with: inserted)
                view.didChangeText()
            }
            let delta = inserted.utf16.count - removed
            let moved = cursor >= changed.upperBound ? cursor + delta
                : (cursor > changed.location ? changed.location + inserted.utf16.count : cursor)
            view.setSelectedRange(NSRange(location: min(max(0, moved), (view.string as NSString).length), length: 0))
            view.restyle()
        }
    }
}

/// The text view under `MarkdownEditor`: restyles after every change, draws the bullets,
/// checkboxes, quote bars, code boxes and "---" lines, and ticks a checkbox when it's clicked.
final class MarkdownTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    private(set) var hasFocus = false
    /// From the last restyle.
    private var drawn = NotesMarkdown.Decorations()
    /// Where each checkbox was drawn, for clicks.
    private var checkboxHits: [(rect: NSRect, range: NSRange)] = []

    var wantsFocus = false {
        didSet { if wantsFocus != oldValue { focusIfWanted() } }
    }

    /// Styles the whole note again. Skipped while a Japanese (or other) input method is still
    /// composing, so its underline isn't wiped; it runs again when the text is committed.
    func restyle() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        storage.beginEditing()
        drawn = NotesMarkdown.style(storage, selection: hasFocus ? selectedRange() : nil)
        storage.endEditing()
        // New text starts plain; the next restyle gives it its look. Inside a code card it's dark
        // code text, and the cursor turns dark too, so both show on the white.
        let cursor = selectedRange().location
        let inCode = drawn.codeBoxes.contains { cursor >= $0.location && cursor <= $0.upperBound }
        typingAttributes = inCode ? NotesMarkdown.codeTypingAttributes : NotesMarkdown.baseAttributes
        insertionPointColor = inCode ? .black : .white
        needsDisplay = true
    }

    /// Where the cursor may go: never inside the hidden marker in front of a list item or quote.
    /// Moving left out of the text goes to the end of the line above; anything else lands on the text.
    func allowedCursor(_ location: Int, from old: NSRange) -> Int {
        let text = string as NSString
        for lead in drawn.leads where location >= lead.location && location < lead.upperBound {
            let lineStart = text.lineRange(for: NSRange(location: lead.location, length: 0)).location
            // Right before an indented marker is a real place (it shows as the indent).
            if location == lead.location && lead.location > lineStart { return location }
            let movingLeft = old.length == 0 && old.location == lead.upperBound
            if movingLeft && lineStart > 0 { return lineStart - 1 }
            return lead.upperBound
        }
        return location
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return super.draw(dirtyRect) }
        let text = string as NSString
        let origin = textContainerOrigin
        let width = textContainer.size.width
        let spacing = NotesMarkdown.lineSpacing

        func glyphs(_ range: NSRange) -> NSRange? {
            guard range.upperBound <= text.length else { return nil }
            let found = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return found.length > 0 ? found : nil
        }
        /// The lines holding these characters, across the whole width (without the last line's spacing).
        func band(_ range: NSRange) -> NSRect? {
            guard let found = glyphs(range) else { return nil }
            let first = layoutManager.lineFragmentRect(forGlyphAt: found.location, effectiveRange: nil)
            let last = layoutManager.lineFragmentRect(forGlyphAt: found.upperBound - 1, effectiveRange: nil)
            return NSRect(x: origin.x, y: first.minY + origin.y, width: width, height: last.maxY - first.minY - spacing)
        }
        /// The baseline under a character, and its glyph's box.
        func place(_ range: NSRange) -> (baseline: CGFloat, box: NSRect)? {
            guard let found = glyphs(range) else { return nil }
            let line = layoutManager.lineFragmentRect(forGlyphAt: found.location, effectiveRange: nil)
            let baseline = origin.y + line.minY + layoutManager.location(forGlyphAt: found.location).y
            let box = layoutManager.boundingRect(forGlyphRange: found, in: textContainer).offsetBy(dx: origin.x, dy: origin.y)
            return (baseline, box)
        }

        // Behind the text: code boxes, inline code boxes, quote bars.
        NotesMarkdown.codeBoxColor.setFill()
        for range in drawn.codeBoxes {
            guard let box = band(range) else { continue }
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        }
        NotesMarkdown.inlineCodeBoxColor.setFill()
        for range in drawn.inlineCode {
            guard let found = glyphs(range) else { continue }
            layoutManager.enumerateEnclosingRects(forGlyphRange: found, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                let height = NotesMarkdown.lineHeight + 1
                let line = rect.offsetBy(dx: origin.x, dy: origin.y)
                let box = NSRect(x: line.minX - 3, y: line.minY + (line.height - spacing - height) / 2,
                                 width: line.width + 6, height: height)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
        NotesMarkdown.quoteBarColor.setFill()
        var bars: [NSRect] = []
        for range in drawn.quoteBars {
            // The bar goes where the ">" is (after any indent).
            let arrow = (text.substring(with: range) as NSString).range(of: ">").location
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            guard arrow != NSNotFound, let rows = band(line),
                  let mark = place(NSRange(location: range.location + arrow, length: 1)) else { continue }
            let bar = NSRect(x: mark.box.minX, y: rows.minY, width: 3, height: rows.height)
            // A quote over several lines gets one bar.
            if let last = bars.last, abs(last.minX - bar.minX) < 0.5, bar.minY - last.maxY < spacing + 1 {
                bars[bars.count - 1] = last.union(bar)
            } else {
                bars.append(bar)
            }
        }
        for bar in bars {
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        super.draw(dirtyRect)

        // On top: bullets, checkboxes, "---" lines.
        for (range, level) in drawn.bullets {
            guard let mark = place(range) else { continue }
            let center = NSPoint(x: mark.box.minX + (mark.box.width + NotesMarkdown.bulletRoom) / 2,
                                 y: mark.baseline - NotesMarkdown.baseFont.xHeight / 2)
            NotesMarkdown.drawBullet(level: level, center: center)
        }
        checkboxHits = []
        for (range, done) in drawn.checkboxes {
            guard let mark = place(range) else { continue }
            let size: CGFloat = 13
            let rect = NSRect(x: mark.box.minX, y: mark.baseline - NotesMarkdown.baseFont.capHeight / 2 - size / 2,
                              width: size, height: size)
            NotesMarkdown.drawCheckbox(done: done, in: rect)
            checkboxHits.append((rect, range))
        }
        NotesMarkdown.ruleColor.setFill()
        for range in drawn.rules {
            guard let line = band(range) else { continue }
            NSRect(x: origin.x, y: line.midY.rounded(.down), width: width, height: 1).fill()
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click on a checkbox ticks it (or unticks it), like Notion.
        if let hit = checkboxHits.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            toggleCheckbox(hit.range)
            return
        }
        // ⌘-click on a link opens it.
        if event.modifierFlags.contains(.command), let url = link(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
        // The selection is settled now that the button is up: show its lines' marks.
        restyle()
    }

    private func toggleCheckbox(_ range: NSRange) {
        let mark = NSRange(location: range.location + 1, length: 1)
        guard mark.upperBound <= (string as NSString).length else { return }
        let ticked = (string as NSString).substring(with: mark).lowercased() == "x"
        let now = ticked ? " " : "x"
        guard shouldChangeText(in: mark, replacementString: now) else { return }
        replaceCharacters(in: mark, with: now)
        didChangeText()
    }

    private func link(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let hit = drawn.links.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        let address = hit.url.contains("://") ? hit.url : "https://" + hit.url
        return URL(string: address)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { setFocus(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { setFocus(false) }
        return gave
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { setFocus(false) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    private func focusIfWanted() {
        guard wantsFocus, !hasFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, !self.hasFocus, let window = self.window else { return }
            // Each screen's pill lives in two windows: the normal one and its full-screen twin, and
            // both draw the same note. Only the copy you can see takes the cursor. Otherwise the
            // copy on the other desktop grabs the keyboard from the one you're looking at, and
            // typing ends straight away (a full-screen browser, Teams or Claude on that screen).
            guard window.isOnActiveSpace, !self.isHiddenOrHasHiddenAncestor else {
                LedgeLog.shared.write("notes: skipped the cursor in a copy of the island that isn't showing")
                return
            }
            // The cursor only takes typing in the window that has the keyboard. The island asked
            // for it already, but if another app or window took it back meanwhile, ask again.
            if !window.isKeyWindow {
                LedgeLog.shared.write("notes: island didn't have the keyboard when the note wanted the cursor (app active \(NSApp.isActive)); taking it")
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
            }
            let took = window.makeFirstResponder(self)
            LedgeLog.shared.write("notes: cursor into the note \(took ? "ok" : "refused") (window key \(window.isKeyWindow), app active \(NSApp.isActive))")
        }
    }

    /// Reported on the next turn, never in the middle of a SwiftUI update. With the cursor gone,
    /// every mark hides; with it back, its line's marks show.
    private func setFocus(_ now: Bool) {
        guard now != hasFocus else { return }
        hasFocus = now
        LedgeLog.shared.write("notes: the note \(now ? "has" : "lost") the cursor")
        restyle()
        let report = onFocusChange
        DispatchQueue.main.async { report?(now) }
    }
}

/// The note drawn as plain SwiftUI while the island is still moving: the same look.
struct MarkdownPreview: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: NotesMarkdown.lineSpacing) {
            ForEach(Array(NotesMarkdown.previewLines(text).enumerated()), id: \.offset) { _, line in
                switch line {
                case .text(let styled, let quote, let code):
                    Text(styled)
                        .lineSpacing(NotesMarkdown.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, code ? NotesMarkdown.codeInset : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(code ? Color(nsColor: NotesMarkdown.codeBoxColor) : .clear)
                        .overlay(alignment: .leading) {
                            if quote {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color(nsColor: NotesMarkdown.quoteBarColor))
                                    .frame(width: 3)
                            }
                        }
                case .rule:
                    Rectangle()
                        .fill(Color(nsColor: NotesMarkdown.ruleColor))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: NotesMarkdown.lineHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
