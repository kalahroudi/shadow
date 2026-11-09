import XCTest
@testable import ShadowKit

final class SessionPipelineTests: XCTestCase {
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)") }
    private func seg(_ s: Speaker, _ t: String, _ start: Double, final: Bool) -> Segment {
        Segment(speaker: s, text: t, start: start, end: start + 1, locale: "en-US", confidence: 0.9, isFinal: final)
    }
    private func collectAll(_ stream: AsyncThrowingStream<Segment, Error>) async -> ([Segment], Error?) {
        var out: [Segment] = []
        do { for try await s in stream { out.append(s) } } catch { return (out, error) }
        return (out, nil)
    }
    private func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int) async -> [T] {
        var out: [T] = []
        var it = stream.makeAsyncIterator()
        while out.count < count, let v = await it.next() { out.append(v) }
        return out
    }

    // A5: both sources get the one session clock, and buffer times derive from it.
    func testSourcesShareOneClockAndStampFromIt() async throws {
        let clock = SessionClock(start: Date(timeIntervalSince1970: 1_000))
        let them = FakeAudioSource(script: [(0.5, 0.1), (1.0, 0.1)])
        let you = FakeAudioSource(script: [(0.25, 0.1)])
        let a = try await them.start(clock: clock), b = try await you.start(clock: clock)
        let t = await collect(a, count: 2), y = await collect(b, count: 1)
        XCTAssertEqual(t.map(\.time), [0.5, 1.0])
        XCTAssertEqual(y.map(\.time), [0.25])
    }

    // A9: partial then final, all fields set, in order.
    func testFakeProviderEmitsPartialThenFinalInOrder() async {
        let script = [seg(.them, "hel", 0, final: false), seg(.them, "hello", 0, final: true)]
        let stt = FakeSTTProvider(scripts: [.them: script])
        let (src, cont) = AsyncStream<TimedBuffer>.makeStream()
        cont.yield(TimedBuffer(buffer: makeBuffer(0.1), time: 0)); cont.yield(TimedBuffer(buffer: makeBuffer(0.1), time: 1)); cont.finish()
        let (got, error) = await collectAll(stt.transcribe(src, speaker: .them, locale: Locale(identifier: "en-US")))
        XCTAssertNil(error)
        XCTAssertEqual(got, script)
        XCTAssertEqual(got[1].speaker, .them); XCTAssertEqual(got[1].locale, "en-US"); XCTAssertEqual(got[1].confidence, 0.9)
    }

    func testFakeProviderThrowsMidStream() async {
        struct Boom: Error {}
        let stt = FakeSTTProvider(scripts: [.them: [seg(.them, "a", 0, final: true), seg(.them, "b", 1, final: true)]],
                                  failures: [.them: (1, Boom())])
        let (src, cont) = AsyncStream<TimedBuffer>.makeStream()
        cont.yield(TimedBuffer(buffer: makeBuffer(0.1), time: 0)); cont.yield(TimedBuffer(buffer: makeBuffer(0.1), time: 1)); cont.finish()
        let (got, error) = await collectAll(stt.transcribe(src, speaker: .them, locale: Locale(identifier: "en-US")))
        XCTAssertEqual(got.map(\.text), ["a"])
        XCTAssertTrue(error is Boom)
    }

    // One stream's recogniser dies mid-session: a friendly notice, the other stream keeps transcribing, nothing already heard is lost.
    func testRecognizerFailureRaisesNoticeAndKeepsOtherStream() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let them = FakeAudioSource(script: [(0.1, 0.5), (0.5, 0.5), (0.9, 0.5)])
        let you = FakeAudioSource(script: [(0.3, 0.25), (0.8, 0.25)])
        let stt = FakeSTTProvider(scripts: [
            .them: [seg(.them, "before the failure", 0.1, final: true), seg(.them, "never heard", 0.5, final: true)],
            .you: [seg(.you, "hi", 0.3, final: true), seg(.you, "still here", 0.8, final: true)],
        ], failures: [.them: (1, UserFacingError("The speech engine stopped."))])
        let controller = SessionController(them: them, you: you, stt: stt, store: store)
        let notices = await controller.notices()
        try await controller.start(locale: Locale(identifier: "en-US"))

        var it = notices.makeAsyncIterator()
        let first = await it.next()
        let notice = try XCTUnwrap(first)
        XCTAssertTrue(notice.contains("Them"))
        XCTAssertTrue(notice.contains("The speech engine stopped."))
        XCTAssertTrue(notice.contains("still capturing You"))
        let running = await controller.isRunning
        XCTAssertTrue(running)

        let record = try await controller.stop()
        let saved = try XCTUnwrap(record)
        XCTAssertEqual(saved.segments.filter { $0.speaker == .them }.map(\.text), ["before the failure"])
        XCTAssertEqual(saved.segments.filter { $0.speaker == .you }.map(\.text), ["hi", "still here"])
        XCTAssertEqual(you.stopCount, 1); XCTAssertEqual(them.stopCount, 1)
    }

    // A21 + A23: Start -> partials -> finals -> Stop -> file, with fakes only.
    func testFullPipelineWritesSessionFile() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let them = FakeAudioSource(script: [(0.1, 0.5), (0.5, 0.5)])
        let you = FakeAudioSource(script: [(0.3, 0.25), (0.8, 0.25)])
        let stt = FakeSTTProvider(scripts: [
            .them: [seg(.them, "how are", 0.1, final: false), seg(.them, "how are you?", 0.1, final: true)],
            .you: [seg(.you, "fine", 0.3, final: false), seg(.you, "fine thanks", 0.3, final: false)],  // never finalised: Stop flushes it
        ])
        let controller = SessionController(them: them, you: you, stt: stt, store: store)

        let id = try await controller.start(locale: Locale(identifier: "en-US"))
        XCTAssertTrue(store.hasRunningLock)
        let running = await controller.isRunning
        XCTAssertTrue(running)
        XCTAssertEqual(them.clocks, you.clocks)                       // one start time
        XCTAssertEqual(stt.preparedLocales.map(\.identifier), ["en-US"])

        let record = try await controller.stop()
        let saved = try XCTUnwrap(record)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.version, SessionRecord.currentVersion)
        XCTAssertEqual(saved.segments.map(\.text), ["how are you?", "fine thanks"])
        XCTAssertTrue(saved.segments.allSatisfy(\.isFinal))
        XCTAssertFalse(store.hasRunningLock)
        XCTAssertEqual(them.stopCount, 1); XCTAssertEqual(you.stopCount, 1)

        // Round trip, and the JSON carries a version field.
        XCTAssertEqual(store.read(id), saved)
        let json = try String(contentsOf: store.fileURL(for: id), encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\""))
        XCTAssertTrue(store.fileURL(for: id).path.hasPrefix(dir.path))
        // Only the one JSON file exists: no audio, no temp files.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["\(id.uuidString).json"])
    }

    // A6: meters follow the buffers and fall to zero on stop.
    func testLevelsFollowBuffersAndResetOnStop() async throws {
        let store = SessionStore(directory: tmp())
        let controller = SessionController(
            them: FakeAudioSource(script: [(0, 0.5)]), you: FakeAudioSource(script: [(0, 0.25)]),
            stt: FakeSTTProvider(scripts: [:]), store: store)
        let updates = await controller.levelUpdates()
        try await controller.start(locale: Locale(identifier: "en-US"))
        let live = await updates.first { abs($0.them - 0.5) < 0.001 && abs($0.you - 0.25) < 0.001 }
        XCTAssertNotNil(live, "meters never reached the buffer levels")
        try await controller.stop()
        let zeroed = await updates.first { $0 == Levels() }
        XCTAssertEqual(zeroed, Levels(), "meters did not fall to zero on stop")
    }

    func testEmptyTranscriptWritesNoFileButClearsLock() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let c = SessionController(them: FakeAudioSource(script: []), you: FakeAudioSource(script: []), stt: FakeSTTProvider(scripts: [:]), store: store)
        try await c.start(locale: Locale(identifier: "en-US"))
        let record = try await c.stop()
        XCTAssertNil(record)
        XCTAssertFalse(store.hasRunningLock)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // R10 seam: a failing prepare starts no capture and leaves no lock.
    func testPrepareFailureStartsNothing() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let them = FakeAudioSource(script: []), you = FakeAudioSource(script: [])
        let c = SessionController(them: them, you: you, stt: FakeSTTProvider(scripts: [:], prepareError: UserFacingError("no model")), store: store)
        do { try await c.start(locale: Locale(identifier: "en-US")); XCTFail("should throw") }
        catch { XCTAssertEqual(UserError.message(for: error, action: "start"), "no model") }
        XCTAssertEqual(them.startCount, 0); XCTAssertEqual(you.startCount, 0)
        XCTAssertFalse(store.hasRunningLock)
        let running = await c.isRunning
        XCTAssertFalse(running)
    }

    func testSecondSourceFailureStopsFirstAndClearsLock() async {
        let store = SessionStore(directory: tmp())
        let them = FakeAudioSource(script: [])
        let c = SessionController(them: them, you: FakeAudioSource(script: [], failOnStart: true), stt: FakeSTTProvider(scripts: [:]), store: store)
        do { try await c.start(locale: Locale(identifier: "en-US")); XCTFail("should throw") }
        catch { XCTAssertTrue(error is FakeAudioSource.Failure) }
        XCTAssertEqual(them.stopCount, 1)
        XCTAssertFalse(store.hasRunningLock)
    }

    func testStartWhileRunningIsRejected() async throws {
        let c = SessionController(them: FakeAudioSource(script: []), you: FakeAudioSource(script: []), stt: FakeSTTProvider(scripts: [:]), store: SessionStore(directory: tmp()))
        try await c.start(locale: Locale(identifier: "en-US"))
        do { try await c.start(locale: Locale(identifier: "en-US")); XCTFail("should throw") }
        catch { XCTAssertEqual(UserError.message(for: error, action: "start"), "A session is already running.") }
        let stillRunning = await c.isRunning
        XCTAssertTrue(stillRunning)
        try await c.stop()
    }

    // MARK: store (A21 atomicity, A22 recovery)

    func testFailedWriteLeavesNoPartialFile() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let record = SessionRecord(id: UUID(), startedAt: Date(), segments: [seg(.you, "x", 0, final: true)])
        try FileManager.default.createDirectory(at: store.fileURL(for: record.id), withIntermediateDirectories: true)  // target is a directory: write must fail
        XCTAssertThrowsError(try store.write(record))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["\(record.id.uuidString).json"])
        XCTAssertNil(store.read(record.id))
    }

    func testLeftoverLockOffersInterruptedTranscript() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        let record = SessionRecord(id: UUID(), startedAt: Date(), segments: [seg(.them, "hello", 0, final: true)])
        try a.begin(record.id); try a.write(record)               // no end(): simulates kill -9
        let check = SessionStore(directory: dir).launchCheck()
        XCTAssertEqual(check.interrupted, record)
        XCTAssertFalse(a.hasRunningLock)                          // cleared once offered
        XCTAssertNotNil(a.read(record.id))                        // non-destructive
        XCTAssertNil(SessionStore(directory: dir).launchCheck().interrupted)
    }

    func testCleanStartHasNothingToRecover() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        try a.begin(UUID()); a.end()
        XCTAssertEqual(SessionStore(directory: dir).launchCheck(), SessionStore.LaunchCheck(interrupted: nil, quarantined: []))
    }

    func testCorruptSessionFileIsQuarantinedNotDeleted() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir)
        let id = UUID()
        try a.begin(id)
        try Data("{ not json".utf8).write(to: a.fileURL(for: id))
        let check = SessionStore(directory: dir).launchCheck()
        XCTAssertNil(check.interrupted)
        XCTAssertEqual(check.quarantined, ["\(id.uuidString).json.corrupt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL(for: id).appendingPathExtension("corrupt").path))
        XCTAssertFalse(a.hasRunningLock)
    }

    func testCheckpointOnFinalSurvivesUncleanExit() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let stt = FakeSTTProvider(scripts: [.them: [seg(.them, "saved", 0, final: true)]])
        let c = SessionController(them: FakeAudioSource(script: [(0, 0.1)]), you: FakeAudioSource(script: []), stt: stt, store: store)
        let id = try await c.start(locale: Locale(identifier: "en-US"))
        var waited = 0
        while store.read(id) == nil && waited < 500 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }  // no stop(): crash
        XCTAssertNotNil(store.read(id), "checkpoint was never written")
        XCTAssertEqual(SessionStore(directory: dir).launchCheck().interrupted?.segments.map(\.text), ["saved"])
        try await c.stop()
    }
}

