import Foundation

// MARK: - Vim keys for the notes box

/// The notes box's Vim keys, when "Vim motions" is on in settings. This is the pure part: it gets
/// a key, the text and the selection, and says what to do. The text view does it.
///
/// What's in:
/// - Counts in front of anything ("3w", "2dd", "d2w").
/// - Motions: h j k l (and the arrow keys), w b e, W B E, 0 ^ $, gg G, f F t T, + - _ and return.
/// - Typing: i a I A o O. Esc (or ⌃[ or ⌃C) goes back to normal mode.
/// - Changes: d c y with any motion or text object, dd cc yy, x X D C s S Y, r, J, p P.
/// - u and ⌃R undo and redo.
/// - v and V select (the same motions move the end), o swaps the ends, then d x y c s p J.
/// - Text objects: iw aw iW aW, i" a" i' a' i` a`, i( a( ib ab, i[ a[, i{ a{ iB aB, i< a<.
///
/// Words follow Vim, Japanese included: kanji, hiragana and katakana are separate words, so "w"
/// in 「日本語のテキスト」 stops at 「の」 and at 「テ」.
public struct Vim {
    public enum Mode: Equatable {
        case normal, insert, visual, visualLine
    }

    /// One change to the text: what's in `range` becomes `text`.
    public struct Edit: Equatable {
        public var range: NSRange
        public var text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// What the text view should do with a key.
    public enum Action: Equatable {
        /// Not a Vim key here: the text view handles it as usual (typing in insert mode).
        case pass
        /// Taken, and nothing to show yet: half a command ("d", "2", "f"), or a key that does nothing.
        case wait
        /// Make the change (if any), then put the cursor or the selection here.
        case apply(edit: Edit?, selection: NSRange)
        case undo
        case redo
    }

    public private(set) var mode: Mode = .normal
    /// The keys of a command that isn't finished yet ("2d", "ci", "f").
    public private(set) var pending: [String] = []
    /// What d, c, y, x and friends took, for p and P. `registerIsLines`: whole lines (dd, yy, V).
    private var register = ""
    private var registerIsLines = false
    /// Visual mode: where it started, and the end that moves.
    private var anchor = 0
    private var head = 0
    /// The selection visual mode last showed. A different one means a click: back to normal mode.
    private var shown: NSRange?
    /// The column j and k keep to (Int.max after "$": the end of each line).
    private var column: Int?

    public init() {}

    /// Normal mode, nothing half typed. Used when the box gets the cursor.
    public mutating func reset() {
        mode = .normal
        pending = []
        shown = nil
        column = nil
    }

    /// Esc has something to do here: leave insert or visual mode, or drop a half typed command.
    /// In normal mode with nothing pending, Esc is free for the island (it closes it).
    public var wantsEscape: Bool { mode != .normal || !pending.isEmpty }

    /// Handles one key. Keys are single characters ("w", "G", "$", "日"), or a name in angle
    /// brackets: "<Esc>", "<CR>", "<BS>", "<Tab>", "<C-r>".
    public mutating func handle(_ key: String, text: String, selection: NSRange) -> Action {
        let buffer = VimText(text)
        switch mode {
        case .insert:
            guard key == "<Esc>" else { return .pass }
            mode = .normal
            pending = []
            column = nil
            // Like Vim, the cursor steps back onto the last character typed.
            let at = min(selection.location, buffer.length)
            let back = at > buffer.lineStart(at) ? buffer.before(at) : at
            return .apply(edit: nil, selection: caret(buffer.clamp(back)))
        case .normal:
            return normal(key, buffer, selection)
        case .visual, .visualLine:
            return visual(key, buffer, selection)
        }
    }

    // MARK: Normal mode

    private mutating func normal(_ key: String, _ b: VimText, _ selection: NSRange) -> Action {
        // A selection made with the mouse: carry on in visual mode.
        if selection.length > 0 && pending.isEmpty {
            mode = .visual
            anchor = selection.location
            head = b.before(selection.upperBound)
            shown = selection
            return visual(key, b, selection)
        }
        let cursor = b.clamp(selection.location)
        if key == "<Esc>" {
            pending = []
            return .apply(edit: nil, selection: caret(cursor))
        }
        let keys = pending + [key]
        switch parse(keys, visual: false) {
        case .incomplete:
            pending = keys
            return .wait
        case .invalid:
            pending = []
            return .wait
        case .command(let count, let op, let name):
            pending = []
            return run(count: count, op: op, name: name, cursor: cursor, b) ?? .wait
        }
    }

