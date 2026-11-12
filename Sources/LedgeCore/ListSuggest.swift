import Foundation

// MARK: - List suggestions

/// Suggests your Reminders lists while you type a "#list" tag in a to-do line.
/// Typing "#wo" at the end of the line offers "Work"; taking it turns the line's end into "#Work ".
public enum ListSuggest {
    /// The "#word" being typed at the end of the line, without the "#" ("" right after a "#").
    /// Nil when the line doesn't end in one, for example after the space that follows a tag.
    public static func activeTag(in text: String) -> String? {
        let ns = text as NSString
        guard let m = activePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// The lists that match a partial tag, best first: same name, then names that start with it,
    /// then names that contain it. "" matches every list. Case doesn't matter, and "-" or "_" in
    /// the tag count as spaces (a tag can't hold a space).
    public static func matches(_ tag: String, in titles: [String], limit: Int = 4) -> [String] {
        let wanted = normalized(tag)
        guard !wanted.isEmpty else { return Array(titles.prefix(limit)) }
        let names = titles.map { ($0, normalized($0)) }
        let exact = names.filter { $0.1 == wanted }
        let starts = names.filter { $0.1 != wanted && $0.1.hasPrefix(wanted) }
        let contains = names.filter { !$0.1.hasPrefix(wanted) && $0.1.contains(wanted) }
        return Array((exact + starts + contains).map(\.0).prefix(limit))
    }

    /// The line with the "#word" at its end replaced by the list's tag and a space, ready to keep typing.
    /// The line comes back unchanged when it doesn't end in a "#word".
    public static func complete(_ text: String, with title: String) -> String {
        let ns = text as NSString
        guard let m = activePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return text
        }
        return ns.replacingCharacters(in: m.range, with: "#" + tag(for: title) + " ")
    }

    /// A list name written as a tag: spaces become "-" ("Side project" → "Side-project").
    public static func tag(for title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Lowercased, with "-" and "_" read as spaces.
    private static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// A "#" (not stuck to a word or another "#") and what follows it, up to the end of the line.
    /// Same rule as the tag quick add reads, but the word may still be empty.
    private static let activePattern = try! NSRegularExpression(pattern: #"(?<![\w#])#([^\s#]*)$"#)
}
