// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import ShadowKit

final class NoticeCenterTests: XCTestCase {
    func testSentenceEndsInExactlyOnePeriod() {
        XCTAssertEqual(NoticeText.sentence("Hit an error."), "Hit an error.")
        XCTAssertEqual(NoticeText.sentence("Hit an error"), "Hit an error.")
        XCTAssertEqual(NoticeText.sentence("Hit an error.. "), "Hit an error.")
        XCTAssertEqual(NoticeText.sentence("Really?"), "Really?")
        XCTAssertEqual(NoticeText.sentence("  "), "")
    }

    func testControllerNoticeHasNoDoublePeriod() {
        let text = NoticeText.sentence("Speech recognition stopped for Them: The speech recognizer hit an error.")
        XCTAssertFalse((text + " Shadow is still capturing You.").contains(".."))
    }

    func testDifferentNoticesGetTheirOwnLines() {
        var c = NoticeCenter()
        c.add("A."); c.add("B.")
        XCTAssertEqual(c.joined, "A.\nB.")
    }

    func testIdenticalNoticesCollapse() {
        var c = NoticeCenter()
        XCTAssertTrue(c.add("A.")); XCTAssertFalse(c.add("A.")); XCTAssertFalse(c.add("  "))
        XCTAssertEqual(c.notices.count, 1)
    }

    func testDismissingOneLeavesTheOther() {
        var c = NoticeCenter()
        c.add("A."); c.add("B.")
        c.dismiss(id: c.notices[0].id)
        XCTAssertEqual(c.notices.map(\.text), ["B."])
        XCTAssertTrue(c.add("A."), "a dismissed notice can be raised again by a new failure")
    }
}
