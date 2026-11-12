import Foundation
import LedgeCore
import XCTest

final class MarkdownStyleTests: XCTestCase {
    /// The spans as "kind:the text they cover", easier to read than ranges. `hang` and `lead`
    /// (layout helpers) are left out unless asked for.
    private func parts(_ text: String, layout: Bool = false) -> [String] {
        let ns = text as NSString
        return MarkdownStyle.spans(in: text)
            .filter { layout || ($0.kind != .hang && $0.kind != .lead) }
            .map { "\($0.kind):\(ns.substring(with: $0.range))" }
    }

    func testHeadingStylesTheLineAndHidesTheHashes() {
        XCTAssertEqual(parts("## Plan"), ["heading(2):## Plan", "mark:## "])
        XCTAssertEqual(parts("#tag is not a heading"), [])
    }

    func testRuleLines() {
        XCTAssertEqual(parts("---"), ["rule:---"])
        XCTAssertEqual(parts("* * *"), ["rule:* * *"])
        XCTAssertEqual(parts("-----  "), ["rule:-----  "])
        XCTAssertTrue(MarkdownStyle.isRule("___"))
        XCTAssertFalse(MarkdownStyle.isRule("--"))
        XCTAssertFalse(MarkdownStyle.isRule("--- not a line"))
    }

    func testRangesCountFromTheStartOfTheWholeText() {
        let text = "first\n---\nlast"
        let rule = MarkdownStyle.spans(in: text).first { $0.kind == .rule }
        XCTAssertEqual(rule?.range, NSRange(location: 6, length: 3))
    }

    func testBoldItalicStrikeAndTheirMarks() {
        XCTAssertEqual(parts("a **big** one"), ["mark:**", "bold:big", "mark:**"])
        XCTAssertEqual(parts("an *odd* one"), ["mark:*", "italic:odd", "mark:*"])
        XCTAssertEqual(parts("~~gone~~"), ["mark:~~", "strike:gone", "mark:~~"])
    }

    func testUnderscoresInsideWordsStayPlain() {
        XCTAssertEqual(parts("rename snake_case_name"), [])
        XCTAssertEqual(parts("say _this_"), ["mark:_", "italic:this", "mark:_"])
    }

    func testNothingIsStyledInsideCode() {
        XCTAssertEqual(parts("run `a **b**`"), ["mark:`", "code:a **b**", "mark:`"])
    }

    func testLinksKnowWhereTheyGo() {
        XCTAssertEqual(parts("[docs](https://x.dev)"), [
            "mark:[", "link:docs", "mark:](https://x.dev)", "linkURL:https://x.dev",
        ])
        XCTAssertEqual(parts("see https://x.dev/a"), ["link:https://x.dev/a", "linkURL:https://x.dev/a"])
    }

    func testBulletsByLevel() {
        XCTAssertEqual(parts("- milk"), ["bullet(level: 0):-"])
        XCTAssertEqual(parts("    * eggs"), ["bullet(level: 1):*"])
        XCTAssertEqual(parts("\t\t+ flour"), ["bullet(level: 2):+"])
        XCTAssertEqual(parts("  1. first"), ["number:1."])
    }

    func testCheckboxesHideTheirBullet() {
        XCTAssertEqual(parts("- [ ] reply"), ["checkboxLead:- ", "checkbox(done: false):[ ]"])
        XCTAssertEqual(parts("- [x] sent"), ["checkboxLead:- ", "checkbox(done: true):[x]", "done:sent"])
    }

    func testListLayoutHelpers() {
        XCTAssertEqual(parts("  - [ ] reply", layout: true), [
            "hang:  - [ ] ", "checkboxLead:- ", "checkbox(done: false):[ ]", "lead:- [ ] ",
        ])
        XCTAssertEqual(parts("- milk", layout: true), ["hang:- ", "bullet(level: 0):-", "lead:- "])
    }

    func testQuote() {
        XCTAssertEqual(parts("> wise words", layout: true), [
            "quoteMark:> ", "quote:wise words", "hang:> ", "lead:> ",
        ])
    }

    func testCodeBlockLinesAreOnlyCode() {
        XCTAssertEqual(parts("```\n# not a heading\n```\n# heading"), [
            "fence:```", "codeBlock:# not a heading", "codeArea:```\n# not a heading\n```", "fence:```",
            "heading(1):# heading", "mark:# ",
        ])
    }

    func testAnOpenCodeBlockRunsToTheEnd() {
        XCTAssertEqual(parts("text\n```swift\nlet a = 1"), [
            "fence:```", "fenceInfo:swift", "codeBlock:let a = 1", "codeArea:```swift\nlet a = 1",
        ])
    }

    func testThirdBacktickOfAnOpeningFenceClosesIt() {
        XCTAssertEqual(MarkdownStyle.fenceToClose(typingBacktickAt: 2, in: "``"), "")
        XCTAssertEqual(MarkdownStyle.fenceToClose(typingBacktickAt: 8, in: "a\n    ``\nb"), "    ")
    }

    func testNoClosingFenceWhenItWouldCloseABlockOrSitsMidLine() {
        // Closing a block that's open.
        XCTAssertNil(MarkdownStyle.fenceToClose(typingBacktickAt: 9, in: "```\ncode\n``"))
        // Text after the cursor, or before the ticks.
        XCTAssertNil(MarkdownStyle.fenceToClose(typingBacktickAt: 2, in: "``x"))
        XCTAssertNil(MarkdownStyle.fenceToClose(typingBacktickAt: 3, in: "a``"))
    }

    func testBackspaceAtTheStartOfAnItemRemovesItsMarker() {
        XCTAssertEqual(MarkdownStyle.markerToRemove(backspaceAt: 2, in: "- milk"), NSRange(location: 0, length: 2))
        XCTAssertEqual(MarkdownStyle.markerToRemove(backspaceAt: 10, in: "a\n  - [ ] reply"), NSRange(location: 4, length: 6))
        XCTAssertEqual(MarkdownStyle.markerToRemove(backspaceAt: 3, in: "1. one"), NSRange(location: 0, length: 3))
        XCTAssertEqual(MarkdownStyle.markerToRemove(backspaceAt: 2, in: "> quote"), NSRange(location: 0, length: 2))
    }

    func testBackspaceElsewhereIsJustABackspace() {
        XCTAssertNil(MarkdownStyle.markerToRemove(backspaceAt: 3, in: "- milk"))
        XCTAssertNil(MarkdownStyle.markerToRemove(backspaceAt: 2, in: "plain"))
        XCTAssertNil(MarkdownStyle.markerToRemove(backspaceAt: 3, in: "---"))
    }

    func testReturnContinuesAQuoteAndEndsItOnAnEmptyOne() {
        XCTAssertEqual(Checklist.autoFormat(old: "> wise", new: "> wise\n"), "> wise\n> ")
        XCTAssertEqual(Checklist.autoFormat(old: "> wise\n> ", new: "> wise\n> \n"), "> wise\n")
    }

    func testReturnCountsUpANumberedList() {
        XCTAssertEqual(Checklist.autoFormat(old: "1. one", new: "1. one\n"), "1. one\n2. ")
        XCTAssertEqual(Checklist.autoFormat(old: "9) nine", new: "9) nine\n"), "9) nine\n10) ")
    }

    func testReturnBeforeAnItemsTextPushesItDown() {
        XCTAssertEqual(Checklist.autoFormat(old: "- milk", new: "- \nmilk"), "- \n- milk")
        XCTAssertEqual(Checklist.autoFormat(old: "- [x] sent", new: "- [x] \nsent"), "- [ ] \n- [x] sent")
    }
}