    /// Runs a parsed normal mode command. Nil when it can't (no such character for "f", no line below).
    private mutating func run(count: Int?, op: String?, name: String, cursor c: Int, _ b: VimText) -> Action? {
        let n = max(1, count ?? 1)
        if op != nil || !(name == "j" || name == "k") { column = nil }

        if let op {
            if name == "line" {
                var last = b.lineStart(c)
                for _ in 1..<n {
                    guard let next = b.nextLine(last) else { break }
                    last = next
                }
                return operate(op, lines: c, last, cursor: c, b)
            }
            if Self.isObject(name) {
                guard let range = object(name, at: c, b) else { return nil }
                return operate(op, chars: range, b)
            }
            guard let target = target(name, from: c, count: count, b, op: op) else { return nil }
            let low = min(c, target.index), high = max(c, target.index)
            switch target.reach {
            case .lines:
                return operate(op, lines: low, high, cursor: c, b)
            case .exclusive:
                return operate(op, chars: NSRange(location: low, length: high - low), b)
            case .inclusive:
                return operate(op, chars: NSRange(location: low, length: b.after(high) - low), b)
            }
        }

        switch name {
        case "i":
            return insert(at: c)
        case "a":
            return insert(at: c < b.lineEnd(c) ? b.after(c) : c)
        case "I":
            return insert(at: b.firstNonBlank(c))
        case "A":
            return insert(at: b.lineEnd(c))
        case "o":
            let at = b.lineEnd(c)
            mode = .insert
            return .apply(edit: Edit(range: NSRange(location: at, length: 0), text: "\n"), selection: caret(at + 1))
        case "O":
            let at = b.lineStart(c)
            mode = .insert
            // On a list or quote line, the new line above is an item of it too (o gets this from
            // the typing helpers, like return).
            let line = b.s.substring(with: NSRange(location: at, length: b.lineEnd(c) - at))
            let start = Checklist.itemStart(for: line) ?? ""
            return .apply(edit: Edit(range: NSRange(location: at, length: 0), text: start + "\n"),
                          selection: caret(at + (start as NSString).length))
        case "x":
            return run(count: count, op: "d", name: "l", cursor: c, b)
        case "X":
            return run(count: count, op: "d", name: "h", cursor: c, b)
        case "D":
            return run(count: count, op: "d", name: "$", cursor: c, b)
        case "C":
            return run(count: count, op: "c", name: "$", cursor: c, b)
        case "s":
            return run(count: count, op: "c", name: "l", cursor: c, b)
        case "S":
            return run(count: count, op: "c", name: "line", cursor: c, b)
        case "Y":
            return run(count: count, op: "y", name: "line", cursor: c, b)
        case "p", "P":
            return put(after: name == "p", count: n, cursor: c, b)
        case "J":
            return join(lines: max(2, n), from: c, b)
        case "u":
            return .undo
        case "<C-r>":
            return .redo
        case "v", "V":
            mode = name == "v" ? .visual : .visualLine
            anchor = c
            head = c
            return showVisual(b)
        default:
            if name.count == 2 && name.hasPrefix("r") {
                return replace(with: String(name.dropFirst()), count: n, cursor: c, b)
            }
            guard let target = target(name, from: c, count: count, b, op: nil) else { return nil }
            return .apply(edit: nil, selection: caret(b.clamp(target.index)))
        }
    }

    private mutating func insert(at index: Int) -> Action {
        mode = .insert
        return .apply(edit: nil, selection: caret(index))
    }

    // MARK: Visual mode

