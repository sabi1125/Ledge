import XCTest
@testable import LedgeCore

final class TrayTests: XCTestCase {
    func testHolding() {
        XCTAssertEqual(TrayText.holding(files: 1, folders: 0), "Holding 1 file in tray")
        XCTAssertEqual(TrayText.holding(files: 0, folders: 1), "Holding 1 folder in tray")
        XCTAssertEqual(TrayText.holding(files: 2, folders: 1), "Holding 2 files and 1 folder in tray")
        XCTAssertEqual(TrayText.holding(files: 3, folders: 2), "Holding 3 files and 2 folders in tray")
        XCTAssertEqual(TrayText.holding(files: 0, folders: 0), "Tray is empty")
    }

    func testLimit() {
        XCTAssertTrue(TrayText.fits(adding: 5, held: 0))
        XCTAssertTrue(TrayText.fits(adding: 1, held: 4))
        XCTAssertFalse(TrayText.fits(adding: 2, held: 4))
        XCTAssertFalse(TrayText.fits(adding: 1, held: 5))
        XCTAssertFalse(TrayText.fits(adding: 0, held: 0))
        XCTAssertEqual(TrayText.spacesLeft(held: 7), 0)
    }

    func testDropWords() {
        XCTAssertEqual(TrayText.dropTitle(files: 2, folders: 0, held: 0, over: false), "Drop to hold in tray")
        XCTAssertEqual(TrayText.dropTitle(files: 2, folders: 0, held: 0, over: true), "Let go to hold 2 files")
        XCTAssertEqual(TrayText.dropDetail(files: 2, folders: 0, held: 0, over: true), "3 spaces left after")
        XCTAssertEqual(TrayText.dropTitle(files: 1, folders: 0, held: 5, over: true), "Tray is full")
        XCTAssertEqual(TrayText.dropTitle(files: 3, folders: 0, held: 3, over: true), "Too many for the tray")
        XCTAssertEqual(TrayText.dropDetail(files: 3, folders: 0, held: 3, over: true), "2 more fit · put these in a folder")
    }

    func testShortName() {
        XCTAssertEqual(TrayText.shortName("a.pdf"), "a.pdf")
        let s = TrayText.shortName("Screenshot 2026-11-13 at 10.21.48 and more words.png", max: 20)
        XCTAssertEqual(s.count, 20)
        XCTAssertTrue(s.hasSuffix(".png"))
    }
}
