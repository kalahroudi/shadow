import XCTest
@testable import ShadowKit

/// R20 / A20 (the file format half).
final class SessionRecordV2Tests: XCTestCase {
    private let v1 = """
    {"version":1,"id":"11111111-2222-3333-4444-555555555555","startedAt":700000000,
     "segments":[{"speaker":"them","text":"hello","start":0,"end":1,"locale":"en-US","confidence":1,"isFinal":true}]}
    """

    func testVersionIsTwo() { XCTAssertEqual(SessionRecord.currentVersion, 2) }

    func testV1FileLoadsWithoutLossAndWithoutAnswers() throws {
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(v1.utf8))
        XCTAssertEqual(r.version, 1)
        XCTAssertEqual(r.segments.map(\.text), ["hello"])
        XCTAssertNil(r.answers)
    }

    func testV1FileOnDiskIsReadByTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(directory: dir)
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        try Data(v1.utf8).write(to: store.fileURL(for: id))
        XCTAssertEqual(store.read(id)?.segments.count, 1)
    }

    func testV2RoundTripKeepsAnswers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = AnswerRecord(question: "Why?", text: "Because.", persona: "Interview", provider: "apple", model: "on-device", kind: "shorter", latencyMs: 420)
        let record = SessionRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segments: [Segment(speaker: .them, text: "Why?", start: 0, end: 1, isFinal: true)], answers: [a])
        let store = SessionStore(directory: dir)
        try store.write(record)
        let back = try XCTUnwrap(store.read(record.id))
        XCTAssertEqual(back, record)
        XCTAssertEqual(back.version, 2)
        XCTAssertEqual(back.answers, [a])
    }

    func testAFutureVersionWithExtraKeysStillLoads() throws {
        let json = v1.replacingOccurrences(of: "\"version\":1", with: "\"version\":9,\"somethingNew\":true")
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8)).version, 9)
    }
}