    private mutating func visual(_ key: String, _ b: VimText, _ selection: NSRange) -> Action {
        // The selection moved under us (a click): this key belongs to normal mode.
        if let shown, shown != selection {
            mode = .normal
            pending = []
            self.shown = nil
            return normal(key, b, selection)
        }
        anchor = min(anchor, b.length)
        head = min(head, b.length)
        if key == "<Esc>" {
            pending = []
            return leaveVisual(b, cursor: head)
        }
        let keys = pending + [key]
        switch parse(keys, visual: true) {
        case .incomplete:
            pending = keys
            return .wait
        case .invalid:
            pending = []
            return .wait
        case .command(let count, _, let name):
            pending = []
            return visualCommand(count: count, name: name, b) ?? .wait
        }
    }

    private mutating func visualCommand(count: Int?, name: String, _ b: VimText) -> Action? {
        if !(name == "j" || name == "k") { column = nil }
        let low = min(anchor, head), high = max(anchor, head)
        let lines = mode == .visualLine
        switch name {
        case "v":
            if mode == .visual { return leaveVisual(b, cursor: head) }
            mode = .visual
            return showVisual(b)
        case "V":
            if mode == .visualLine { return leaveVisual(b, cursor: head) }
            mode = .visualLine
            return showVisual(b)
        case "o":
            swap(&anchor, &head)
            return showVisual(b)
        case "d", "x", "X", "D", "y", "Y", "c", "s", "S", "C":
            let op: String
            switch name {
            case "y", "Y": op = "y"
            case "c", "s", "S", "C": op = "c"
            default: op = "d"
            }
            let range = visualRange(b)
            leave()
            // X, D, Y, S and C take whole lines in Vim, even from v.
            if lines || ["X", "D", "Y", "S", "C"].contains(name) {
                return operate(op, lines: low, high, cursor: low, b)
            }
            return operate(op, chars: range, b)
        case "p", "P":
            guard !register.isEmpty else { return nil }
            let range = visualRange(b)
            leave()
            let after = b.replacing(range, with: register)
            return .apply(edit: Edit(range: range, text: register), selection: caret(after.clamp(range.location)))
        case "J":
            var count = 1
            var line = b.lineStart(low)
            while let next = b.nextLine(line), next <= high {
                count += 1
                line = next
            }
            leave()
            return join(lines: max(2, count), from: low, b)
        default:
            if Self.isObject(name) {
                guard let range = object(name, at: head, b), range.length > 0 else { return nil }
                mode = .visual
                anchor = range.location
                head = b.before(range.upperBound)
                return showVisual(b)
            }
            guard let target = target(name, from: head, count: count, b, op: nil) else { return nil }
            head = b.clamp(target.index)
            return showVisual(b)
        }
    }

    /// What visual mode has selected: from one end through the character under the other, or
    /// every line it touches (V).
    private func visualRange(_ b: VimText) -> NSRange {
        let low = min(anchor, head), high = max(anchor, head)
        if mode == .visualLine {
            let start = b.lineStart(low)
            let end = b.nextLine(high) ?? b.lineEnd(high)
            return NSRange(location: start, length: end - start)
        }
        return NSRange(location: low, length: max(b.after(high), high) - low)
    }

    private mutating func showVisual(_ b: VimText) -> Action {
        let range = visualRange(b)
        shown = range
        return .apply(edit: nil, selection: range)
    }

    private mutating func leave() {
        mode = .normal
        shown = nil
    }

    private mutating func leaveVisual(_ b: VimText, cursor: Int) -> Action {
        leave()
        return .apply(edit: nil, selection: caret(b.clamp(cursor)))
    }

    // MARK: Changes

    /// d, c or y over whole lines: the lines holding `first` through `last`.
    private mutating func operate(_ op: String, lines first: Int, _ last: Int, cursor c: Int, _ b: VimText) -> Action {
        let start = b.lineStart(first)
        let contentsEnd = b.lineEnd(last)
        let end = b.nextLine(last) ?? contentsEnd
        var taken = b.substring(start, end)
        if !taken.hasSuffix("\n") { taken += "\n" }
        register = taken
        registerIsLines = true
        switch op {
        case "y":
            // yk and friends move up to the first line; yy and yj leave the cursor alone.
            let stays = b.lineStart(c) == start
            return .apply(edit: nil, selection: caret(stays ? c : b.firstNonBlank(start)))
        case "c":
            // The lines' text goes; one empty line stays to type on.
            mode = .insert
            let range = NSRange(location: start, length: contentsEnd - start)
            return .apply(edit: Edit(range: range, text: ""), selection: caret(start))
        default:
            var range = NSRange(location: start, length: end - start)
            // The last line has no line break after it: take the one before it instead.
            if end == contentsEnd && start > 0 {
                let previousBreak = b.before(start)
                range = NSRange(location: previousBreak, length: end - previousBreak)
            }
            let after = b.replacing(range, with: "")
            let cursor = after.firstNonBlank(min(range.location, after.length))
            return .apply(edit: Edit(range: range, text: ""), selection: caret(after.clamp(cursor)))
        }
    }

