import XCTest
@testable import LedgeCore

final class TodoTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()
    // Wednesday 11 November 2026, 1:12 PM in Tokyo.
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 13, minute: 12))!

    func testAllTheMarkers() {
        let d = TodoInput.parse("! Reply to 菅さん's review fri #s3 [30m]", now: now, calendar: cal)
        XCTAssertEqual(d.title, "Reply to 菅さん's review")
        XCTAssertTrue(d.isMust)
        XCTAssertEqual(d.listTag, "s3")
        XCTAssertEqual(d.minutes, 30)
        XCTAssertTrue(d.hasDue)
        XCTAssertFalse(d.dueHasTime)
        XCTAssertEqual(d.event.start, cal.date(from: DateComponents(year: 2026, month: 11, day: 13)))
    }

    func testMustStuckToAWord() {
        let d = TodoInput.parse("!Check the feedback", now: now, calendar: cal)
        XCTAssertTrue(d.isMust)
        XCTAssertEqual(d.title, "Check the feedback")
    }

    func testExclamationInsideAWordIsNotMust() {
        let d = TodoInput.parse("Ship it!", now: now, calendar: cal)
        XCTAssertFalse(d.isMust)
        XCTAssertEqual(d.title, "Ship it!")
    }

    func testNoDateMeansNoDueDate() {
        let d = TodoInput.parse("List all the pushed tickets [2h]", now: now, calendar: cal)
        XCTAssertFalse(d.hasDue)
        XCTAssertEqual(d.minutes, 120)
        XCTAssertEqual(d.title, "List all the pushed tickets")
    }

    func testLinkIsKeptAsTheURL() {
        let d = TodoInput.parse("Reply https://cios.backlog.com/view/CONTRACT-9508#comment-285896573 tomorrow 10am", now: now, calendar: cal)
        XCTAssertEqual(d.url?.absoluteString, "https://cios.backlog.com/view/CONTRACT-9508#comment-285896573")
        XCTAssertNil(d.listTag)
        XCTAssertEqual(d.title, "Reply")
        XCTAssertTrue(d.dueHasTime)
    }

    func testTitleWithTimeGuess() {
        XCTAssertEqual(TodoTitle.split("Reply to the review [30m]").title, "Reply to the review")
        XCTAssertEqual(TodoTitle.split("Reply to the review [30m]").minutes, 30)
        XCTAssertEqual(TodoTitle.split("Plain").minutes, nil)
        XCTAssertEqual(TodoTitle.join("Plan", minutes: 90), "Plan [90m]")
        XCTAssertEqual(TodoTitle.split("Plan [90m]").minutes, 90)
        XCTAssertEqual(TodoTitle.join("Plan", minutes: 120), "Plan [2h]")
        XCTAssertEqual(TodoTitle.format(minutes: 60), "1h")
    }

    func testChecklist() {
        let notes = "context line\n- [x] send this comment for review\n- [ ] reply to the feedback\n  - [ ] check 菅さん's notes"
        let items = Checklist.items(in: notes)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].done, true)
        XCTAssertEqual(items[1].text, "reply to the feedback")
        XCTAssertEqual(Checklist.progress(in: notes).done, 1)
        XCTAssertEqual(Checklist.otherLines(in: notes), ["context line"])
        let toggled = Checklist.toggling(line: 2, in: notes)
        XCTAssertEqual(Checklist.progress(in: toggled).done, 2)
    }

    func testTypingABoxShortcut() {
        XCTAssertEqual(Checklist.autoFormat(old: "[]", new: "[] "), "- [ ] ")
        XCTAssertEqual(Checklist.autoFormat(old: "a\n[ ]", new: "a\n[ ] "), "a\n- [ ] ")
        XCTAssertNil(Checklist.autoFormat(old: "abc", new: "abcd"))
    }

    func testListLinesForTab() {
        XCTAssertTrue(Checklist.isListLine("- [ ] step"))
        XCTAssertTrue(Checklist.isListLine("    - item"))
        XCTAssertTrue(Checklist.isListLine("* item"))
        XCTAssertFalse(Checklist.isListLine("plain text"))
        XCTAssertFalse(Checklist.isListLine("-not a list"))
    }

    func testReturnContinuesAndEndsTheList() {
        XCTAssertEqual(Checklist.autoFormat(old: "- [ ] one", new: "- [ ] one\n"), "- [ ] one\n- [ ] ")
        XCTAssertEqual(Checklist.autoFormat(old: "- [x] done", new: "- [x] done\n"), "- [x] done\n- [ ] ")
        XCTAssertEqual(Checklist.autoFormat(old: "- [ ] one\n- [ ] ", new: "- [ ] one\n- [ ] \n"), "- [ ] one\n")
        XCTAssertEqual(Checklist.autoFormat(old: "- bullet", new: "- bullet\n"), "- bullet\n- ")
        XCTAssertNil(Checklist.autoFormat(old: "plain", new: "plain\n"))
    }
}

final class NoteLinksTests: XCTestCase {
    func testMarkdownLinkWithoutScheme() {
        XCTAssertEqual(NoteLinks.markdown("see [google](www.google.com)"), "see [google](https://www.google.com)")
        XCTAssertEqual(NoteLinks.markdown("[docs](https://a.com/x)"), "[docs](https://a.com/x)")
    }

    func testBareLinkGetsAShortName() {
        XCTAssertEqual(NoteLinks.markdown("ref https://cios.backlog.com/view/CONTRACT-9508#comment-283747400"),
                       "ref [CONTRACT-9508](https://cios.backlog.com/view/CONTRACT-9508#comment-283747400)")
    }

    func testFirstLink() {
        XCTAssertEqual(NoteLinks.first(in: "x [g](www.google.com) y")?.absoluteString, "https://www.google.com")
        XCTAssertEqual(NoteLinks.first(in: "go https://a.com/b now")?.absoluteString, "https://a.com/b")
        XCTAssertNil(NoteLinks.first(in: "nothing here"))
    }

    func testToDoFromNowHasATimeAndKeepsItsGuess() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))!
        let t = TodoInput.parse("remind me to check the oven in 30 min [10m]", now: now)
        XCTAssertEqual(t.title, "check the oven")
        XCTAssertTrue(t.dueHasTime) // so an alarm is set
        XCTAssertEqual(t.minutes, 10)
        XCTAssertEqual(t.event.start, now.addingTimeInterval(30 * 60))
    }
}
