import LedgeCore
import XCTest

final class ListSuggestTests: XCTestCase {
    private let lists = ["Work", "Personal", "Side project", "Homework", "s3 migration"]

    func testActiveTagIsTheHashWordAtTheEnd() {
        XCTAssertEqual(ListSuggest.activeTag(in: "Reply to the review #wo"), "wo")
        XCTAssertEqual(ListSuggest.activeTag(in: "Reply #"), "")
        XCTAssertEqual(ListSuggest.activeTag(in: "#Work"), "Work")
    }

    func testNoActiveTagAfterASpaceOrInsideAWord() {
        XCTAssertNil(ListSuggest.activeTag(in: "Reply #work "))
        XCTAssertNil(ListSuggest.activeTag(in: "Reply #work fri"))
        XCTAssertNil(ListSuggest.activeTag(in: "issue#12"))
        XCTAssertNil(ListSuggest.activeTag(in: "Reply ##"))
        XCTAssertNil(ListSuggest.activeTag(in: ""))
    }

    func testMatchesSameNameThenStartsWithThenContains() {
        XCTAssertEqual(ListSuggest.matches("work", in: lists), ["Work", "Homework"])
        XCTAssertEqual(ListSuggest.matches("wo", in: lists), ["Work", "Homework"])
        XCTAssertEqual(ListSuggest.matches("s", in: lists), ["Side project", "s3 migration", "Personal"])
    }

    func testDashesMatchSpaces() {
        XCTAssertEqual(ListSuggest.matches("side-pro", in: lists), ["Side project"])
        XCTAssertEqual(ListSuggest.matches("side_project", in: lists), ["Side project"])
    }

    func testEmptyTagOffersEveryListUpToTheLimit() {
        XCTAssertEqual(ListSuggest.matches("", in: lists), Array(lists.prefix(4)))
        XCTAssertEqual(ListSuggest.matches("", in: lists, limit: 2), ["Work", "Personal"])
    }

    func testNoMatch() {
        XCTAssertEqual(ListSuggest.matches("wrok", in: lists), [])
    }

    func testCompleteReplacesTheTagAndAddsASpace() {
        XCTAssertEqual(ListSuggest.complete("Reply fri #wo", with: "Work"), "Reply fri #Work ")
        XCTAssertEqual(ListSuggest.complete("Plan it #", with: "Side project"), "Plan it #Side-project ")
    }

    func testCompleteLeavesALineWithoutATagAlone() {
        XCTAssertEqual(ListSuggest.complete("Reply fri", with: "Work"), "Reply fri")
    }

    func testCompletedTagIsReadBackAsTheSameList() {
        let line = ListSuggest.complete("Plan it #side", with: "Side project")
        let draft = TodoInput.parse(line)
        XCTAssertEqual(draft.listTag, "Side-project")
        XCTAssertEqual(ListSuggest.matches(draft.listTag ?? "", in: lists).first, "Side project")
        XCTAssertEqual(draft.title, "Plan it")
    }
}