    /// d, c or y over characters.
    private mutating func operate(_ op: String, chars range: NSRange, _ b: VimText) -> Action {
        if range.length > 0 {
            register = b.substring(range.location, range.upperBound)
            registerIsLines = false
        }
        switch op {
        case "y":
            return .apply(edit: nil, selection: caret(b.clamp(range.location)))
        case "c":
            mode = .insert
            let edit = range.length > 0 ? Edit(range: range, text: "") : nil
            return .apply(edit: edit, selection: caret(range.location))
        default:
            guard range.length > 0 else { return .apply(edit: nil, selection: caret(b.clamp(range.location))) }
            let after = b.replacing(range, with: "")
            return .apply(edit: Edit(range: range, text: ""), selection: caret(after.clamp(range.location)))
        }
    }

    /// p (after the cursor, or below the line) and P (before it, or above).
    private mutating func put(after: Bool, count: Int, cursor c: Int, _ b: VimText) -> Action? {
        guard !register.isEmpty else { return nil }
        let copies = String(repeating: register, count: count)
        if registerIsLines {
            let at: Int
            let text: String
            if !after {
                at = b.lineStart(c)
                text = copies
            } else if let next = b.nextLine(c) {
                at = next
                text = copies
            } else {
                // Below the last line: it needs a line break first.
                at = b.lineEnd(c)
                text = "\n" + copies.dropLast()
            }
            let result = b.replacing(NSRange(location: at, length: 0), with: text)
            let firstLine = text.hasPrefix("\n") ? at + 1 : at
            return .apply(edit: Edit(range: NSRange(location: at, length: 0), text: text),
                          selection: caret(result.clamp(result.firstNonBlank(firstLine))))
        }
        let at = after && c < b.lineEnd(c) ? b.after(c) : c
        let result = b.replacing(NSRange(location: at, length: 0), with: copies)
        // The cursor ends on the last character put in.
        let last = result.before(at + (copies as NSString).length)
        return .apply(edit: Edit(range: NSRange(location: at, length: 0), text: copies), selection: caret(result.clamp(last)))
    }

    /// J: this line and the next ones (`lines` in all) become one, with a space where they meet.
    private func join(lines: Int, from c: Int, _ b: VimText) -> Action? {
        let start = b.lineStart(c)
        guard b.nextLine(start) != nil else { return nil }
        var result = b.substring(start, b.lineEnd(start))
        var joint = (result as NSString).length
        var line = start
        var joined = 1
        while joined < lines, let next = b.nextLine(line) {
            let body = b.substring(b.firstNonBlank(next), b.lineEnd(next))
            let space = !body.isEmpty && !result.isEmpty && !result.hasSuffix(" ") && !body.hasPrefix(")")
            joint = (result as NSString).length
            result += (space ? " " : "") + body
            line = next
            joined += 1
        }
        let range = NSRange(location: start, length: b.lineEnd(line) - start)
        let after = b.replacing(range, with: result)
        return .apply(edit: Edit(range: range, text: result), selection: caret(after.clamp(start + joint)))
    }

    /// r: the character under the cursor (and the next ones, with a count) becomes this one.
    private func replace(with character: String, count: Int, cursor c: Int, _ b: VimText) -> Action? {
        var end = c
        var replaced = 0
        while replaced < count && end < b.lineEnd(c) {
            end = b.after(end)
            replaced += 1
        }
        guard replaced == count else { return nil }
        let text = String(repeating: character, count: count)
        let last = c + (count - 1) * (character as NSString).length
        return .apply(edit: Edit(range: NSRange(location: c, length: end - c), text: text), selection: caret(last))
    }

