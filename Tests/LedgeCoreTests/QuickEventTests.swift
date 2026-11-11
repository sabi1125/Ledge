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
}
