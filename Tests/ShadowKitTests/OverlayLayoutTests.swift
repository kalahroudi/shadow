import XCTest
@testable import ShadowKit

final class OverlayLayoutTests: XCTestCase {
    private func store() -> FrameStore {
        let name = "shadow-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return FrameStore(defaults: d)
    }
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testFrameRoundTripsPerDisplay() {
        let s = store()
        let a = CGRect(x: 10, y: 20, width: 430, height: 300)
        let b = CGRect(x: 600, y: 100, width: 520, height: 420)
        s.save(a, for: "display-A"); s.save(b, for: "display-B")
        XCTAssertEqual(s.frame(for: "display-A"), a)
        XCTAssertEqual(s.frame(for: "display-B"), b)
        XCTAssertNil(s.frame(for: "display-C"))
    }

    func testRestoredFallsBackWhenOffScreenOrUnknown() {
        let s = store()
        s.save(CGRect(x: 9000, y: 9000, width: 420, height: 230), for: "A")
        XCTAssertEqual(s.restored(for: "A", compact: true, visible: screen), OverlayLayout.defaultFrame(compact: true, in: screen))
        XCTAssertEqual(s.restored(for: "none", compact: true, visible: screen).size, OverlayLayout.compactSize)
        let ok = CGRect(x: 50, y: 50, width: 450, height: 260)
        s.save(ok, for: "A")
        XCTAssertEqual(s.restored(for: "A", compact: true, visible: screen), ok)
    }

    func testSizesFollowMockupAndResizeKeepsTopLeft() {
        XCTAssertEqual(OverlayLayout.minSize(compact: true).width, 420)
        XCTAssertEqual(OverlayLayout.minSize(compact: false).width, 520)
        let old = CGRect(x: 100, y: 500, width: 420, height: 230)
        let new = OverlayLayout.resized(old, compact: false)
        XCTAssertEqual(new.minX, old.minX); XCTAssertEqual(new.maxY, old.maxY)
        XCTAssertEqual(new.size, OverlayLayout.expandedSize)
    }

    func testOverlayStateFollowsSession() {
        XCTAssertEqual(OverlayState.from(sessionRunning: false), .idle)
        XCTAssertEqual(OverlayState.from(sessionRunning: true), .listening)
    }

    func testRestoredEnforcesMinWidthAndRequiresUsableOverlap() {
        let s = store()
        s.save(CGRect(x: 100, y: 300, width: 420, height: 230), for: "A")   // saved in Compact
        let expanded = s.restored(for: "A", compact: false, visible: screen)
        XCTAssertEqual(expanded.width, 520)
        XCTAssertEqual(expanded.minX, 100); XCTAssertEqual(expanded.maxY, 530)
        s.save(CGRect(x: 1438, y: 300, width: 420, height: 230), for: "B")   // a 2pt sliver on screen
        XCTAssertEqual(s.restored(for: "B", compact: true, visible: screen), OverlayLayout.defaultFrame(compact: true, in: screen))
    }
}
