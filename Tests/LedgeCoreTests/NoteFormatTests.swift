import XCTest
@testable import LedgeCore

final class NoteFormatTests: XCTestCase {
    func testHTMLKeepsTitleLinesAndIndents() {
        let html = NoteFormat.html(title: "S3 backup", body: "- [ ] send <bucket list>\n    - [x] done\n\nend")
        XCTAssertEqual(html, "<div><h1>S3 backup</h1></div>"
            + "<div>- [ ] send &lt;bucket list&gt;</div>"
            + "<div>&nbsp;&nbsp;&nbsp;&nbsp;- [x] done</div>"
            + "<div><br></div>"
            + "<div>end</div>")
    }

    func testEmptyTitleBecomesUntitled() {
        XCTAssertTrue(NoteFormat.html(title: " ", body: "").hasPrefix("<div><h1>Untitled</h1></div>"))
    }

    func testSplitPlaintext() {
        let (title, body) = NoteFormat.split(plaintext: "S3 backup\n- [ ] send\n\u{00A0}\u{00A0}\u{00A0}\u{00A0}- [x] done\n\n")
        XCTAssertEqual(title, "S3 backup")
        XCTAssertEqual(body, "- [ ] send\n    - [x] done")
    }

    func testRoundTripOfTheText() {
        let body = "line one\n    - [ ] indented step\n\nlast"
        // What Notes gives back for that HTML: the lines, with non-breaking spaces for the indent.
        let fromNotes = "Title\n" + body.replacingOccurrences(of: "    ", with: "\u{00A0}\u{00A0}\u{00A0}\u{00A0}")
        XCTAssertEqual(NoteFormat.split(plaintext: fromNotes).body, body)
    }

    func testListItem() {
        let item = NoteFormat.listItem("x-coredata://ABC/ICNote/p12\tS3 backup\t2026-11-11T17:00:00")
        XCTAssertEqual(item?.id, "x-coredata://ABC/ICNote/p12")
        XCTAssertEqual(item?.title, "S3 backup")
        XCTAssertNotNil(item?.modified)
        XCTAssertNil(NoteFormat.listItem("garbage"))
    }
}
