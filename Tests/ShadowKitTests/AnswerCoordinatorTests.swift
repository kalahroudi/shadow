import XCTest
@testable import ShadowKit

/// A clock that only moves when a test says so.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [(deadline: Instant, cont: CheckedContinuation<Void, Error>, id: Int)] = []
    private var nextID = 0
    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= _now { lock.unlock(); c.resume(); return }
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                sleepers.append((deadline, c, id)); lock.unlock()
            }
        } onCancel: {
            let hit = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: i).cont
            }
            hit?.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _now = _now.advanced(by: d)
            let ready = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return ready.map(\.cont)
        }
        due.forEach { $0.resume() }
    }
}

@MainActor
final class AnswerCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var running = true, auto = false
    private var persona = Persona.default
    private var turnsList: [Segment] = []
    private var logs: [String] = []
    private let clock = ManualClock()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "answer-\(UUID().uuidString)")
        running = true; auto = false; persona = Persona.default; turnsList = []; logs = []
    }

    private func seg(_ s: Speaker, _ t: String, start: TimeInterval = 0, final: Bool = true) -> Segment {
        Segment(speaker: s, text: t, start: start, end: start + 1, isFinal: final)
    }

    private func make(_ providers: @escaping @MainActor () -> any LLMProvider, cap: Int = AnswerCoordinator.maxAnswerCharacters) -> AnswerCoordinator {
        AnswerCoordinator(settings: LLMSettings(defaults: defaults), makeProvider: { _ in providers() },
                          persona: { self.persona }, language: { .auto }, turns: { self.turnsList },
                          isSessionRunning: { self.running }, autoSuggest: { self.auto }, clock: clock,
                          debounce: .seconds(1), maxCharacters: cap, log: { self.logs.append($0) })
    }

    private func make(_ p: FakeLLMProvider, cap: Int = AnswerCoordinator.maxAnswerCharacters) -> AnswerCoordinator { make({ p }, cap: cap) }

    private func poll(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func assertEventually(_ condition: @MainActor () -> Bool, line: UInt = #line) async {
        let ok = await poll(condition)
        XCTAssertTrue(ok, line: line)
    }

    private func text(_ c: AnswerCoordinator) -> String? { if case .answering(let a) = c.state { a.text } else { nil } }
    private func done(_ c: AnswerCoordinator) async {
        _ = await poll { switch c.state { case .answering(let a): !a.isStreaming; case .idle: false; default: true } }
    }
    private func snapshot(_ finals: [Segment], partials: [Speaker: Segment] = [:]) -> TranscriptSnapshot {
        var s = TranscriptSnapshot(); s.finals = finals; s.partials = partials; return s
    }
    /// Lets the debounce task reach its sleep.
    private func settle(_ c: ManualClock, sleepers n: Int) async { _ = await poll { c.sleeperCount == n } }

    // MARK: Answer now (A7)

    func testAnswerNowUsesLatestQuestionElseLatestThemTurn() async {
        let p = FakeLLMProvider(deltas: ["Hi", " there"])
        let c = make(p)
        turnsList = [seg(.them, "What is your biggest weakness?", start: 1), seg(.them, "Take your time.", start: 2), seg(.you, "Hmm.", start: 3)]
        XCTAssertEqual(c.answerNow(), .started)
        await done(c)
        XCTAssertEqual(text(c), "Hi there")
        XCTAssertTrue(p.requests[0].user.hasSuffix("Question to answer: What is your biggest weakness?"))

        turnsList = [seg(.them, "We ship on Friday.", start: 1), seg(.you, "ok", start: 2)]
        XCTAssertEqual(c.answerNow(), .started)
        await done(c)
        XCTAssertTrue(p.requests[1].user.hasSuffix("Question to answer: We ship on Friday."))
    }

    func testAnswerNowDoesNothingWithoutSessionOrTurns() async {
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        turnsList = [seg(.them, "Why?")]
        running = false
        XCTAssertEqual(c.answerNow(), .noSession)
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(p.requests.isEmpty)
        running = true; turnsList = [seg(.you, "only me")]
        XCTAssertEqual(c.answerNow(), .nothingToAnswer)
        XCTAssertTrue(p.requests.isEmpty)
    }

    func testRequestUsesActivePersonaPrompt() async {
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        turnsList = [seg(.them, "Why?")]
        persona = Persona.builtIn(Persona.salesID)!
        c.answerNow(); await done(c)
        XCTAssertEqual(p.requests[0].personaID, Persona.salesID)
        XCTAssertTrue(p.requests[0].system.contains(Persona.builtIn(Persona.salesID)!.systemPrompt))
    }

    func testHotkeyDefaultAndConflict() {
        XCTAssertEqual(HotkeyMap.defaults[.answerNow]?.string, "cmd+shift+a")
        XCTAssertTrue(HotkeyAction.allCases.contains(.answerNow))
        XCTAssertEqual(HotkeyMap.defaults.values.count, Set(HotkeyMap.defaults.values).count, "default shortcuts must not conflict")
        if case .success = HotkeyMap.defaults.binding(.answerNow, to: "cmd+shift+h") { XCTFail("conflict accepted") }
        if case .failure = HotkeyMap.defaults.binding(.answerNow, to: "cmd+shift+j") { XCTFail("free binding rejected") }
    }

    // MARK: Meeting notes (A16)

    func testMeetingNotesNeverAutoAnswersAndAnswerNowDeclines() async {
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        persona = Persona.builtIn(Persona.meetingNotesID)!
        auto = true
        let q = [seg(.them, "What do you think?", start: 1)]
        turnsList = q
        c.transcriptChanged(snapshot(q))
        XCTAssertEqual(clock.sleeperCount, 0)
        clock.advance(by: .seconds(5))
        XCTAssertEqual(c.answerNow(), .declined)
        guard case .declined(let msg, let to) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertTrue(msg.contains("doesn't suggest answers"))
        XCTAssertEqual(to, Persona.interviewID)
        XCTAssertTrue(p.requests.isEmpty)
    }

    // MARK: Auto-suggest (A8)

    func testAutoSuggestOffNeverAnswers() async {
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        let q = [seg(.them, "What is your biggest weakness?", start: 1)]
        turnsList = q
        c.transcriptChanged(snapshot(q))
        clock.advance(by: .seconds(10))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(p.requests.isEmpty)
        XCTAssertEqual(c.state, .idle)
    }

    func testAutoSuggestAnswersQuestionAfterDebounce() async {
        auto = true
        let p = FakeLLMProvider(deltas: ["Answer"])
        let c = make(p)
        let q = [seg(.them, "What is your biggest weakness?", start: 1)]
        turnsList = q
        c.transcriptChanged(snapshot(q))
        await settle(clock, sleepers: 1)
        clock.advance(by: .milliseconds(900))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(p.requests.isEmpty, "not before the debounce")
        clock.advance(by: .milliseconds(200))
        await done(c)
        XCTAssertEqual(text(c), "Answer")
        // The same turn is not answered twice.
        c.transcriptChanged(snapshot(q, partials: [.you: seg(.you, "uh", final: false)]))
        XCTAssertEqual(clock.sleeperCount, 0)
        XCTAssertEqual(p.requests.count, 1)
    }

    func testNewSpeechRestartsDebounce() async {
        auto = true
        let p = FakeLLMProvider(deltas: ["A"])
        let c = make(p)
        let q = [seg(.them, "Can you walk me through it?", start: 1)]
        turnsList = q
        c.transcriptChanged(snapshot(q))
        await settle(clock, sleepers: 1)
        clock.advance(by: .milliseconds(800))
        // The turn continues: a Them partial cancels the wait.
        c.transcriptChanged(snapshot(q, partials: [.them: seg(.them, "and also", start: 2, final: false)]))
        await settle(clock, sleepers: 0)
        clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(p.requests.isEmpty)
        // It ends in a question again: a fresh full debounce starts.
        let q2 = q + [seg(.them, "and also how long did it take?", start: 2)]
        turnsList = q2
        c.transcriptChanged(snapshot(q2))
        await settle(clock, sleepers: 1)
        clock.advance(by: .milliseconds(900))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(p.requests.isEmpty)
        clock.advance(by: .milliseconds(200))
        await done(c)
        XCTAssertEqual(p.requests.count, 1)
        XCTAssertTrue(p.requests[0].user.contains("how long did it take"))
    }

    func testStatementDoesNotTrigger() async {
        auto = true
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        let s = [seg(.them, "We shipped the release yesterday.", start: 1)]
        turnsList = s
        c.transcriptChanged(snapshot(s))
        XCTAssertEqual(clock.sleeperCount, 0)
        XCTAssertTrue(p.requests.isEmpty)
    }

    func testSessionStopCancelsPendingDebounce() async {
        auto = true
        let c = make(FakeLLMProvider(deltas: ["x"]))
        let q = [seg(.them, "Why?", start: 1)]
        turnsList = q
        c.transcriptChanged(snapshot(q))
        await settle(clock, sleepers: 1)
        c.sessionStopped()
        await settle(clock, sleepers: 0)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    // MARK: One at a time (A10)

    func testSecondTriggerCancelsFirstAndKeepsOnlySecondText() async {
        let first = FakeLLMProvider(id: "a", deltas: ["old1", "old2", "old3"], delayBetween: .milliseconds(200))
        let second = FakeLLMProvider(id: "b", deltas: ["new"])
        var n = 0
        let c = make { n += 1; return n == 1 ? first : second }
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        try? await Task.sleep(for: .milliseconds(50))
        c.answerNow()
        await done(c)
        XCTAssertEqual(text(c), "new")
        await assertEventually { first.cancelCount == 1 }
    }

    func testStoppingSessionCancelsStream() async {
        let p = FakeLLMProvider(deltas: ["a", "b", "c"], delayBetween: .milliseconds(200))
        let c = make(p)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        try? await Task.sleep(for: .milliseconds(50))
        c.sessionStopped()
        XCTAssertEqual(c.state, .idle)
        await assertEventually { p.cancelCount == 1 }
    }

    func testStopKeepsPartialText() async {
        let p = FakeLLMProvider(deltas: ["one ", "two ", "three"], delayBetween: .milliseconds(100))
        let c = make(p)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        await assertEventually { self.text(c)?.isEmpty == false }
        c.stop()
        guard case .answering(let a) = c.state else { return XCTFail() }
        XCTAssertFalse(a.isStreaming)
        XCTAssertFalse(a.text.isEmpty)
        let kept = a.text
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(text(c), kept)
        await assertEventually { p.cancelCount == 1 }
    }

    // MARK: Failure, retry, Local-only, cap, logs

    func testFailureShowsOneLineAndRetryReissuesSameRequest() async {
        let p = FakeLLMProvider(deltas: [], failure: LLMError(.rateLimited))
        let c = make(p)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        await assertEventually { if case .failed = c.state { true } else { false } }
        guard case .failed(let msg, _) = c.state else { return }
        XCTAssertEqual(msg, LLMError(.rateLimited).message)
        XCTAssertFalse(msg.contains("\n"))
        turnsList = [seg(.them, "Something else entirely?")]   // Retry must not re-read the transcript
        XCTAssertEqual(c.reissue(), .started)
        _ = await poll { p.requests.count == 2 }
        XCTAssertEqual(p.requests[0], p.requests[1])
    }

    func testLocalOnlyOnCancelsCloudStreamAndReselectsLocal() async {
        let p = FakeLLMProvider(id: "anthropic", isCloud: true, deltas: ["a", "b", "c"], delayBetween: .milliseconds(200))
        let c = make(p)
        let s = LLMSettings(defaults: defaults)
        XCTAssertTrue(s.select("anthropic").isSuccess)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        try? await Task.sleep(for: .milliseconds(50))
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        c.localOnlyChanged(to: true)
        XCTAssertEqual(s.selectedProviderID, LLMSettings.fallbackProviderID)
        guard case .failed(let msg, _) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertEqual(msg, LocalOnlyPolicy.message)
        await assertEventually { p.cancelCount == 1 }
    }

    func testCloudProviderRefusedWhileLocalOnly() async {
        let p = FakeLLMProvider(id: "anthropic", isCloud: true, deltas: ["x"])
        let c = make(p)
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        XCTAssertTrue(p.requests.isEmpty, "a cloud provider is never called while Local-only is on")
        guard case .failed(let msg, _) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertEqual(msg, LocalOnlyPolicy.message)
    }

    func testAnswerLengthIsCapped() async {
        let p = FakeLLMProvider(deltas: Array(repeating: "0123456789", count: 50))
        let c = make(p, cap: 100)
        turnsList = [seg(.them, "Why?")]
        c.answerNow()
        _ = await poll { if case .answering(let a) = c.state { a.truncated } else { false } }
        guard case .answering(let a) = c.state else { return XCTFail() }
        XCTAssertEqual(a.text.count, 100)
        XCTAssertTrue(a.truncated)
    }

    func testLogsHoldNoPromptOrAnswerText() async {
        let p = FakeLLMProvider(deltas: ["SECRETANSWERTEXT"], failure: nil)
        let c = make(p)
        turnsList = [seg(.them, "SECRETQUESTIONTEXT why?")]
        c.answerNow(); await done(c)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("provider=\(LLMSettings.fallbackProviderID)"))
        XCTAssertTrue(logs[0].contains("latencyMs="))
        XCTAssertFalse(logs.joined().contains("SECRET"))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