    // MARK: Motions

    private enum Reach { case exclusive, inclusive, lines }

    private struct Target {
        var index: Int
        var reach: Reach
    }

    /// Where a motion goes from `c`. Nil when it can't go (no line below, no such character).
    private mutating func target(_ name: String, from c: Int, count: Int?, _ b: VimText, op: String?) -> Target? {
        let n = max(1, count ?? 1)
        switch name {
        case "h", "<BS>":
            var j = c
            let start = b.lineStart(c)
            for _ in 0..<n where j > start { j = b.before(j) }
            return Target(index: j, reach: .exclusive)
        case "l", " ":
            var j = c
            let end = b.lineEnd(c)
            for _ in 0..<n where j < end { j = b.after(j) }
            return Target(index: j, reach: .exclusive)
        case "j", "k", "+", "-", "<CR>", "_":
            let up = name == "k" || name == "-"
            var line = b.lineStart(c)
            for _ in 0..<(name == "_" ? n - 1 : n) {
                guard let next = up ? b.previousLine(line) : b.nextLine(line) else { break }
                line = next
            }
            if name != "_" && line == b.lineStart(c) { return nil }
            if name == "j" || name == "k" {
                let wanted = column ?? b.column(c)
                column = wanted
                return Target(index: b.index(onLineAt: line, column: wanted), reach: .lines)
            }
            return Target(index: b.firstNonBlank(line), reach: .lines)
        case "0":
            return Target(index: b.lineStart(c), reach: .exclusive)
        case "^":
            return Target(index: b.firstNonBlank(c), reach: .exclusive)
        case "$":
            var line = b.lineStart(c)
            for _ in 1..<n {
                guard let next = b.nextLine(line) else { break }
                line = next
            }
            column = Int.max
            let end = b.lineEnd(line)
            return end > line ? Target(index: b.before(end), reach: .inclusive) : Target(index: end, reach: .exclusive)
        case "gg", "G":
            let line = count.map { b.line($0) } ?? (name == "gg" ? 0 : b.lineStart(b.length))
            return Target(index: b.firstNonBlank(line), reach: .lines)
        case "w", "W":
            let big = name == "W"
            // cw on a word changes to the end of the word, not up to the next one (like ce).
            if op == "c" && b.kind(c, big: big) != 0 {
                var j = b.endOfWord(c, big: big)
                for _ in 1..<n { j = b.wordEnd(j, big: big) }
                return Target(index: j, reach: .inclusive)
            }
            var j = c
            for _ in 0..<n { j = b.wordForward(j, big: big) }
            // With an operator, w stops at the end of the line instead of eating the line break.
            if op != nil {
                let targetLine = b.lineStart(j)
                if targetLine > b.lineStart(c) { j = max(c, b.lineEnd(b.before(targetLine))) }
            }
            return Target(index: j, reach: .exclusive)
        case "e", "E":
            var j = c
            for _ in 0..<n { j = b.wordEnd(j, big: name == "E") }
            return Target(index: j, reach: .inclusive)
        case "b", "B":
            var j = c
            for _ in 0..<n { j = b.wordBack(j, big: name == "B") }
            return Target(index: j, reach: .exclusive)
        default:
            return find(name, from: c, count: n, b)
        }
    }

    /// f F t T and the character to look for, on the cursor's line.
    private func find(_ name: String, from c: Int, count: Int, _ b: VimText) -> Target? {
        guard name.count == 2, let kind = name.first, "fFtT".contains(kind) else { return nil }
        let wanted = String(name.dropFirst())
        var found = 0
        if kind == "f" || kind == "t" {
            var k = b.after(c)
            let end = b.lineEnd(c)
            while k < end {
                if b.char(k) == wanted {
                    found += 1
                    if found == count { return Target(index: kind == "f" ? k : b.before(k), reach: .inclusive) }
                }
                k = b.after(k)
            }
            return nil
        }
        var k = c
        let start = b.lineStart(c)
        while k > start {
            k = b.before(k)
            if b.char(k) == wanted {
                found += 1
                if found == count { return Target(index: kind == "F" ? k : b.after(k), reach: .exclusive) }
            }
        }
        return nil
    }

