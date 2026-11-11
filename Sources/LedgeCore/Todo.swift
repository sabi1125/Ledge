import Foundation

// MARK: - Typing a to-do

/// What quick add understood from a to-do line like "! Reply to 菅さん's review fri #s3 [30m]".
public struct TodoDraft: Equatable, Sendable {
    /// The title and due date, read the same way as an event ("fri", "tomorrow 3pm"…).
    /// `foundDate` false means no due date.
    public var event: QuickEventDraft
    /// "!" anywhere: a must (saved as high priority).
    public var isMust: Bool
    /// "#s3": the list to save to, matched against your Reminders lists by name.
    public var listTag: String?
    /// "[30m]", "[2h]": your time guess, in minutes.
    public var minutes: Int?
    /// A link in the text (a Backlog ticket, say), saved as the reminder's URL.
    public var url: URL?

    public var title: String { event.title }
    public var hasDue: Bool { event.foundDate }
    /// The due date has a time of day ("fri 3pm"), not just a day ("fri").
    public var dueHasTime: Bool { event.foundDate && !event.isAllDay }
}

public enum TodoInput {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> TodoDraft {
        var rest = text
        var url: URL?
        var tag: String?
        var minutes: Int?
        var must = false

        if let m = first(Pattern.url, in: rest) {
            url = URL(string: (rest as NSString).substring(with: m.range))
            rest = removing(m.range, from: rest)
        }
        if let m = first(Pattern.tag, in: rest) {
            tag = (rest as NSString).substring(with: m.range(at: 1))
            rest = removing(m.range, from: rest)
        }
        if let m = first(Pattern.guess, in: rest) {
            let ns = rest as NSString
            if let n = Double(ns.substring(with: m.range(at: 1))) {
                let unit = ns.substring(with: m.range(at: 2)).lowercased()
                minutes = Int((unit.hasPrefix("h") ? n * 60 : n).rounded())
            }
            rest = removing(m.range, from: rest)
        }
        // "!" on its own, or stuck to the front of a word ("!Check the feedback").
        while let m = first(Pattern.must, in: rest) {
            must = true
            rest = removing(m.range(at: 1), from: rest)
        }

        var event = QuickEventParser.parse(rest, now: now, calendar: calendar)
        event.title = event.title.trimmingCharacters(in: .whitespaces)
        return TodoDraft(event: event, isMust: must, listTag: tag, minutes: minutes, url: url)
    }

