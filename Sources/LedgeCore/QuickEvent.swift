import Foundation

/// What quick add understood from a line like "Dentist tomorrow 3pm" or "Gym fri 7-8pm".
public struct QuickEventDraft: Equatable, Sendable {
    /// The text with the date and time words taken out. Empty if only a date was typed.
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// False when no day or time was found. The draft then falls back to an all-day event today.
    public var foundDate: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool, foundDate: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.foundDate = foundDate
    }
}

/// Reads a day and a time out of one line of text.
///
/// Understands: today, tonight, tomorrow (tmrw), weekdays (mon, friday, next fri), times (3pm,
/// 3:30pm, 15:00, at 7, noon, midnight), ranges (7-8pm, 11-1pm, 9:30 to 10:15am), lengths
/// (for 90 min, for 2h), times from now (in 3 hours, 30 min from now), next week and, on macOS, written dates such as "Nov 20", "12/3",
/// "2026-12-20" or "in 3 days", and ranges from one date to another ("Jan 20 to Jan 25").
public enum QuickEventParser {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current,
                             defaultDuration: TimeInterval = 3600) -> QuickEventDraft {
        let ns = text as NSString
        var used: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool { !used.contains { NSIntersectionRange($0, r).length > 0 } }

        // A time from now: "in 3 hours", "in 30 min", "3 hours from now". The whole line is about
        // that moment, so it wins over any other day or time words.
        if let found = relativeTime(in: text, ns) {
            var length = defaultDuration
            var pieces = [found.range]
            if let d = firstMatch(Pattern.duration, in: text, ns, { NSIntersectionRange($0, found.range).length == 0 }, read: readDuration) {
                length = d.1
                pieces.append(d.0.range)
            }
            // To the minute (seconds would show as an odd time).
            let raw = now.addingTimeInterval(found.seconds)
            let start = Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
            return QuickEventDraft(title: cleanTitle(ns, removing: pieces), start: start, end: start.addingTimeInterval(length),
                                   isAllDay: false, foundDate: true)
        }

        // From one date to another: "Jan 20 2027 to Jan 25 2027", "Dec 20-23", "12/20 - 12/23",
        // "Dec 20 9am to Dec 21 5pm". Read as a whole first, so its two halves aren't taken apart.
        if let found = dateRange(in: text, calendar: calendar) {
            let title = cleanTitle(ns, removing: [found.range])
            return QuickEventDraft(title: title, start: found.start, end: found.end, isAllDay: found.isAllDay, foundDate: true)
        }

        // Times of day, as minutes after midnight.
        var startMinutes: Int?
        var endMinutes: Int?
        if let found = firstMatch(Pattern.range, in: text, ns, isFree, read: readRange) {
            startMinutes = found.1.0
            endMinutes = found.1.1
            used.append(found.0.range)
        } else if let found = firstMatch(Pattern.meridiemTime, in: text, ns, isFree, read: readMeridiemTime)
                    ?? firstMatch(Pattern.clockTime, in: text, ns, isFree, read: readClockTime)
                    ?? firstMatch(Pattern.namedTime, in: text, ns, isFree, read: readNamedTime)
                    ?? firstMatch(Pattern.atHour, in: text, ns, isFree, read: readAtHour) {
            startMinutes = found.1
            used.append(found.0.range)
        }

        var duration: TimeInterval?
        if let found = firstMatch(Pattern.duration, in: text, ns, isFree, read: readDuration) {
            duration = found.1
            used.append(found.0.range)
        }

        // The day.
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var isTonight = false
        var weekdayMeansToday = false
        if let found = firstMatch(Pattern.day, in: text, ns, isFree, read: { (m: NSTextCheckingResult, ns: NSString) -> (String, String)? in
            (group(m, 1, ns) ?? "", group(m, 2, ns) ?? "")
        }) {
            used.append(found.0.range)
            let (prefix, name) = found.1
            switch name {
            case "today": day = today
            case "tonight": day = today; isTonight = true
            case "tomorrow", "tmrw", "tmr": day = calendar.date(byAdding: .day, value: 1, to: today)
            default:
                if let weekday = weekdayNumber(name) {
                    let current = calendar.component(.weekday, from: today)
                    var ahead = (weekday - current + 7) % 7
                    if ahead == 0 && prefix.hasPrefix("next") { ahead = 7 }
                    weekdayMeansToday = ahead == 0
                    day = calendar.date(byAdding: .day, value: ahead, to: today)
                }
            }
        }
        // "in 3 days", "in 2 weeks", "in a month": counted from now.
        if day == nil, let found = firstMatch(Pattern.inDays, in: text, ns, isFree, read: { m, ns -> DateComponents? in
            guard let amount = group(m, 1, ns), let unit = group(m, 2, ns) else { return nil }
            let n = Int(amount) ?? ((amount == "a" || amount == "an") ? 1 : 0)
            guard n > 0 else { return nil }
            var c = DateComponents()
            if unit.hasPrefix("w") { c.day = 7 * n } else if unit.hasPrefix("m") { c.month = n } else { c.day = n }
            return c
        }) {
            used.append(found.0.range)
            day = calendar.date(byAdding: found.1, to: today)
        }
        // "next week": its Monday.
        if day == nil, let found = firstMatch(Pattern.nextWeek, in: text, ns, isFree, read: { _, _ in true }) {
            used.append(found.0.range)
            let current = calendar.component(.weekday, from: today) // 1 is Sunday
            let toMonday = (2 - current + 7) % 7
            day = calendar.date(byAdding: .day, value: toMonday == 0 ? 7 : toMonday, to: today)
        }
        if day == nil, let found = writtenDate(in: text, used: used) {
            used.append(found.0)
            day = calendar.startOfDay(for: found.1)
        }

        // Put it together.
        let title = cleanTitle(ns, removing: used)
        let oneDay: (Date) -> Date = { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0.addingTimeInterval(86_400) }
        if let s = startMinutes {
            let base = day ?? today
            var start = calendar.date(byAdding: .minute, value: s, to: base) ?? base
            // "Call at 9am" when it's already past 9: tomorrow. "Gym wed 7am" on a Wednesday afternoon: next week.
            if day == nil && start <= now { start = oneDay(start) }
            if weekdayMeansToday && start <= now { start = calendar.date(byAdding: .day, value: 7, to: start) ?? start }
            var end: Date
            if let e = endMinutes {
                var length = e - s
                if length <= 0 { length += 24 * 60 } // runs past midnight
                end = start.addingTimeInterval(TimeInterval(length * 60))
            } else {
                end = start.addingTimeInterval(duration ?? defaultDuration)
            }
            if end <= start { end = start.addingTimeInterval(defaultDuration) }
            return QuickEventDraft(title: title, start: start, end: end, isAllDay: false, foundDate: true)
        }
        if let day {
            if isTonight {
                let start = calendar.date(byAdding: .hour, value: 20, to: day) ?? day
                return QuickEventDraft(title: title, start: start, end: start.addingTimeInterval(duration ?? defaultDuration),
                                       isAllDay: false, foundDate: true)
            }
            return QuickEventDraft(title: title, start: day, end: oneDay(day), isAllDay: true, foundDate: true)
        }
        return QuickEventDraft(title: title, start: today, end: oneDay(today), isAllDay: true, foundDate: false)
    }

    // MARK: Patterns

    private enum Pattern {
        static func make(_ p: String) -> NSRegularExpression {
            // The patterns are fixed, so a failure here is a programming mistake.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        /// 7-8pm, 11-1pm, 9:30 to 10:15am, from 14:00-15:30
        static let range = make(#"(?<![\w:])(?:from\s+)?(\d{1,2})(?::([0-5]\d))?\s*(am|pm|a|p)?\s*(?:-|–|—|to|until|till)\s*(\d{1,2})(?::([0-5]\d))?\s*(am|pm|a|p)?(?![\w:])"#)
        /// 3pm, at 3:30 pm
        static let meridiemTime = make(#"(?<![\w:])(?:at\s+|@\s*)?(\d{1,2})(?::([0-5]\d))?\s*(am|pm)(?![\w])"#)
        /// 15:00, at 9:30
        static let clockTime = make(#"(?<![\w:])(?:at\s+|@\s*)?(\d{1,2}):([0-5]\d)(?![\w:])"#)
        /// noon, at midnight
        static let namedTime = make(#"(?<![\w])(?:at\s+)?(noon|midday|midnight)(?![\w])"#)
        /// at 7
        static let atHour = make(#"(?<![\w])(?:at|@)\s*(\d{1,2})(?![\w:])"#)
        /// for 90 min, for 2h, for 1.5 hours
        static let duration = make(#"(?<![\w])for\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)(?![\w])"#)
        /// today, tonight, tomorrow, (next) friday, on mon…
        static let day = make(#"(?<![\w])(?:on\s+|due\s+|by\s+)?(next\s+|this\s+)?(today|tonight|tomorrow|tmrw|tmr|monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun)(?![\w])"#)
        /// Written dates the system date reader may find: month names, 12/3, 2026-12-20, in 3 days.
        static let writtenDate = make(#"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*\d|\d\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\d{1,2}/\d{1,2}|\d{4}-\d{1,2}-\d{1,2}"#)
        /// in 3 days, in 2 weeks, in a month
        static let inDays = make(#"(?<![\w])in\s+(\d+|an?)\s+(days?|weeks?|months?)(?![\w])"#)
        /// in 3 hours, in 30 min, after 20 minutes, in an hour, in half an hour, in 1.5h
        static let relative = make(#"(?<![\w])(?:in|after)\s+(\d+(?:\.\d+)?|an?|half\s+an?)\s*(hours?|hrs?|h|minutes?|mins?|m)(?![\w])"#)
        /// 3 hours from now, 3hours from now, 20 min from now
        static let fromNow = make(#"(?<![\w])(\d+(?:\.\d+)?|an?|half\s+an?)\s*(hours?|hrs?|h|minutes?|mins?|m)\s+from\s+now(?![\w])"#)
        /// "remind me to", "don't forget to" at the start: not part of the title.
        static let reminderPrefix = make(#"^\s*(?:please\s+)?(?:remind\s+me(?:\s+to)?|don'?t\s+forget(?:\s+to)?|remember\s+to)\s+"#)
        /// next week
        static let nextWeek = make(#"(?<![\w])(?:on\s+|due\s+|by\s+)?next\s+week(?![\w])"#)
        /// A time of day inside a date range ("Dec 20 9am to Dec 21 5pm").
        static let anyTime = make(#"\d\s*(am|pm|a\.m\.|p\.m\.)(?![\w])|\d:[0-5]\d|(?<![\w])(noon|midnight)(?![\w])"#)
        /// Quotes left empty once the date inside them is taken out: review "due friday".
        static let emptyQuotes = make(#"["“”'‘’「」『』]\s*["“”'‘’「」『』]"#)
        static let danglingWord = make(#"^(?:at|on|from|by|for|@|-|–|—|,)\s+|\s+(?:at|on|from|by|for|@|-|–|—|,)$"#)
    }

    // MARK: Reading matches

    private static func firstMatch<T>(_ pattern: NSRegularExpression, in text: String, _ ns: NSString,
                                      _ isFree: (NSRange) -> Bool,
                                      read: (NSTextCheckingResult, NSString) -> T?) -> (NSTextCheckingResult, T)? {
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) where isFree(m.range) {
            if let value = read(m, ns) { return (m, value) }
        }
        return nil
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
    }

    /// 12-hour clock to minutes after midnight.
    private static func minutes(hour: Int, minute: Int, meridiem: String) -> Int? {
        guard (1...12).contains(hour) else { return nil }
        let pm = meridiem.hasPrefix("p")
        return ((hour % 12) + (pm ? 12 : 0)) * 60 + minute
    }

    private static func readRange(_ m: NSTextCheckingResult, _ ns: NSString) -> (Int, Int)? {
        guard let h1 = group(m, 1, ns).flatMap({ Int($0) }), let h2 = group(m, 4, ns).flatMap({ Int($0) }) else { return nil }
        let m1 = group(m, 2, ns).flatMap({ Int($0) }), m2 = group(m, 5, ns).flatMap({ Int($0) })
        let mer1 = group(m, 3, ns), mer2 = group(m, 6, ns)
        // "2-3 chairs" is not a time: it needs am/pm or a colon somewhere.
        guard mer1 != nil || mer2 != nil || m1 != nil || m2 != nil else { return nil }
        let end: Int
        if let mer = mer2 ?? mer1 {
            guard let e = minutes(hour: h2, minute: m2 ?? 0, meridiem: mer) else { return nil }
            end = e
        } else {
            guard h2 < 24 else { return nil }
            end = h2 * 60 + (m2 ?? 0)
        }
        let start: Int
        if let mer = mer1 {
            guard let s = minutes(hour: h1, minute: m1 ?? 0, meridiem: mer) else { return nil }
            start = s
        } else if let mer = mer2 {
            // "11-1pm": the start takes the end's am/pm unless that would put it after the end.
            guard var s = minutes(hour: h1, minute: m1 ?? 0, meridiem: mer) else { return nil }
            if s > end { s -= 12 * 60 }
            start = s
        } else {
            guard h1 < 24 else { return nil }
            start = h1 * 60 + (m1 ?? 0)
        }
        return (start, end)
    }

    private static func readMeridiemTime(_ m: NSTextCheckingResult, _ ns: NSString) -> Int? {
        guard let h = group(m, 1, ns).flatMap({ Int($0) }), let mer = group(m, 3, ns) else { return nil }
        return minutes(hour: h, minute: group(m, 2, ns).flatMap({ Int($0) }) ?? 0, meridiem: mer)
    }

    private static func readClockTime(_ m: NSTextCheckingResult, _ ns: NSString) -> Int? {
        guard let raw = group(m, 1, ns), let h = Int(raw), h < 24, let minute = group(m, 2, ns).flatMap({ Int($0) }) else { return nil }
        // "9:30" is morning and "15:00" is afternoon, but a bare "3:30" means the afternoon.
        let hour = (1...7).contains(h) && !raw.hasPrefix("0") ? h + 12 : h
        return hour * 60 + minute
    }

    private static func readNamedTime(_ m: NSTextCheckingResult, _ ns: NSString) -> Int? {
        group(m, 1, ns) == "midnight" ? 0 : 12 * 60
    }

    private static func readAtHour(_ m: NSTextCheckingResult, _ ns: NSString) -> Int? {
        guard let h = group(m, 1, ns).flatMap({ Int($0) }), h < 24 else { return nil }
        // "at 7" is most likely the evening; "at 9" the morning.
        let hour = (1...7).contains(h) ? h + 12 : h
        return hour * 60
    }

    private static func readDuration(_ m: NSTextCheckingResult, _ ns: NSString) -> TimeInterval? {
        guard let n = group(m, 1, ns).flatMap({ Double($0) }), n > 0, let unit = group(m, 2, ns) else { return nil }
        let seconds = unit.hasPrefix("h") ? n * 3600 : n * 60
        return seconds <= 7 * 86_400 ? seconds : nil
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        // Calendar's weekday numbers: 1 is Sunday.
        let order = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        return order.firstIndex(of: String(name.prefix(3))).map { $0 + 1 }
    }

    /// "Nov 20", "20 Nov", "12/3": read with the system's date reader, on macOS.
    private static func writtenDate(in text: String, used: [NSRange]) -> (NSRange, Date)? {
        #if canImport(Darwin)
        let masked = NSMutableString(string: text)
        for r in used.sorted(by: { $0.location > $1.location }) {
            masked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        let s = masked as String
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        for m in detector.matches(in: s, range: NSRange(location: 0, length: masked.length)) {
            guard let date = m.date else { continue }
            let piece = masked.substring(with: m.range)
            if Pattern.writtenDate.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) != nil {
                return (m.range, date)
            }
        }
        #endif
        return nil
    }

    /// "in 3 hours", "3 hours from now": how far ahead, in seconds (up to a week).
    private static func relativeTime(in text: String, _ ns: NSString) -> (range: NSRange, seconds: TimeInterval)? {
        let all = NSRange(location: 0, length: ns.length)
        for pattern in [Pattern.relative, Pattern.fromNow] {
            for m in pattern.matches(in: text, range: all) {
                guard let amount = group(m, 1, ns), let unit = group(m, 2, ns) else { continue }
                let n: Double
                if amount.hasPrefix("half") { n = 0.5 }
                else if amount == "a" || amount == "an" { n = 1 }
                else if let v = Double(amount) { n = v } else { continue }
                let seconds = unit.hasPrefix("h") ? n * 3600 : n * 60
                guard seconds > 0, seconds <= 7 * 86_400 else { continue }
                return (m.range, seconds)
            }
        }
        return nil
    }

    /// "Jan 20 2027 to Jan 25 2027", "Dec 20-23": the system's date reader returns the first date and
    /// how long the range lasts. Without times it's all day, both ends included.
    private static func dateRange(in text: String, calendar: Calendar) -> (range: NSRange, start: Date, end: Date, isAllDay: Bool)? {
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var date = m.date, m.duration > 0 else { continue }
            let piece = ns.substring(with: m.range)
            let whole = NSRange(location: 0, length: (piece as NSString).length)
            // Only real dates ("3pm to 5pm" on its own is a time range, read the usual way).
            guard Pattern.writtenDate.firstMatch(in: piece, range: whole) != nil else { continue }
            let end = date.addingTimeInterval(m.duration)
            // "Dec 20 to Dec 23 2027": the year written once belongs to both ends (the reader takes
            // the first date as this year, which would make it a range of more than a year).
            while end.timeIntervalSince(date) > 330 * 86_400, let later = calendar.date(byAdding: .year, value: 1, to: date) {
                date = later
            }
            if Pattern.anyTime.firstMatch(in: piece, range: whole) != nil {
                return (m.range, date, end, false)
            }
            let first = calendar.startOfDay(for: date)
            let last = calendar.startOfDay(for: end)
            guard let after = calendar.date(byAdding: .day, value: 1, to: last), after > first else { continue }
            return (m.range, first, after, true)
        }
        #endif
        return nil
    }

    /// Takes out the date and time words, and tidies the spaces and leftover joining words.
    private static func cleanTitle(_ ns: NSString, removing ranges: [NSRange]) -> String {
        let out = NSMutableString(string: ns)
        // Overlapping pieces (the system's date reader can match across a time already taken out)
        // are merged first: cutting them one by one would run past the end of the shortened text.
        var merged: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) where r.location != NSNotFound {
            let clipped = NSIntersectionRange(r, NSRange(location: 0, length: ns.length))
            guard clipped.length > 0 else { continue }
            if let last = merged.last, clipped.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, clipped)
            } else {
                merged.append(clipped)
            }
        }
        for r in merged.reversed() {
            out.replaceCharacters(in: r, with: " ")
        }
        var title = (out as String).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // "remind me to charge the laptop" is the to-do "charge the laptop".
        title = Pattern.reminderPrefix.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: (title as NSString).length), withTemplate: "")
        title = Pattern.emptyQuotes.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: (title as NSString).length), withTemplate: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while true {
            let range = NSRange(location: 0, length: (title as NSString).length)
            let next = Pattern.danglingWord.stringByReplacingMatches(in: title, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if next == title { break }
            title = next
        }
        if ["at", "on", "from", "by", "for", "@", "-", ","].contains(title.lowercased()) { title = "" }
        return title
    }
}
