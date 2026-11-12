import XCTest
@testable import LedgeCore

final class RepeatTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    /// Friday, Nov 13 2026, 10 AM.
    private var now: Date { day(2026, 11, 13, 10) }

    func testGymOnChosenDaysUntilAMonth() {
        let d = QuickEventParser.parse("gym every mon wed fri 5-7pm until dec 2029", now: now)
        XCTAssertEqual(d.title, "gym")
        XCTAssertEqual(d.repeatRule?.frequency, .weekly)
        XCTAssertEqual(Set(d.repeatRule?.weekdays ?? []), [2, 4, 6])
        XCTAssertEqual(d.repeatRule?.until, day(2029, 12, 31))
        // Today is a Friday and 5 PM is still ahead: the first one is today.
        XCTAssertEqual(d.start, day(2026, 11, 13, 17))
        XCTAssertEqual(d.end, day(2026, 11, 13, 19))
    }

    func testEveryWeekendStartsOnSaturday() {
        let d = QuickEventParser.parse("hike every weekend 9am", now: now)
        XCTAssertEqual(d.title, "hike")
        XCTAssertEqual(Set(d.repeatRule?.weekdays ?? []), [1, 7])
        XCTAssertEqual(d.start, day(2026, 11, 14, 9))
        XCTAssertEqual(d.repeatRule?.summary(), "Every weekend")
    }

    func testWeekdaysAndWeekendsOnTheirOwn() {
        XCTAssertEqual(Set(QuickEventParser.parse("standup weekdays 10am", now: now).repeatRule?.weekdays ?? []), [2, 3, 4, 5, 6])
        XCTAssertEqual(Set(QuickEventParser.parse("brunch weekends 11am", now: now).repeatRule?.weekdays ?? []), [1, 7])
        XCTAssertEqual(QuickEventParser.parse("standup every weekday 10am", now: now).repeatRule?.summary(), "Every weekday")
    }

    func testStartingLater() {
        let d = QuickEventParser.parse("gym every mon wed fri 5-7pm from dec 1 2027 until dec 2029", now: now)
        XCTAssertEqual(d.title, "gym")
        XCTAssertEqual(d.start, day(2027, 12, 1, 17)) // Dec 1 2027 is a Wednesday
    }

    func testOtherWeekAndNumbers() {
        XCTAssertEqual(QuickEventParser.parse("cleaning every other week sat 10am", now: now).repeatRule?.interval, 2)
        let d = QuickEventParser.parse("review every 2 weeks", now: now)
        XCTAssertEqual(d.repeatRule?.interval, 2)
        XCTAssertEqual(d.repeatRule?.summary(), "Every other week")
    }

    func testMonthOnADay() {
        let d = QuickEventParser.parse("rent every month on the 25th", now: now)
        XCTAssertEqual(d.title, "rent")
        XCTAssertEqual(d.repeatRule?.frequency, .monthly)
        XCTAssertEqual(d.repeatRule?.monthDay, 25)
        XCTAssertEqual(d.start, day(2026, 11, 25))
        XCTAssertEqual(d.repeatRule?.summary(), "Every month on the 25th")
    }

    func testDailyYearlyAndEndings() {
        XCTAssertEqual(QuickEventParser.parse("vitamins daily 8am", now: now).repeatRule?.frequency, .daily)
        XCTAssertEqual(QuickEventParser.parse("birthday every year dec 3", now: now).repeatRule?.frequency, .yearly)
        XCTAssertEqual(QuickEventParser.parse("class every tue and thu 6pm until 2027", now: now).repeatRule?.until, day(2027, 12, 31))
        XCTAssertEqual(QuickEventParser.parse("class every tuesday 6pm until dec 15 2027", now: now).repeatRule?.until, day(2027, 12, 15))
    }

    func testWordsThatAreNotRepeats() {
        XCTAssertNil(QuickEventParser.parse("everything for the trip fri", now: now).repeatRule)
        XCTAssertNil(QuickEventParser.parse("dentist tomorrow 3pm", now: now).repeatRule)
    }

    func testToDosRepeatToo() {
        let t = TodoInput.parse("take out the trash every fri 8am", now: now)
        XCTAssertEqual(t.title, "take out the trash")
        XCTAssertEqual(t.event.repeatRule?.weekdays, [6])
        XCTAssertTrue(t.dueHasTime)
        XCTAssertEqual(t.event.start, day(2026, 11, 20, 8)) // 8 AM today has passed
    }

    func testWeekEndWithASpaceAndFromHours() {
        let d = QuickEventParser.parse("gym every week end from 5 to 8", now: now)
        XCTAssertEqual(d.title, "gym")
        XCTAssertEqual(Set(d.repeatRule?.weekdays ?? []), [1, 7])
        XCTAssertEqual(d.start, day(2026, 11, 14, 17))
        XCTAssertEqual(d.end, day(2026, 11, 14, 20))
    }

    func testFromHoursOnTheirOwn() {
        let now = day(2026, 11, 13, 10)
        let d = QuickEventParser.parse("study from 9 to 11", now: now)
        XCTAssertEqual(d.start, day(2026, 11, 14, 9)) // like "at 9": the morning, so tomorrow (it's past 9 AM)
        XCTAssertEqual(QuickEventParser.parse("meeting from 11 to 1", now: now).end, day(2026, 11, 13, 13))
        // Without "from", plain numbers stay plain numbers.
        XCTAssertEqual(QuickEventParser.parse("order 5 to 8 chairs", now: now).title, "order 5 to 8 chairs")
    }
}