final class SpeechRestartTests: XCTestCase {
    private struct Boom: Error {}
    private let locale = Locale(identifier: "en-US")
    private func seg(_ s: Speaker, _ t: String, _ start: Double) -> Segment {
        Segment(speaker: s, text: t, start: start, end: start + 1, locale: "en-US", confidence: 0.9, isFinal: true)
    }
    private func store() -> SessionStore { SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)")) }
    private func script(_ n: Int, value: Float = 0.5) -> [(offset: TimeInterval, value: Float)] { (0..<n).map { (Double($0) * 0.05 + 0.05, value) } }

    /// Runs a session until `them` has delivered all its text or the deadline passes, returns the saved record and the notices.
    private func runSession(stt: FakeSTTProvider, themBuffers: Int = 8, wait: @Sendable () -> Bool) async throws -> (SessionRecord?, [String]) {
        let c = SessionController(them: FakeAudioSource(script: script(themBuffers), pace: 0.02), you: FakeAudioSource(script: script(3, value: 0.25), pace: 0.02), stt: stt, store: store())
        let notices = await c.notices()
        let collected = Task { var out: [String] = []; for await n in notices { out.append(n) }; return out }
        try await c.start(locale: locale)
        for _ in 0..<200 where !wait() { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let record = try await c.stop()
        collected.cancel()
        return (record, await collected.value)
    }

    func testClassifierTable() {
        XCTAssertTrue(STTFailure.isRecoverable(NSError(domain: "SFSpeechErrorDomain", code: 17)))
        XCTAssertTrue(STTFailure.isRecoverable(Boom()))
        XCTAssertFalse(STTFailure.isRecoverable(UserFacingError("Speech recognition can't read this audio.")))
        XCTAssertFalse(STTFailure.isRecoverable(CancellationError()))
        XCTAssertFalse(STTFailure.isRecoverable(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
    }

    // N <= 3 failures: recovers, earlier finals kept without duplicates, no notice, audio reaches the new analyzers.
    func testRecoversFromUpToThreeFailuresSilently() async throws {
        for n in 1...3 {
            let words = ["a", "b", "c", "d", "e"].map { seg(.them, $0, 0) }
            let fails: [(afterSegments: Int, error: Error)?] = Array(repeating: (1, Boom() as Error), count: n)
            let stt = FakeSTTProvider(scripts: [.them: words], callFailures: [.them: fails])
            let (record, notices) = try await runSession(stt: stt) { stt.transcribeCalls(.them) > n && stt.buffersReceived(.them) >= 8 }
            XCTAssertEqual(notices, [], "n=\(n)")
            XCTAssertEqual(record?.segments.filter { $0.speaker == .them }.map(\.text), ["a", "b", "c", "d", "e"], "n=\(n)")
            XCTAssertEqual(stt.transcribeCalls(.them), n + 1, "n=\(n)")
            XCTAssertEqual(stt.buffersReceived(.them), 8, "no buffer lost across \(n) restarts")
        }
    }

    // A budget reset after a successful segment: 3 failures, a working stretch, then 3 more failures still recover.
    func testRetryBudgetResetsAfterASegment() async throws {
        let words = (0..<8).map { seg(.them, "w\($0)", Double($0)) }
        let f: (afterSegments: Int, error: Error)? = (1, Boom())
        let stt = FakeSTTProvider(scripts: [.them: words], callFailures: [.them: [f, f, f, f, f, f]])
        let (record, notices) = try await runSession(stt: stt, themBuffers: 10) { stt.buffersReceived(.them) >= 10 }
        XCTAssertEqual(notices, [])
        XCTAssertEqual(record?.segments.filter { $0.speaker == .them }.map(\.text), (0..<8).map { "w\($0)" })
    }

    // 4 consecutive failures (3 restarts all failing): exactly one notice, the other stream is unaffected.
    func testFourthConsecutiveFailureShowsOneNotice() async throws {
        let f: (afterSegments: Int, error: Error)? = (0, Boom())
        let stt = FakeSTTProvider(scripts: [.them: [], .you: [seg(.you, "hi", 0)]], callFailures: [.them: [f, f, f, f, f]])
        let (record, notices) = try await runSession(stt: stt) { stt.transcribeCalls(.them) >= 4 && stt.buffersReceived(.you) >= 1 }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("Them") == true)
        XCTAssertEqual(stt.transcribeCalls(.them), 4)
        XCTAssertEqual(record?.segments.map(\.text), ["hi"])
    }

    func testNonRecoverableErrorNoticesWithoutRetry() async throws {
        let stt = FakeSTTProvider(scripts: [.them: []], callFailures: [.them: [(0, UserFacingError("Unsupported."))]])
        let (_, notices) = try await runSession(stt: stt) { stt.transcribeCalls(.them) >= 1 }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(stt.transcribeCalls(.them), 1)
    }

    // Partial results are not "successful segments": a stream that only ever yields partials runs out of budget,
    // and each restart keeps the dead stream's partial as a final instead of letting the next result replace it.
    func testPartialsDoNotResetBudgetAndAreKeptOnRestart() async throws {
        let partials = (0..<6).map { Segment(speaker: .them, text: "p\($0)", start: Double($0), end: Double($0) + 1, locale: "en-US", confidence: 0.5, isFinal: false) }
        let f: (afterSegments: Int, error: Error)? = (1, Boom())
        let stt = FakeSTTProvider(scripts: [.them: partials], callFailures: [.them: [f, f, f, f, f, f]])
        let (record, notices) = try await runSession(stt: stt, themBuffers: 10) { stt.transcribeCalls(.them) >= 4 }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(stt.transcribeCalls(.them), 4)
        XCTAssertEqual(record?.segments.filter { $0.speaker == .them }.map(\.text), ["p0", "p1", "p2", "p3"])
    }
}