    // MARK: Text objects

    private static func isObject(_ name: String) -> Bool {
        name.count == 2 && (name.hasPrefix("i") || name.hasPrefix("a"))
    }

    /// The range of iw, a", i( and the rest, around `c`.
    private func object(_ name: String, at c: Int, _ b: VimText) -> NSRange? {
        let inner = name.hasPrefix("i")
        let what = String(name.dropFirst())
        switch what {
        case "w", "W":
            let big = what == "W"
            guard c < b.length, !b.isBreak(c) else { return nil }
            let lineStart = b.lineStart(c), lineEnd = b.lineEnd(c)
            let kind = b.kind(c, big: big)
            var start = c
            while start > lineStart && b.kind(b.before(start), big: big) == kind { start = b.before(start) }
            var end = b.after(c)
            while end < lineEnd && b.kind(end, big: big) == kind { end = b.after(end) }
            if !inner {
                // aw: the spaces after the word, or before it when there are none after.
                var spaced = end
                while spaced < lineEnd && b.isBlank(spaced) { spaced = b.after(spaced) }
                if spaced > end {
                    end = spaced
                } else {
                    while start > lineStart && b.isBlank(b.before(start)) { start = b.before(start) }
                }
            }
            return NSRange(location: start, length: end - start)
        case "\"", "'", "`":
            // The quotes on the cursor's line pair up in order; take the pair around the cursor,
            // or the first one after it.
            var quotes: [Int] = []
            var k = b.lineStart(c)
            let end = b.lineEnd(c)
            while k < end {
                if b.char(k) == what && (quotes.count % 2 == 1 || k == b.lineStart(c) || b.char(b.before(k)) != "\\") {
                    quotes.append(k)
                }
                k = b.after(k)
            }
            var pair = 0
            while pair + 1 < quotes.count {
                let open = quotes[pair], close = quotes[pair + 1]
                if close >= c {
                    if inner { return NSRange(location: open + 1, length: close - open - 1) }
                    // a": the spaces after the closing quote, or before the opening one when there are none after.
                    var start = open, end = b.after(close)
                    if end < b.lineEnd(c) && b.isBlank(end) {
                        while end < b.lineEnd(c) && b.isBlank(end) { end = b.after(end) }
                    } else {
                        while start > b.lineStart(c) && b.isBlank(b.before(start)) { start = b.before(start) }
                    }
                    return NSRange(location: start, length: end - start)
                }
                pair += 2
            }
            return nil
        default:
            let pairs: [String: (String, String)] = [
                "(": ("(", ")"), ")": ("(", ")"), "b": ("(", ")"),
                "[": ("[", "]"), "]": ("[", "]"),
                "{": ("{", "}"), "}": ("{", "}"), "B": ("{", "}"),
                "<": ("<", ">"), ">": ("<", ">"),
            ]
            guard let (open, close) = pairs[what] else { return nil }
            // Back to the bracket that opens around the cursor (the cursor may be on it)…
            var from: Int?
            if b.char(c) == open {
                from = c
            } else {
                var depth = 0
                var k = c
                while k > 0 {
                    k = b.before(k)
                    let ch = b.char(k)
                    if ch == close {
                        depth += 1
                    } else if ch == open {
                        if depth == 0 { from = k; break }
                        depth -= 1
                    }
                }
            }
            guard let from else { return nil }
            // …then on to the one that closes it.
            var depth = 0
            var k = b.after(from)
            while k < b.length {
                let ch = b.char(k)
                if ch == open {
                    depth += 1
                } else if ch == close {
                    if depth == 0 {
                        return inner ? NSRange(location: b.after(from), length: k - b.after(from))
                            : NSRange(location: from, length: b.after(k) - from)
                    }
                    depth -= 1
                }
                k = b.after(k)
            }
            return nil
        }
    }

    // MARK: Reading keys

    private enum Parsed {
        case incomplete, invalid
        case command(count: Int?, op: String?, name: String)
    }

