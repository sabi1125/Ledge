import Foundation

/// Converting between Ledge's notes (a title plus plain text with Markdown-style lists) and
/// Apple Notes. Notes takes HTML when writing and gives back plain text when reading; its first
/// line is the note's title.
public enum NoteFormat {
    /// The HTML to save: the title as a heading, then one line per paragraph. Leading spaces
    /// (list indents) are kept as non-breaking spaces, since HTML would drop them.
    public static func html(title: String, body: String) -> String {
        let heading = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title
        var out = "<div><h1>\(escape(heading))</h1></div>"
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let lead = line.prefix { $0 == " " }.count
            let text = String(repeating: "&nbsp;", count: lead) + escape(String(line.dropFirst(lead)))
            out += text.isEmpty ? "<div><br></div>" : "<div>\(text)</div>"
        }
        return out
    }

    /// Splits a note's plain text into its title (first line) and body (the rest).
    public static func split(plaintext: String) -> (title: String, body: String) {
        let clean = plaintext.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return (title, lines.joined(separator: "\n"))
    }

    /// One line of the note list from the AppleScript ("id<TAB>title<TAB>2026-11-11T17:00:00").
    public static func listItem(_ line: String) -> (id: String, title: String, modified: Date?)? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], isoLocal.date(from: parts[2]))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let isoLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}
