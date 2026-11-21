import XCTest
@testable import LedgeCore

final class VersionTests: XCTestCase {
    func testNewer() {
        XCTAssertTrue(Version.isNewer("v1.3.1", than: "1.3"))
        XCTAssertTrue(Version.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(Version.isNewer("v2.0.0", than: "1.99.9"))
        XCTAssertFalse(Version.isNewer("v1.3.0", than: "1.3"))
        XCTAssertFalse(Version.isNewer("1.3", than: "1.3.1"))
        XCTAssertFalse(Version.isNewer("v1.4.0-beta", than: "1.4"))
    }

    func testParts() {
        XCTAssertEqual(Version.parts("v1.3.1"), [1, 3, 1])
        XCTAssertEqual(Version.parts("1.4.0-beta"), [1, 4, 0])
    }
}