    private static let operators: Set<String> = ["d", "c", "y"]
    private static let motions: Set<String> = [
        "h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "G", "+", "-", "_", "<CR>", "<BS>", " ",
    ]

    /// Reads "[count] command", "[count] operator [count] motion" and the like. Motions with a
    /// second key ("gg", "fx", "iw") come back as one name. "dd" comes back as "line".
    private func parse(_ keys: [String], visual: Bool) -> Parsed {
        var i = 0
        func readCount() -> Int? {
            var value: Int?
            while i < keys.count, keys[i].count == 1, let digit = Int(keys[i]), value != nil || digit != 0 {
                value = (value ?? 0) * 10 + digit
                i += 1
            }
            return value
        }
        /// A motion (or, after an operator or in visual mode, a text object) from keys[i] on.
        func readTarget(objects: Bool) -> Parsed {
            guard i < keys.count else { return .incomplete }
            let first = keys[i]
            i += 1
            if Self.motions.contains(first) { return .command(count: nil, op: nil, name: first) }
            let takesCharacter = "fFtT".contains(first) && first.count == 1
            let isObject = objects && (first == "i" || first == "a")
            guard first == "g" || takesCharacter || isObject else { return .invalid }
            guard i < keys.count else { return .incomplete }
            let second = keys[i]
            i += 1
            if first == "g" { return second == "g" ? .command(count: nil, op: nil, name: "gg") : .invalid }
            guard second.count == 1 else { return .invalid }
            return .command(count: nil, op: nil, name: first + second)
        }

        let count = readCount()
        guard i < keys.count else { return .incomplete }
        let key = keys[i]

        if !visual && Self.operators.contains(key) {
            i += 1
            let motionCount = readCount()
            let total = count == nil && motionCount == nil ? nil : (count ?? 1) * (motionCount ?? 1)
            guard i < keys.count else { return .incomplete }
            if keys[i] == key { return .command(count: total, op: key, name: "line") }
            switch readTarget(objects: true) {
            case .command(_, _, let name): return .command(count: total, op: key, name: name)
            case let unfinished: return unfinished
            }
        }
        if !visual && key == "r" {
            guard i + 1 < keys.count else { return .incomplete }
            let character = keys[i + 1]
            return character.count == 1 ? .command(count: count, op: nil, name: "r" + character) : .invalid
        }
        if key == "g" || ("fFtT".contains(key) && key.count == 1) || (visual && (key == "i" || key == "a")) {
            switch readTarget(objects: visual) {
            case .command(_, _, let name): return .command(count: count, op: nil, name: name)
            case let unfinished: return unfinished
            }
        }
        return .command(count: count, op: nil, name: key)
    }
}

// MARK: - The text, as Vim sees it

/// The note's text with the line and word helpers Vim needs. Indexes are UTF-16, like NSString
/// and NSTextView; a step is always a whole character (an emoji or 「が」 never splits).
struct VimText {
    let s: NSString

    init(_ text: String) {
        s = text as NSString
    }

    var length: Int { s.length }

    func after(_ i: Int) -> Int {
        guard i < length else { return length }
        return s.rangeOfComposedCharacterSequence(at: i).upperBound
    }

    func before(_ i: Int) -> Int {
        guard i > 0 else { return 0 }
        return s.rangeOfComposedCharacterSequence(at: min(i, length) - 1).location
    }

    func char(_ i: Int) -> String {
        guard i >= 0 && i < length else { return "" }
        return s.substring(with: s.rangeOfComposedCharacterSequence(at: i))
    }

    func substring(_ from: Int, _ to: Int) -> String {
        s.substring(with: NSRange(location: from, length: max(0, to - from)))
    }

    func replacing(_ range: NSRange, with text: String) -> VimText {
        VimText(s.replacingCharacters(in: range, with: text))
    }

    func isBreak(_ i: Int) -> Bool {
        let c = char(i)
        return c == "\n" || c == "\r\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}"
    }

    func isBlank(_ i: Int) -> Bool {
        let c = char(i)
        return c == " " || c == "\t" || c == "\u{3000}"
    }

    // MARK: Lines

