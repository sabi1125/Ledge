import Foundation

// MARK: - Markdown styling for the notes box

/// Finds the Markdown in a note so the notes box can draw it the way Notion or render-markdown.nvim
/// do: "## Plan" as a big "Plan", "- " as a bullet, "[ ]" as a box, "---" as a line. The text itself
/// never changes; the marks stay in it and the notes box hides them, except on the line you're on.
public enum MarkdownStyle {
    public enum Kind: Equatable, Sendable {
        /// A whole "# Title" line (level 1 to 6).
        case heading(Int)
        /// Syntax characters ("##", "**", "`", "[", "](url)"): hidden, except on the cursor's line.
        case mark
        case bold, italic, strike
        /// `code` inside a line (without its backticks).
        case code
        /// A line between ``` fences.
        case codeBlock
        /// A whole ``` block, fences included (to the end of the note while it's still open).
        case codeArea
        /// The ``` of a fence line: hidden, except on the cursor's line.
        case fence
        /// What follows an opening ``` ("bash"): shown as a small label.
        case fenceInfo
        /// The text of a [link](url), or a bare https:// link.
        case link
        /// Where a link goes: the "url" of [text](url), or a bare link itself.
        case linkURL
        /// The "> " at the start of a quote line: drawn as a bar.
        case quoteMark
        /// The text after "> ".
        case quote
        /// A "-", "*" or "+" list marker: drawn as a bullet, ●○◆◇ by how far it's indented.
        case bullet(level: Int)
        /// A "1." list marker.
        case number
        /// The "- " in front of a checkbox: hidden (the box is enough).
        case checkboxLead
        /// "[ ]" or "[x]": drawn as a box.
        case checkbox(done: Bool)
        /// The text of a ticked "- [x]" item.
        case done
        /// A "---" (or "***", "___") line: drawn as a line across.
        case rule
        /// From the start of a list or quote line to where its text starts ("    - [ ] "): wrapped
        /// lines line up under the text.
        case hang
        /// Where the cursor shouldn't stop, because nothing shows there: the bullet, box or ">"
        /// and the space after it. Arrow keys and clicks go to the text instead.
        case lead
    }

    public struct Span: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16 range in the whole text (what NSString and NSTextView use).
        public var range: NSRange

        public init(_ kind: Kind, _ range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    /// Every styled part of the text, line by line.
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        var inFence = false
        var fenceStart: Int?
        forEachLine(ns) { line, range in
            if matches(fencePattern, line) {
                if let open = fenceStart {
                    out.append(Span(.codeArea, NSRange(location: open, length: range.upperBound - open)))
                    fenceStart = nil
                } else {
                    fenceStart = range.location
                }
            }
            parseLine(line, at: range.location, inFence: &inFence, into: &out)
        }
        // A block that isn't closed yet (you're still typing it) runs to the end.
        if let open = fenceStart {
            out.append(Span(.codeArea, NSRange(location: open, length: ns.length - open)))
        }
        return out
    }

    /// True for a "---", "***" or "___" line (3 or more, spaces allowed between them).
    public static func isRule(_ line: String) -> Bool {
        matches(rulePattern, line)
    }

    // MARK: Typing helpers

