import XCTest
@testable import ShadowKit

final class KitTests: XCTestCase {
    func testSetupStateWithNothingMissingIsReady() {
        XCTAssertTrue(SetupState(items: []).ready)
    }

    // MARK: sessions (crash safety), ported to the one-file-per-session store
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)") }
    private func record(_ text: String) -> SessionRecord {
        SessionRecord(id: UUID(), startedAt: Date(), segments: [Segment(speaker: .you, text: text, start: 0, end: 1, isFinal: true)])
    }

    func testSessionsSurviveCleanRestart() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        let r = record("one")
        try a.begin(r.id); try a.write(r); a.end()
        let b = SessionStore(directory: dir)
        let check = b.launchCheck()
        XCTAssertNil(check.interrupted)
        XCTAssertEqual(check.quarantined, [])
        XCTAssertFalse(b.hasRunningLock)
        XCTAssertEqual(b.read(r.id), r)
    }

    func testCrashIsDetectedAndTranscriptOffered() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        let r = record("busy")
        try a.begin(r.id); try a.write(r)          // no end(): simulates a crash / kill -9
        XCTAssertTrue(SessionStore(directory: dir).hasRunningLock)
        let check = SessionStore(directory: dir).launchCheck()
        XCTAssertEqual(check.interrupted?.id, r.id)
        XCTAssertEqual(check.interrupted?.segments.map(\.text), ["busy"])
    }

    func testCorruptSessionIsQuarantinedAndKept() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        let r = record("keep")
        try a.begin(r.id)
        try Data("{ not json".utf8).write(to: a.fileURL(for: r.id))
        let check = SessionStore(directory: dir).launchCheck()
        XCTAssertNil(check.interrupted)
        XCTAssertEqual(check.quarantined, ["\(r.id.uuidString).json.corrupt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL(for: r.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL(for: r.id).appendingPathExtension("corrupt").path))
    }
}