    private func bounds(_ i: Int) -> (start: Int, end: Int, contentsEnd: Int) {
        var start = 0, end = 0, contentsEnd = 0
        s.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(max(0, i), length), length: 0))
        return (start, end, contentsEnd)
    }

    func lineStart(_ i: Int) -> Int { bounds(i).start }

    /// Where the line's text ends (before its line break).
    func lineEnd(_ i: Int) -> Int { bounds(i).contentsEnd }

    /// The start of the line after this one, if there is one.
    func nextLine(_ i: Int) -> Int? {
        let line = bounds(i)
        return line.end > line.contentsEnd ? line.end : nil
    }

    func previousLine(_ i: Int) -> Int? {
        let start = lineStart(i)
        return start > 0 ? lineStart(start - 1) : nil
    }

    /// The start of line `number` (from 1), or of the last line.
    func line(_ number: Int) -> Int {
        var start = 0
        var current = 1
        while current < number, let next = nextLine(start) {
            start = next
            current += 1
        }
        return start
    }

    func firstNonBlank(_ i: Int) -> Int {
        var j = lineStart(i)
        let end = lineEnd(i)
        while j < end && isBlank(j) { j = after(j) }
        return j
    }

    /// Where the cursor may sit in normal mode: on a character, never on the line break
    /// (except on an empty line).
    func clamp(_ i: Int) -> Int {
        let i = min(max(0, i), length)
        let line = bounds(i)
        let last = line.contentsEnd > line.start ? before(line.contentsEnd) : line.start
        return min(max(i, line.start), last)
    }

    /// Characters from the start of the line.
    func column(_ i: Int) -> Int {
        var j = lineStart(i)
        var count = 0
        while j < i {
            j = after(j)
            count += 1
        }
        return count
    }

    func index(onLineAt start: Int, column: Int) -> Int {
        var j = start
        let end = lineEnd(start)
        var count = 0
        while count < column && j < end {
            j = after(j)
            count += 1
        }
        return clamp(j)
    }

    // MARK: Words

    /// Which kind of word a character belongs to: 0 for blanks and line breaks. Kanji, hiragana
    /// and katakana are kinds of their own, like in Vim. With `big` (W B E) anything not blank is one kind.
    func kind(_ i: Int, big: Bool) -> Int {
        guard let u = char(i).unicodeScalars.first else { return 0 }
        if CharacterSet.whitespacesAndNewlines.contains(u) { return 0 }
        if big { return 1 }
        switch u.value {
        case 0x3040...0x309F: return 3
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return 4
        case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return 5
        default: break
        }
        if u == "_" || CharacterSet.alphanumerics.contains(u) { return 2 }
        return 1
    }

    /// w: the start of the next word (an empty line counts as one).
    func wordForward(_ i: Int, big: Bool) -> Int {
        var j = i
        let current = kind(j, big: big)
        if current != 0 {
            while j < length && kind(j, big: big) == current { j = after(j) }
        }
        while j < length && kind(j, big: big) == 0 {
            if isBreak(j) {
                let next = after(j)
                if next < length && isBreak(next) { return next }
            }
            j = after(j)
        }
        return j
    }

    /// e: the end of this word, or of the next one when already at the end.
    func wordEnd(_ i: Int, big: Bool) -> Int {
        var j = after(i)
        while j < length && kind(j, big: big) == 0 { j = after(j) }
        guard j < length else { return i }
        return endOfWord(j, big: big)
    }

    /// The last character of the word under `i`.
    func endOfWord(_ i: Int, big: Bool) -> Int {
        let current = kind(i, big: big)
        var j = i
        while after(j) < length && kind(after(j), big: big) == current { j = after(j) }
        return j
    }

    /// b: the start of this word, or of the one before when already at the start.
    func wordBack(_ i: Int, big: Bool) -> Int {
        guard i > 0 else { return 0 }
        var j = before(i)
        while j > 0 && kind(j, big: big) == 0 { j = before(j) }
        let current = kind(j, big: big)
        while j > 0 && kind(before(j), big: big) == current { j = before(j) }
        return j
    }
}

private func caret(_ index: Int) -> NSRange {
    NSRange(location: index, length: 0)
}
