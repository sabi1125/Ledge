import XCTest
@testable import LedgeCore

final class QuickEventTests: XCTestCase {
    // Wednesday 11 November 2026, 1:12 PM in Tokyo.
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    lazy var now = date(11, 13, 12)

    func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func parse(_ text: String) -> QuickEventDraft {
        QuickEventParser.parse(text, now: now, calendar: cal)
    }

    func testTomorrowAtATime() {
        let d = parse("Dentist tomorrow 3pm")
        XCTAssertEqual(d.title, "Dentist")
        XCTAssertEqual(d.start, date(12, 15))
        XCTAssertEqual(d.end, date(12, 16))
        XCTAssertFalse(d.isAllDay)
        XCTAssertTrue(d.foundDate)
    }

    func testWeekdayWithARange() {
        let d = parse("Gym fri 7-8pm")
        XCTAssertEqual(d.title, "Gym")
        XCTAssertEqual(d.start, date(13, 19))
        XCTAssertEqual(d.end, date(13, 20))
    }

    func testRangeWhereTheStartIsMorning() {
        let d = parse("Review 11-1pm thu")
        XCTAssertEqual(d.title, "Review")
        XCTAssertEqual(d.start, date(12, 11))
        XCTAssertEqual(d.end, date(12, 13))
    }

    func testRangeWithMinutes() {
        let d = parse("Sync tomorrow 9:30 to 10:15am")
        XCTAssertEqual(d.title, "Sync")
        XCTAssertEqual(d.start, date(12, 9, 30))
        XCTAssertEqual(d.end, date(12, 10, 15))
    }

    func testNoDateFallsBackToAllDayToday() {
        let d = parse("Call mom about the trip")
        XCTAssertEqual(d.title, "Call mom about the trip")
        XCTAssertFalse(d.foundDate)
        XCTAssertTrue(d.isAllDay)
        XCTAssertEqual(d.start, date(11))
        XCTAssertEqual(d.end, date(12))
    }

    func testNumbersThatAreNotTimes() {
        let d = parse("Bring 2-3 chairs")
        XCTAssertFalse(d.foundDate)
        XCTAssertEqual(d.title, "Bring 2-3 chairs")
    }

    func testDayWithoutATimeIsAllDay() {
        let d = parse("Flight to Osaka tomorrow")
        XCTAssertEqual(d.title, "Flight to Osaka")
        XCTAssertTrue(d.isAllDay)
        XCTAssertEqual(d.start, date(12))
        XCTAssertEqual(d.end, date(13))
    }

    func testTimeAlreadyPassedTodayMeansTomorrow() {
        let d = parse("Lunch with Tom at noon")
        XCTAssertEqual(d.title, "Lunch with Tom")
        XCTAssertEqual(d.start, date(12, 12))
    }

    func testLaterTodayStaysToday() {
        let d = parse("Gym at 7")
        XCTAssertEqual(d.title, "Gym")
        XCTAssertEqual(d.start, date(11, 19))
    }

    func testTodaysWeekday() {
        XCTAssertEqual(parse("Party wed 8pm").start, date(11, 20))
        XCTAssertEqual(parse("Yoga wed 9am").start, date(18, 9))
        XCTAssertEqual(parse("Yoga next wed 8pm").start, date(18, 20))
    }

    func testClockTimes() {
        XCTAssertEqual(parse("Standup tomorrow 9:30").start, date(12, 9, 30))
        XCTAssertEqual(parse("Call fri 15:00").start, date(13, 15))
        XCTAssertEqual(parse("Call fri at 3:30").start, date(13, 15, 30))
    }

    func testLength() {
        let d = parse("Deep work tomorrow 2pm for 90 min")
        XCTAssertEqual(d.title, "Deep work")
        XCTAssertEqual(d.start, date(12, 14))
        XCTAssertEqual(d.end, date(12, 15, 30))
    }

    func testTonight() {
        let d = parse("Drinks tonight")
        XCTAssertEqual(d.title, "Drinks")
        XCTAssertEqual(d.start, date(11, 20))
        XCTAssertFalse(d.isAllDay)
    }

    func testRangePastMidnight() {
        let d = parse("Party sat 10pm-1am")
        XCTAssertEqual(d.start, date(14, 22))
        XCTAssertEqual(d.end, date(15, 1))
    }

    func testOnlyADate() {
        let d = parse("tomorrow 3pm")
        XCTAssertEqual(d.title, "")
        XCTAssertEqual(d.start, date(12, 15))
    }

    func testDueAndByBeforeADay() {
        let d = parse("!must review \"due friday\"")
        XCTAssertEqual(d.title, "!must review")
        XCTAssertEqual(d.start, date(13))
        XCTAssertTrue(d.isAllDay)
        XCTAssertEqual(parse("Submit report by fri").title, "Submit report")
    }

    func testJoiningWordsAreTidied() {
        XCTAssertEqual(parse("Dinner on friday at 7pm").title, "Dinner")
        XCTAssertEqual(parse("Meet at the cafe tomorrow 3pm").title, "Meet at the cafe")
    }

    /// A date and a time on each side used to crash (overlapping pieces taken out of the title).
    func testTwoDatesWithTimesDoNotCrash() {
        let d = QuickEventParser.parse("Conf Dec 20 9am to Dec 21 5pm")
        XCTAssertEqual(d.title, "Conf")
        XCTAssertTrue(d.foundDate)
    }