    private enum Pattern {
        static func make(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        static let url = make(#"https?://\S+"#)
        static let tag = make(#"(?<![\w#])#([^\s#]+)"#)
        static let guess = make(#"\[\s*(\d+(?:\.\d+)?)\s*(m|min|mins|h|hr|hrs)\s*\]"#)
        static let must = make(#"(?:^|(?<=\s))(!)(?=\s|$|\S)"#)
    }

    private static func first(_ p: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        p.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func removing(_ range: NSRange, from text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: " ")
    }
}

// MARK: - Titles in Reminders

/// The time guess lives at the end of the reminder's title ("Reply to the review [30m]"),
/// so it syncs everywhere and reads naturally in the Reminders app too.
public enum TodoTitle {
    public static func split(_ raw: String) -> (title: String, minutes: Int?) {
        let ns = raw as NSString
        guard let m = guess.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              let n = Double(ns.substring(with: m.range(at: 1))) else {
            return (raw.trimmingCharacters(in: .whitespaces), nil)
        }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        let minutes = Int((unit.hasPrefix("h") ? n * 60 : n).rounded())
        let title = ns.replacingCharacters(in: m.range, with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (title, minutes)
    }

    /// Written as "[30m]", "[2h]" or "[90m]", so it can always be read back.
    public static func join(_ title: String, minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return title }
        return minutes % 60 == 0 ? "\(title) [\(minutes / 60)h]" : "\(title) [\(minutes)m]"
    }

    /// 30 → "30m", 60 → "1h", 90 → "1h30m".
    public static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    private static let guess = try! NSRegularExpression(pattern: #"\[\s*(\d+(?:\.\d+)?)\s*(m|min|mins|h|hr|hrs)\s*\]"#,
                                                        options: [.caseInsensitive])
}

// MARK: - Checklists in notes

/// One "- [ ] step" line in a to-do's notes.
public struct ChecklistItem: Equatable, Sendable {
    /// The line number in the notes (from 0).
    public var line: Int
    public var done: Bool
    public var text: String
}

/// Checklists written as Markdown in the notes: "- [ ] reply to the feedback", "- [x] send it".
/// This is how a to-do gets steps, since other apps can't make subtasks in Reminders.
public enum Checklist {
    public static func items(in notes: String) -> [ChecklistItem] {
        lines(notes).enumerated().compactMap { index, line in
            let ns = line as NSString
            guard let m = item.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let mark = ns.substring(with: m.range(at: 1))
            return ChecklistItem(line: index, done: mark != " ", text: ns.substring(with: m.range(at: 2)))
        }
    }

    public static func progress(in notes: String) -> (done: Int, total: Int) {
        let all = items(in: notes)
        return (all.filter(\.done).count, all.count)
    }

    /// The notes with that line's box ticked or unticked.
    public static func toggling(line index: Int, in notes: String) -> String {
        var all = lines(notes)
        guard all.indices.contains(index) else { return notes }
        let line = all[index] as NSString
        guard let m = item.firstMatch(in: all[index], range: NSRange(location: 0, length: line.length)) else { return notes }
        let mark = line.substring(with: m.range(at: 1))
        all[index] = line.replacingCharacters(in: m.range(at: 1), with: mark == " " ? "x" : " ")
        return all.joined(separator: "\n")
    }

    /// The lines that aren't checklist items (the rest of the notes).
    public static func otherLines(in notes: String) -> [String] {
        let steps = Set(items(in: notes).map(\.line))
        return lines(notes).enumerated()
            .filter { !steps.contains($0.offset) && !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.element)
    }

    /// Typing helpers for the notes box: "[] " at the start of a line becomes "- [ ] ", and return
    /// on a checklist line starts the next one (return on an empty one ends the list).
    /// Returns the new text, or nil when nothing needs changing.
    public static func autoFormat(old: String, new: String) -> String? {
        // "[] " or "[ ] " typed at the start of a line.
        let range = NSRange(location: 0, length: (new as NSString).length)
        if shortcut.firstMatch(in: new, range: range) != nil {
            return shortcut.stringByReplacingMatches(in: new, range: range, withTemplate: "$1- [ ] ")
        }
        // A single return typed.
        let a = Array(old), b = Array(new)
        guard b.count == a.count + 1 else { return nil }
        let at = zip(a, b).prefix { $0 == $1 }.count
        guard at < b.count, b[at] == "\n" else { return nil }
        let before = String(a[..<at])
        let lineStart = before.lastIndex(of: "\n").map { before.index(after: $0) } ?? before.startIndex
        let line = String(before[lineStart...])
        let ns = line as NSString
        guard let m = continuing.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let marker = ns.substring(with: m.range(at: 2))
        let content = ns.substring(with: m.range(at: 3))
        let after = String(a[at...])
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Return on an empty item: end the list (drop the empty marker, no new line).
            return String(before[..<lineStart]) + indent + after
        }
        let next = marker.hasPrefix("- [") || marker.hasPrefix("* [") ? "- [ ] " : marker
        return before + "\n" + indent + next + after
    }

    /// A list line ("- item", "* item", "- [ ] step"), which Tab indents as a whole.
    public static func isListLine(_ line: String) -> Bool {
        listLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func lines(_ notes: String) -> [String] {
        notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static let item = try! NSRegularExpression(pattern: #"^\s*[-*] \[([ xX])\] ?(.*)$"#)
    private static let shortcut = try! NSRegularExpression(pattern: #"(?m)^([ \t]*)\[ ?\] "#)
    private static let listLine = try! NSRegularExpression(pattern: #"^[ \t]*[-*] "#)
    private static let continuing = try! NSRegularExpression(pattern: #"^([ \t]*)([-*] \[[ xX]\] |[-*] )(.*)$"#)
}

// MARK: - Links in notes

/// Links in notes, ready to show as Markdown: "[google](www.google.com)" opens https://www.google.com
/// and shows just "google"; a bare Backlog link shows as its ticket ("CONTRACT-9508").
public enum NoteLinks {
    /// One line of notes as inline Markdown with working links.
    public static func markdown(_ line: String) -> String {
        var s = line
        // A bare link (not already inside a Markdown link) gets a short name.
        let bareRange = NSRange(location: 0, length: (s as NSString).length)
        for m in bare.matches(in: s, range: bareRange).reversed() {
            let ns = s as NSString
            let url = ns.substring(with: m.range)
            s = ns.replacingCharacters(in: m.range, with: "[\(shortName(url))](\(url))")
        }
        // "[name](www.site.com)": add https:// so it opens.
        let range = NSRange(location: 0, length: (s as NSString).length)
        return schemeless.stringByReplacingMatches(in: s, range: range, withTemplate: "[$1](https://$2)")
    }

    /// The first link in some text: a Markdown link's target, a bare http(s) link, or www.….
    public static func first(in text: String) -> URL? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = target.firstMatch(in: text, range: range) {
            let raw = ns.substring(with: m.range(at: 1))
            return URL(string: raw.contains("://") ? raw : "https://" + raw)
        }
        if let m = anyLink.firstMatch(in: text, range: range) {
            let raw = ns.substring(with: m.range)
            return URL(string: raw.contains("://") ? raw : "https://" + raw)
        }
        return nil
    }

    /// "https://cios.backlog.com/view/CONTRACT-9508#comment-1" → "CONTRACT-9508"; else the site name.
    public static func shortName(_ url: String) -> String {
        guard let u = URL(string: url) else { return url }
        let last = u.lastPathComponent
        if !last.isEmpty && last != "/" { return last }
        return u.host ?? url
    }

    private static func make(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let bare = make(#"(?<!\]\()(?<![\w/(])https?://[^\s)\]]+"#)
    private static let schemeless = make(#"\[([^\]]+)\]\((?![a-z][a-z0-9+.-]*:)([^)\s]+)\)"#)
    private static let target = make(#"\[[^\]]+\]\(([^)\s]+)\)"#)
    private static let anyLink = make(#"https?://[^\s)\]]+|(?<![\w/@.])www\.[^\s)\]]+"#)
}