    /// Typing a "`" at `cursor` would finish an opening "```": the line so far is "``", nothing
    /// follows the cursor on that line, and it isn't the end of a block already open. Returns the
    /// line's indent (for the closing "```" that goes in with it), or nil.
    public static func fenceToClose(typingBacktickAt cursor: Int, in text: String) -> String? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
        guard cursor == lineEnd(line, in: ns) else { return nil }
        let before = ns.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let m = twoTicks.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else {
            return nil
        }
        let fencesAbove = ns.substring(to: line.location)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { matches(fencePattern, String($0)) }
            .count
        guard fencesAbove % 2 == 0 else { return nil }
        return (before as NSString).substring(with: m.range(at: 1))
    }

    /// Backspace right where a list item's or quote's text starts: the marker to delete ("- ",
    /// "- [ ] ", "1. ", "> "), so the line turns back into plain text in one go, like Notion.
    /// The indent stays. Nil anywhere else.
    public static func markerToRemove(backspaceAt cursor: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = ns.substring(with: NSRange(location: line.location, length: lineEnd(line, in: ns) - line.location))
        let whole = NSRange(location: 0, length: (lineText as NSString).length)
        guard !isRule(lineText) else { return nil }
        let markerStart: Int
        let textStart: Int
        if let m = listPattern.firstMatch(in: lineText, range: whole) {
            markerStart = m.range(at: 2).location
            textStart = m.range.upperBound
        } else if let m = quotePattern.firstMatch(in: lineText, range: whole) {
            markerStart = lineText.prefix { $0 == " " || $0 == "\t" }.utf16.count
            textStart = m.range(at: 2).location
        } else {
            return nil
        }
        guard cursor == line.location + textStart, textStart > markerStart else { return nil }
        return NSRange(location: line.location + markerStart, length: textStart - markerStart)
    }

    // MARK: One line

    private static func parseLine(_ line: String, at offset: Int, inFence: inout Bool, into out: inout [Span]) {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func add(_ kind: Kind, _ range: NSRange) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            out.append(Span(kind, NSRange(location: range.location + offset, length: range.length)))
        }

        // ``` starts or ends a code block; the lines in between are code, with nothing else styled.
        if let m = fencePattern.firstMatch(in: line, range: whole) {
            inFence.toggle()
            let ticksEnd = m.range(at: 1).upperBound
            add(.fence, NSRange(location: 0, length: ticksEnd))
            add(.fenceInfo, NSRange(location: ticksEnd, length: ns.length - ticksEnd))
            return
        }
        if inFence {
            add(.codeBlock, whole)
            return
        }
        if isRule(line) {
            add(.rule, whole)
            return
        }

        var content = whole
        if let m = headingPattern.firstMatch(in: line, range: whole) {
            add(.heading(m.range(at: 1).length), whole)
            add(.mark, NSRange(location: 0, length: m.range(at: 3).location))
            content = m.range(at: 3)
        } else if let m = quotePattern.firstMatch(in: line, range: whole) {
            let marker = m.range(at: 1)
            let textStart = m.range(at: 2).location
            add(.quoteMark, marker)
            add(.quote, m.range(at: 2))
            add(.hang, NSRange(location: 0, length: textStart))
            add(.lead, NSRange(location: marker.location, length: textStart - marker.location))
            content = m.range(at: 2)
        } else if let m = listPattern.firstMatch(in: line, range: whole) {
            let indent = m.range(at: 1)
            let marker = m.range(at: 2)
            let box = m.range(at: 4)
            let textStart = m.range.upperBound
            content = NSRange(location: textStart, length: ns.length - textStart)
            add(.hang, NSRange(location: 0, length: textStart))
            if box.location != NSNotFound {
                add(.checkboxLead, NSRange(location: marker.location, length: box.location - marker.location))
                let ticked = ns.substring(with: box).lowercased().contains("x")
                add(.checkbox(done: ticked), NSRange(location: box.location, length: 3))
                add(.lead, NSRange(location: marker.location, length: textStart - marker.location))
                if ticked { add(.done, content) }
            } else if ns.substring(with: marker).first?.isNumber == true {
                add(.number, marker)
            } else {
                add(.bullet(level: level(of: ns.substring(with: indent))), marker)
                add(.lead, NSRange(location: marker.location, length: textStart - marker.location))
            }
        }
        parseInline(line, in: content, add: add)
    }

    /// Code, links, bold, italic and strikethrough inside one line's text.
    private static func parseInline(_ line: String, in content: NSRange, add: (Kind, NSRange) -> Void) {
        guard content.length > 0 else { return }
        // Code and links come first: nothing inside them is styled again.
        var taken: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in codePattern.matches(in: line, range: content) {
            add(.mark, NSRange(location: m.range.location, length: 1))
            add(.code, m.range(at: 1))
            add(.mark, NSRange(location: m.range.upperBound - 1, length: 1))
            taken.append(m.range)
        }
        for m in linkPattern.matches(in: line, range: content) where isFree(m.range) {
            let text = m.range(at: 1)
            add(.mark, NSRange(location: m.range.location, length: 1))
            add(.link, text)
            add(.mark, NSRange(location: text.upperBound, length: m.range.upperBound - text.upperBound))
            add(.linkURL, m.range(at: 2))
            taken.append(m.range)
        }
        for m in urlPattern.matches(in: line, range: content) where isFree(m.range) {
            add(.link, m.range)
            add(.linkURL, m.range)
            taken.append(m.range)
        }

        // Wrapped text: the marks on both sides are hidden, the inside gets the style.
        let wrapped: [(NSRegularExpression, Int, Kind)] = [
            (boldStars, 2, .bold), (boldUnderscores, 2, .bold),
            (italicStar, 1, .italic), (italicUnderscore, 1, .italic),
            (strikePattern, 2, .strike),
        ]
        for (pattern, width, kind) in wrapped {
            for m in pattern.matches(in: line, range: content) where isFree(m.range) {
                add(.mark, NSRange(location: m.range.location, length: width))
                add(kind, NSRange(location: m.range.location + width, length: m.range.length - 2 * width))
                add(.mark, NSRange(location: m.range.upperBound - width, length: width))
            }
        }
    }

    // MARK: Small helpers

    /// How deep a list item is: every 4 spaces (or a tab) of indent is one level; 2 also counts.
    private static func level(of indent: String) -> Int {
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (width + 2) / 4
    }

    /// Calls `body` with each line's text and its range (without the "\n").
    private static func forEachLine(_ ns: NSString, _ body: (String, NSRange) -> Void) {
        var start = 0
        while true {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let range = NSRange(location: start, length: end - start)
            body(ns.substring(with: range), range)
            if newline.location == NSNotFound { return }
            start = end + 1
        }
    }

    /// Where a line's text ends (before its "\n", if it has one).
    private static func lineEnd(_ line: NSRange, in ns: NSString) -> Int {
        line.length > 0 && ns.character(at: line.upperBound - 1) == 10 ? line.upperBound - 1 : line.upperBound
    }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let fencePattern = regex(#"^[ \t]*(```|~~~)"#)
    private static let twoTicks = regex(#"^([ \t]*)``$"#)
    private static let rulePattern = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    /// "## Title": the hashes, the spaces, then the title.
    private static let headingPattern = regex(#"^(#{1,6})([ \t]+)(.*)$"#)
    /// "> quote": the indent and ">" with one space, then the text.
    private static let quotePattern = regex(#"^([ \t]*>[ \t]?)(.*)$"#)
    /// "- item", "1. item", "- [ ] step": indent, marker, spaces, then an optional checkbox.
    private static let listPattern = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#)
    private static let codePattern = regex(#"`([^`]+)`"#)
    private static let linkPattern = regex(#"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let urlPattern = regex(#"\bhttps?://[^\s<>()]+"#)
    private static let boldStars = regex(#"(?<!\*)\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*(?!\*)"#)
    private static let boldUnderscores = regex(#"(?<![\w_])__(?=[^\s_])(.+?)(?<=[^\s_])__(?![\w_])"#)
    private static let italicStar = regex(#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
    /// Not inside a word, so snake_case_names stay plain.
    private static let italicUnderscore = regex(#"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#)
    private static let strikePattern = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
}