    // MARK: From one date to another, and more ways to write a date

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDateRangeWithYears() {
        let d = QuickEventParser.parse("gunma trip jan 20 2027 to jan 25 2027")
        XCTAssertEqual(d.title, "gunma trip")
        XCTAssertTrue(d.isAllDay)
        XCTAssertEqual(d.start, day(2027, 1, 20))
        XCTAssertEqual(d.end, day(2027, 1, 26)) // all day through Jan 25
    }

    func testDateRangeShortForms() {
        for text in ["Trip Dec 20 to Dec 23 2027", "Trip from Dec 20 to Dec 23 2027", "Trip Dec 20-23 2027", "Trip 12/20/2027 - 12/23/2027"] {
            let d = QuickEventParser.parse(text)
            XCTAssertEqual(d.title, "Trip", text)
            XCTAssertTrue(d.isAllDay, text)
            XCTAssertEqual(d.start, day(2027, 12, 20), text)
            XCTAssertEqual(d.end, day(2027, 12, 24), text)
        }
    }

    func testDateRangeWithTimes() {
        let d = QuickEventParser.parse("Conf Dec 20 2027 9am to Dec 21 2027 5pm")
        XCTAssertEqual(d.title, "Conf")
        XCTAssertFalse(d.isAllDay)
        XCTAssertEqual(d.start, day(2027, 12, 20, 9))
        XCTAssertEqual(d.end, day(2027, 12, 21, 17))
    }

    func testTimeRangeOnOneDayIsUnchanged() {
        let d = QuickEventParser.parse("Meeting Dec 20 2027 3-5pm")
        XCTAssertEqual(d.title, "Meeting")
        XCTAssertEqual(d.start, day(2027, 12, 20, 15))
        XCTAssertEqual(d.end, day(2027, 12, 20, 17))
    }

    func testISODate() {
        let d = QuickEventParser.parse("Dentist 2027-12-20 3pm")
        XCTAssertEqual(d.title, "Dentist")
        XCTAssertEqual(d.start, day(2027, 12, 20, 15))
    }

    func testInSomeDays() {
        let now = day(2026, 11, 11, 10)
        let d = QuickEventParser.parse("Call mom in 3 days", now: now)
        XCTAssertEqual(d.title, "Call mom")
        XCTAssertTrue(d.isAllDay)
        XCTAssertEqual(d.start, day(2026, 11, 14))
    }

    func testNextWeekIsItsMonday() {
        let wednesday = day(2026, 11, 11, 10)
        let d = QuickEventParser.parse("Plan the trip next week", now: wednesday)
        XCTAssertEqual(d.title, "Plan the trip")
        XCTAssertEqual(d.start, day(2026, 11, 16))
    }

    // MARK: Times from now

    func testInSomeHours() {
        let now = day(2026, 11, 11, 23, 23)
        let d = QuickEventParser.parse("charge the laptop in 3 hours", now: now)
        XCTAssertEqual(d.title, "charge the laptop")
        XCTAssertFalse(d.isAllDay)
        XCTAssertEqual(d.start, day(2026, 11, 12, 2, 23))
    }

    func testFromNowWithoutASpace() {
        let now = day(2026, 11, 11, 23, 23)
        let d = QuickEventParser.parse("remind me to charge the laptop 3hours from now", now: now)
        XCTAssertEqual(d.title, "charge the laptop")
        XCTAssertEqual(d.start, day(2026, 11, 12, 2, 23))
    }

    func testOtherWaysToSayIt() {
        let now = day(2026, 11, 11, 10, 0)
        let cases: [(String, Date)] = [
            ("check the oven in 30 min", day(2026, 11, 11, 10, 30)),
            ("check the oven in 30m", day(2026, 11, 11, 10, 30)),
            ("stretch after 20 minutes", day(2026, 11, 11, 10, 20)),
            ("call back in an hour", day(2026, 11, 11, 11, 0)),
            ("tea in half an hour", day(2026, 11, 11, 10, 30)),
            ("leave in 1.5 hours", day(2026, 11, 11, 11, 30)),
            ("laundry 45 min from now", day(2026, 11, 11, 10, 45)),
        ]
        for (text, start) in cases {
            let d = QuickEventParser.parse(text, now: now)
            XCTAssertEqual(d.start, start, text)
            XCTAssertTrue(d.foundDate, text)
            XCTAssertFalse(d.title.lowercased().contains(" in "), text)
        }
    }

    func testSecondsAreDropped() {
        let now = day(2026, 11, 11, 10, 0).addingTimeInterval(42)
        XCTAssertEqual(QuickEventParser.parse("call in 2 hours", now: now).start, day(2026, 11, 11, 12, 0))
    }

    func testEventFromNowWithALength() {
        let now = day(2026, 11, 11, 10, 0)
        let d = QuickEventParser.parse("call mom in 2 hours for 30 min", now: now)
        XCTAssertEqual(d.title, "call mom")
        XCTAssertEqual(d.start, day(2026, 11, 11, 12, 0))
        XCTAssertEqual(d.end, day(2026, 11, 11, 12, 30))
    }

    func testNumbersWithoutInOrFromNowStay() {
        let d = QuickEventParser.parse("buy 3 hours of parking", now: day(2026, 11, 11, 10, 0))
        XCTAssertEqual(d.title, "buy 3 hours of parking")
        XCTAssertFalse(d.foundDate)
    }

    func testReminderWordsAreDropped() {
        XCTAssertEqual(QuickEventParser.parse("remind me to water the plants").title, "water the plants")
        XCTAssertEqual(QuickEventParser.parse("don't forget to water the plants").title, "water the plants")
        XCTAssertEqual(QuickEventParser.parse("remind me water the plants").title, "water the plants")
    }
}
