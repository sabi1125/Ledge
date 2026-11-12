import Foundation
import LedgeCore
import XCTest

final class EventOrderTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    /// 2026-11-12 at the given hour and minute, Tokyo time.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func group(_ start: Date, _ end: Date, allDay: Bool = false) -> EventOrder.Group {
        EventOrder.group(start: start, end: end, isAllDay: allDay, now: at(14), calendar: calendar)
    }

    func testMeetingsComeBeforeAllDayAndLongItems() {
        XCTAssertEqual(group(at(13, 30), at(14, 30)), .now)
        XCTAssertEqual(group(at(15), at(16)), .laterToday)
        XCTAssertEqual(group(at(0), at(0, day: 13), allDay: true), .todayBackground)
        // An all-morning block that runs into the afternoon is background, not "now".
        XCTAssertEqual(group(at(9), at(18)), .todayBackground)
    }

    func testTomorrow() {
        XCTAssertEqual(group(at(10, day: 13), at(11, day: 13)), .tomorrow)
        XCTAssertEqual(group(at(0, day: 13), at(0, day: 14), allDay: true), .tomorrowBackground)
    }

    func testOrderIsGroupThenStart() {
        let now = at(14)
        let allDay = (start: at(0), end: at(0, day: 13), isAllDay: true)
        let current = (start: at(13, 30), end: at(14, 30), isAllDay: false)
        let next = (start: at(15), end: at(16), isAllDay: false)
        let later = (start: at(17), end: at(17, 30), isAllDay: false)
        let sorted = [allDay, later, next, current].sorted { EventOrder.isBefore($0, $1, now: now, calendar: calendar) }
        XCTAssertEqual(sorted.map(\.start), [current.start, next.start, later.start, allDay.start])
    }
}
