import Foundation

/// How an event or to-do repeats: "every mon wed fri", "every weekend", "every 2 weeks",
/// "every month on the 25th", with an optional end ("until dec 2029").
public struct RepeatRule: Equatable, Sendable {
    public enum Frequency: Sendable { case daily, weekly, monthly, yearly }

    public var frequency: Frequency
    /// Every how many days, weeks, months or years (2 for "every other week").
    public var interval: Int = 1
    /// For weekly repeats: the days, as `Calendar` weekday numbers (1 is Sunday). Empty means
    /// the weekday of the first one.
    public var weekdays: [Int] = []
    /// For monthly repeats: the day of the month ("on the 25th"). Nil means the first one's day.
    public var monthDay: Int?
    /// The last day it can happen on (inclusive). Nil means it keeps going.
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = [], monthDay: Int? = nil, until: Date? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.monthDay = monthDay
        self.until = until
    }

    /// "Every Mon, Wed, Fri", "Every weekend", "Every other week", "Every month on the 25th".
    public func summary(calendar: Calendar = .current) -> String {
        let names = calendar.shortWeekdaySymbols
        switch frequency {
        case .daily:
            return interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            let set = Set(weekdays)
            let every = interval == 1 ? "Every" : (interval == 2 ? "Every other" : "Every \(interval)th")
            if set == [2, 3, 4, 5, 6] { return interval == 1 ? "Every weekday" : "\(every) week, weekdays" }
            if set == [1, 7] { return interval == 1 ? "Every weekend" : "\(every) weekend" }
            if weekdays.isEmpty { return interval == 1 ? "Every week" : (interval == 2 ? "Every other week" : "Every \(interval) weeks") }
            // Monday first, the way a week reads.
            let ordered = weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
            let days = ordered.map { names[$0 - 1] }.joined(separator: ", ")
            return interval == 1 ? "Every \(days)" : "\(every) week on \(days)"
        case .monthly:
            let base = interval == 1 ? "Every month" : (interval == 2 ? "Every other month" : "Every \(interval) months")
            return monthDay.map { "\(base) on the \(Self.ordinal($0))" } ?? base
        case .yearly:
            return interval == 1 ? "Every year" : "Every \(interval) years"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// Finds the repeat words in a line and takes them out, so the rest reads as usual.
enum RepeatReader {
    private static func make(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let weekday = #"(?:mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)s?"#
    /// every day, every weekday, every weekend, every week, every other week, every 2 weeks,
    /// every month, every year, every mon wed fri, every tuesday and thursday
    private static let every = make(#"(?<![\w])(?:every|each)\s+(?:(other)\s+|(\d+)\s+)?(days?|weekdays?|week\s*ends?|weeks?|months?|years?|"# + weekday + #"(?:\s*(?:,|and|&|/|\+)?\s*"# + weekday + #")*)(?![\w])"#)
    /// daily, weekly, monthly, yearly, weekdays, weekends (on their own)
    private static let word = make(#"(?<![\w])(?:on\s+)?(daily|weekly|monthly|yearly|annually|weekdays|week\s*ends)(?![\w])"#)
    /// "on the 25th" (with a monthly repeat)
    private static let onThe = make(#"(?<![\w])on\s+the\s+(\d{1,2})(?:st|nd|rd|th)?(?![\w])"#)
    /// "until dec 2029", "till 2029-12-31", "through dec 31 2029"
    private static let until = make(#"(?<![\w])(?:until|till|thru|through|ending)\s+"#)
    private static let monthOnly = make(#"^\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*,?\s*(\d{4})\s*$"#)
    private static let yearOnly = make(#"^\s*(\d{4})\s*$"#)
    private static let dayName = make(weekday)

    /// The repeat in `text` (if any), and the text with its words blanked out.
    static func extract(_ text: String, calendar: Calendar) -> (rule: RepeatRule, text: String)? {
        let ns = NSMutableString(string: text)
        func blank(_ r: NSRange) { ns.replaceCharacters(in: r, with: String(repeating: " ", count: r.length)) }
        func all() -> NSRange { NSRange(location: 0, length: ns.length) }

        var rule: RepeatRule?
        if let m = every.firstMatch(in: ns as String, range: all()) {
            let interval = m.range(at: 1).location != NSNotFound ? 2
                : (m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 1 : 1)
            // "week end" is the weekend.
            let unit = ns.substring(with: m.range(at: 3)).lowercased().replacingOccurrences(of: "week end", with: "weekend")
            rule = Self.rule(for: unit, interval: max(1, interval))
            if rule != nil { blank(m.range) }
        }
        if rule == nil, let m = word.firstMatch(in: ns as String, range: all()) {
            let w = ns.substring(with: m.range(at: 1)).lowercased().replacingOccurrences(of: " ", with: "")
            switch w {
            case "daily": rule = RepeatRule(frequency: .daily)
            case "weekly": rule = RepeatRule(frequency: .weekly)
            case "monthly": rule = RepeatRule(frequency: .monthly)
            case "weekdays": rule = RepeatRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
            case "weekends": rule = RepeatRule(frequency: .weekly, weekdays: [1, 7])
            default: rule = RepeatRule(frequency: .yearly)
            }
            blank(m.range)
        }
        guard var found = rule else { return nil }

        if found.frequency == .monthly, let m = onThe.firstMatch(in: ns as String, range: all()),
           let n = Int(ns.substring(with: m.range(at: 1))), (1...31).contains(n) {
            found.monthDay = n
            blank(m.range)
        }
        if let m = until.firstMatch(in: ns as String, range: all()) {
            let restStart = NSMaxRange(m.range)
            let rest = ns.substring(from: restStart)
            if let (length, date) = untilDate(in: rest, calendar: calendar) {
                found.until = date
                blank(NSRange(location: m.range.location, length: m.range.length + length))
            }
        }
        return (found, ns as String)
    }

    private static func rule(for unit: String, interval: Int) -> RepeatRule? {
        if unit.hasPrefix("weekday") { return RepeatRule(frequency: .weekly, interval: interval, weekdays: [2, 3, 4, 5, 6]) }
        if unit.hasPrefix("weekend") { return RepeatRule(frequency: .weekly, interval: interval, weekdays: [1, 7]) }
        if unit.hasPrefix("day") { return RepeatRule(frequency: .daily, interval: interval) }
        if unit.hasPrefix("week") { return RepeatRule(frequency: .weekly, interval: interval) }
        if unit.hasPrefix("month") { return RepeatRule(frequency: .monthly, interval: interval) }
        if unit.hasPrefix("year") { return RepeatRule(frequency: .yearly, interval: interval) }
        // A list of days: "mon wed fri", "tuesday and thursday".
        let ns = unit as NSString
        let order = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var days: [Int] = []
        for m in dayName.matches(in: unit, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range).lowercased().prefix(3)
            if let i = order.firstIndex(of: String(name)), !days.contains(i + 1) { days.append(i + 1) }
        }
        return days.isEmpty ? nil : RepeatRule(frequency: .weekly, interval: interval, weekdays: days)
    }

    /// The date right after "until": "dec 2029" (the end of that month), "2029" (the end of that
    /// year), or any date the system's date reader finds there ("dec 31 2029", "2029-12-31").
    /// Returns how many characters it used, and the last day.
    private static func untilDate(in rest: String, calendar: Calendar) -> (Int, Date)? {
        let ns = rest as NSString
        // Just a month and a year, or just a year: up to the end of it.
        let words = rest.split(separator: " ", omittingEmptySubsequences: true)
        for count in [2, 1] where words.count >= count {
            let piece = words.prefix(count).joined(separator: " ")
            let whole = NSRange(location: 0, length: (piece as NSString).length)
            if count == 2, let m = monthOnly.firstMatch(in: piece, range: whole),
               let year = Int((piece as NSString).substring(with: m.range(at: 2))) {
                let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
                    .firstIndex(of: (piece as NSString).substring(with: m.range(at: 1)).lowercased())! + 1
                if let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                   let last = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: first) {
                    return (usedLength(of: count, in: rest), last)
                }
            }
            if count == 1, let m = yearOnly.firstMatch(in: piece, range: whole),
               let year = Int((piece as NSString).substring(with: m.range(at: 1))),
               let last = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) {
                return (usedLength(of: count, in: rest), last)
            }
        }
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)),
              m.range.location <= 1, let date = m.date else { return nil }
        return (NSMaxRange(m.range), calendar.startOfDay(for: date))
        #else
        return nil
        #endif
    }

    /// How many characters the first `count` words (and the spaces before them) take up.
    private static func usedLength(of count: Int, in text: String) -> Int {
        var seen = 0, inWord = false, end = 0
        for (i, ch) in text.utf16.enumerated() {
            let space = ch == 32
            if !space && !inWord { seen += 1 }
            inWord = !space
            if seen == count && !space { end = i + 1 }
            if seen > count { break }
        }
        return end
    }
}
