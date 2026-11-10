import XCTest
@testable import ShadowKit

final class SessionTimeMapTests: XCTestCase {
    func testContiguousBuffersMapByFirstSessionTime() {
        var map = SessionTimeMap()
        for i in 0..<10 { map.append(sessionTime: 5 + Double(i) * 0.1, duration: 0.1) }
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 0), 5, accuracy: 1e-9)
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 0.55), 5.55, accuracy: 1e-9)
    }

    func testSmallJitterDoesNotMoveTheMapping() {
        var map = SessionTimeMap()
        map.append(sessionTime: 2, duration: 0.1)
        map.append(sessionTime: 2.13, duration: 0.1)
        map.append(sessionTime: 2.18, duration: 0.1)
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 0.25), 2.25, accuracy: 1e-9)
    }

    func testLongGapInSourceIsNotCarriedIntoLaterResults() {
        var map = SessionTimeMap()
        map.append(sessionTime: 0, duration: 1)
        map.append(sessionTime: 1, duration: 1)       // analyzer time 0...2
        map.append(sessionTime: 62, duration: 1)      // 60 s of nothing, then analyzer 2...3
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 1.5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 2.5), 62.5, accuracy: 1e-9)
    }

    func testNonFiniteFirstTimeFallsBackToZero() {
        var map = SessionTimeMap()
        map.append(sessionTime: .nan, duration: 1)
        map.append(sessionTime: 1, duration: 1)
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 1.5), 1.5, accuracy: 1e-9)
    }

    func testNonFiniteLaterTimeAndDurationAreIgnored() {
        var map = SessionTimeMap()
        map.append(sessionTime: 3, duration: 1)
        map.append(sessionTime: .infinity, duration: .nan)
        map.append(sessionTime: 4, duration: 1)
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 1.5), 4.5, accuracy: 1e-9)
    }

    func testEmptyMapIsIdentity() {
        XCTAssertEqual(SessionTimeMap().sessionTime(forAnalyzerTime: 2), 2)
    }

    func testAnchorsStayBounded() {
        var map = SessionTimeMap()
        for i in 0..<5000 { map.append(sessionTime: Double(i) * 100, duration: 0.1) }
        XCTAssertEqual(map.sessionTime(forAnalyzerTime: 499.95), 499_900.05, accuracy: 1e-3)
    }
}
