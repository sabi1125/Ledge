import Foundation

/// The pages of the open island, in swipe order.
public enum IslandPage: String, CaseIterable, Sendable {
    case music, calendar, notes

    public var title: String {
        switch self {
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        }
    }

    public var symbol: String {
        switch self {
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        }
    }

    /// Pages available right now (Music only while something is loaded in a player).
    public static func available(hasMedia: Bool) -> [IslandPage] {
        hasMedia ? [.music, .calendar, .notes] : [.calendar, .notes]
    }

    /// The page one step away, or nil at either end (no wrap-around).
    public static func step(from current: IslandPage, forward: Bool, in pages: [IslandPage]) -> IslandPage? {
        guard let i = pages.firstIndex(of: current) else { return pages.first }
        let j = forward ? i + 1 : i - 1
        return pages.indices.contains(j) ? pages[j] : nil
    }
}

/// Finds a video-call link (Zoom, Google Meet, Teams, Webex, FaceTime) in event fields.
public enum MeetingLink {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://(?:[\w-]+\.)*(?:zoom\.us/(?:j|my|w)/[^\s<>"]+|meet\.google\.com/[a-z0-9-]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[\w-]+\.webex\.com/[^\s<>"]+|facetime\.apple\.com/join[^\s<>"]*)"#,
        options: [.caseInsensitive])

    public static func find(in texts: [String?]) -> URL? {
        for case let text? in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let match = pattern.firstMatch(in: text, range: range),
               let r = Range(match.range, in: text) {
                let trimmed = text[r].trimmingCharacters(in: CharacterSet(charactersIn: ").,;>"))
                if let url = URL(string: trimmed) { return url }
            }
        }
        return nil
    }
}
