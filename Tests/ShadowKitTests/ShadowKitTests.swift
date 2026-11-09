import XCTest
@testable import ShadowKit

final class KitTests: XCTestCase {
    func testSetupStateWithNothingMissingIsReady() {
        XCTAssertTrue(SetupState(items: []).ready)
    }

    // MARK: sessions (crash safety)
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)") }

    func testSessionsSurviveCleanRestart() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); let m = SessionMeta(title: "one"); idx.sessions = [m]; idx.selected = m.id
        try a.saveIndex(idx); try a.writePayload(m.id, Data("hello".utf8)); a.markCleanShutdown()
        let b = SessionStore(directory: dir).load()
        XCTAssertFalse(b.recoveredFromCrash)
        XCTAssertEqual(b.index.sessions.map(\.title), ["one"])
        XCTAssertEqual(SessionStore(directory: dir).readPayload(m.id), Data("hello".utf8))
    }

    func testCrashRestoresAndMarksRunningAsInterrupted() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); idx.sessions = [SessionMeta(title: "busy", status: .busy), SessionMeta(title: "idle")]
        try a.saveIndex(idx)                       // no markCleanShutdown: simulates a crash / kill -9
        let b = SessionStore(directory: dir).load()
        XCTAssertTrue(b.recoveredFromCrash)
        XCTAssertEqual(b.index.sessions.map(\.status), [.interrupted, .idle])
    }

    func testCorruptIndexFallsBackToBackupAndIsQuarantined() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); idx.sessions = [SessionMeta(title: "keep")]
        try a.saveIndex(idx); try a.saveIndex(idx)  // second save leaves index.json.bak
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("index.json"))
        let b = SessionStore(directory: dir).load()
        XCTAssertEqual(b.index.sessions.map(\.title), ["keep"])
        XCTAssertEqual(b.quarantined, ["index.json.corrupt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json.corrupt").path))
    }
}
