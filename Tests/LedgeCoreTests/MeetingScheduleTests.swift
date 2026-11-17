import XCTest
@testable import LedgeCore

final class MeetingScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    func meeting(_ id: String, start: Double, minutes: Double = 30, allDay: Bool = false, declined: Bool = false) -> MeetingSchedule.Event {
        .init(id: id, start: at(start), end: at(start + minutes), isAllDay: allDay, declined: declined)
    }

    func testPhasesOverTime() {
        let e = [meeting("a", start: 10)]
        XCTAssertNil(MeetingSchedule.current(e, now: at(4.9)))
        XCTAssertEqual(MeetingSchedule.current(e, now: at(5))?.phase, .countdown)
        XCTAssertEqual(MeetingSchedule.current(e, now: at(8.9))?.phase, .countdown)
        XCTAssertEqual(MeetingSchedule.current(e, now: at(9))?.phase, .alert)
        XCTAssertEqual(MeetingSchedule.current(e, now: at(14.9))?.phase, .alert)
        XCTAssertNil(MeetingSchedule.current(e, now: at(15)))
    }

    func testSkipsAllDayDeclinedLongAndDismissed() {
        XCTAssertNil(MeetingSchedule.current([meeting("a", start: 10, allDay: true)], now: at(9.5)))
        XCTAssertNil(MeetingSchedule.current([meeting("a", start: 10, declined: true)], now: at(9.5)))
        XCTAssertNil(MeetingSchedule.current([meeting("a", start: 10, minutes: 5 * 60)], now: at(9.5)))
        XCTAssertNil(MeetingSchedule.current([meeting("a", start: 10)], now: at(9.5), dismissed: ["a"]))
    }

    func testShortMeetingPillEndsWithIt() {
        XCTAssertNil(MeetingSchedule.current([meeting("a", start: 10, minutes: 2)], now: at(12.5)))
    }

    func testBackToBackTheNextOneTakesOver() {
        let e = [meeting("a", start: 0), meeting("b", start: 3)]
        XCTAssertEqual(MeetingSchedule.current(e, now: at(1))?.id, "a")
        XCTAssertEqual(MeetingSchedule.current(e, now: at(2))?.id, "b")
        // A pill beats another meeting's countdown.
        let f = [meeting("a", start: 0), meeting("b", start: 4)]
        XCTAssertEqual(MeetingSchedule.current(f, now: at(0.5))?.id, "a")
    }

    func testNextCheck() {
        XCTAssertEqual(MeetingSchedule.nextCheck([meeting("a", start: 10)], now: at(6)), 1)
        XCTAssertEqual(MeetingSchedule.nextCheck([meeting("a", start: 10)], now: at(4.9)), 6, accuracy: 0.01)
        XCTAssertEqual(MeetingSchedule.nextCheck([meeting("a", start: 60)], now: at(0)), 30)
        XCTAssertEqual(MeetingSchedule.nextCheck([], now: at(0)), 30)
    }

    func testTexts() {
        XCTAssertEqual(MeetingSchedule.whenText(start: at(1), now: at(0.3)), "in 0:42")
        XCTAssertEqual(MeetingSchedule.whenText(start: at(1), now: at(1.5)), "now")
        XCTAssertEqual(MeetingSchedule.whenText(start: at(1), now: at(3.2)), "2 min ago")
        XCTAssertEqual(MeetingSchedule.countdownText(start: at(5), now: at(0)), "5:00")
        XCTAssertEqual(MeetingSchedule.countdownText(start: at(5), now: at(0.02)), "4:59")
    }
}
