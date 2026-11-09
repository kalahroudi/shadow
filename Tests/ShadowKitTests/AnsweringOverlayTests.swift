import XCTest
@testable import ShadowKit

final class MarkdownAndHistoryTests: XCTestCase {
    func testMarkdownBlocks() {
        let blocks = MarkdownParser.parse("Intro **bold** and `code`.\n\n- one\n* two **b**\n\n```swift\nlet x = 1\n```\nDone")
        XCTAssertEqual(blocks, [
            .paragraph([.text("Intro "), .bold("bold"), .text(" and "), .code("code"), .text(".")]),
            .bullet([.text("one")]),
            .bullet([.text("two "), .bold("b")]),
            .code(language: "swift", text: "let x = 1", isClosed: true),
            .paragraph([.text("Done")]),
        ])
    }

    func testUnterminatedFenceAndMarkupWhileStreaming() {
        XCTAssertEqual(MarkdownParser.parse("Here:\n```py\nprint(1)\nprint("),
                       [.paragraph([.text("Here:")]), .code(language: "py", text: "print(1)\nprint(", isClosed: false)])
        XCTAssertEqual(MarkdownParser.inlines("half **bold and `code"), [.text("half **bold and `code")])
        XCTAssertEqual(MarkdownParser.inlines("a ** b"), [.text("a ** b")])
        XCTAssertEqual(MarkdownParser.parse(""), [])
    }

    private func rec(_ n: Int) -> AnswerRecord { AnswerRecord(question: "q\(n)", text: "a\(n)", persona: "interview", provider: "p", model: "m") }

    func testHistoryBoundsAndAppendAfterNavigation() {
        var h = AnswerHistory()
        XCTAssertFalse(h.canBack); XCTAssertFalse(h.canForward); XCTAssertNil(h.back()); XCTAssertNil(h.forward())
        h.append(rec(1)); h.append(rec(2)); h.append(rec(3))
        XCTAssertEqual(h.position, "3 / 3")
        XCTAssertFalse(h.canForward)
        XCTAssertEqual(h.back()?.question, "q2"); XCTAssertEqual(h.back()?.question, "q1")
        XCTAssertNil(h.back()); XCTAssertFalse(h.canBack)
        XCTAssertEqual(h.forward()?.question, "q2")
        h.append(rec(4))   // a new answer goes to the end, not after the cursor
        XCTAssertEqual(h.records.map(\.question), ["q1", "q2", "q3", "q4"])
        XCTAssertEqual(h.position, "4 / 4")
        h.detach()          // a new answer or an error on screen: back goes to the newest record
        XCTAssertEqual(h.back()?.question, "q4")
    }

    func testChipInstructions() {
        XCTAssertTrue(FollowUpChip.addMetric.instruction(personaID: Persona.interviewID).contains("concrete metric"))
        XCTAssertEqual(FollowUpChip.addMetric.instruction(personaID: Persona.salesID), "Rewrite your previous answer to be more specific.")
        XCTAssertTrue(FollowUpChip.language(.german).instruction(personaID: "x").contains("Deutsch"))
        XCTAssertEqual(FollowUpChip.language(.french).title, "Say it in Français")
        XCTAssertEqual(FollowUpChip.languageChips.count, Language.allCases.count - 1)
        XCTAssertFalse(FollowUpChip.languageChips.contains(.language(.auto)))
    }

    func testOverlayStateTransitions() {
        let a = AnswerState.answering(Answer(question: "q", provider: "p", model: "", isCloud: false))
        XCTAssertEqual(OverlayState.from(sessionRunning: false, answer: a), .idle)
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: .idle), .listening)
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: a), .answering)
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: .declined("m", switchTo: "x")), .answering)
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: .failed("m", partial: nil)), .error)
        XCTAssertEqual(OverlayState.from(sessionRunning: true), .listening)
    }

    func testCopyAnswerHotkeyIsBoundAndRebindable() {
        XCTAssertEqual(HotkeyMap.defaults[.copyAnswer]?.string, "cmd+shift+c")
        XCTAssertEqual(HotkeyMap.defaults.values.count, Set(HotkeyMap.defaults.values).count)
        if case .success = HotkeyMap.defaults.binding(.copyAnswer, to: "cmd+shift+a") { XCTFail("conflict accepted") }
    }
}

@MainActor
final class AnsweringOverlayCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var running = true
    private var persona = Persona.default
    private var turnsList: [Segment] = []
    private var records: [AnswerRecord] = []
    private var copyable: [Bool] = []

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "overlay-\(UUID().uuidString)")
        running = true; persona = Persona.default; records = []; copyable = []
        turnsList = [Segment(speaker: .them, text: "Tell me about a hard bug?", start: 1, end: 2, isFinal: true)]
    }

    private func make(_ p: FakeLLMProvider) -> AnswerCoordinator {
        let c = AnswerCoordinator(settings: LLMSettings(defaults: defaults), makeProvider: { _ in p },
                                  persona: { self.persona }, language: { .auto }, turns: { self.turnsList },
                                  isSessionRunning: { self.running }, autoSuggest: { false }, log: { _ in })
        c.onRecord = { self.records.append($0) }
        c.onCopyableChange = { self.copyable.append($0) }
        return c
    }

    private func poll(_ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(2)
        while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
    private func done(_ c: AnswerCoordinator) async {
        _ = await poll { if case .answering(let a) = c.state { !a.isStreaming } else { true } }
    }
    private func text(_ c: AnswerCoordinator) -> String? { if case .answering(let a) = c.state { a.text } else { nil } }

    func testCopyPutsFullTextOnPasteboardClosure() async {
        let c = make(FakeLLMProvider(deltas: ["Full ", "**answer**"]))
        var out: [String] = []
        XCTAssertFalse(c.copy { out.append($0) })
        c.answerNow(); await done(c)
        XCTAssertTrue(c.copy { out.append($0) })
        XCTAssertEqual(out, ["Full **answer**"])
    }

    func testCopyableFlagFlipsOnceForHotkeyRegistration() async {
        let c = make(FakeLLMProvider(deltas: ["a", "b"]))
        c.answerNow(); await done(c)
        XCTAssertEqual(copyable, [true])
        c.sessionStopped()
        XCTAssertEqual(copyable, [true, false])
    }

    func testRegenerateReissuesSameRequestAndHistoryGrows() async {
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        c.answerNow(); await done(c)
        c.reissue(); await done(c)
        XCTAssertEqual(p.requests.count, 2)
        XCTAssertEqual(p.requests[0], p.requests[1])
        XCTAssertEqual(c.history.records.count, 2)
        XCTAssertEqual(records.count, 2)
    }

    func testStopKeepsPartialAndRecordsIt() async {
        let p = FakeLLMProvider(deltas: ["one ", "two ", "three"], delayBetween: .milliseconds(150))
        let c = make(p)
        c.answerNow()
        _ = await poll { (self.text(c) ?? "").contains("one") }
        c.stop()
        let kept = text(c)
        XCTAssertEqual(kept?.hasPrefix("one"), true)
        XCTAssertEqual(c.isStreaming, false)
        XCTAssertEqual(p.cancelCount, 1)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(text(c), kept, "nothing more arrives after Stop")
        XCTAssertEqual(records.map(\.text), [kept])
    }

    func testRetryReissuesTheSameRequestAfterFailure() async {
        let p = FakeLLMProvider(deltas: [], failure: LLMError(.offline))
        let c = make(p)
        c.answerNow()
        _ = await poll { if case .failed = c.state { true } else { false } }
        guard case .failed(let message, _) = c.state else { return XCTFail("expected failure") }
        XCTAssertEqual(message, LLMError(.offline).message)
        XCTAssertFalse(message.contains("\n"))
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: c.state), .error)
        c.reissue()
        _ = await poll { p.requests.count == 2 }
        XCTAssertEqual(p.requests[0], p.requests[1])
    }

    func testChipsBuildFollowUpOnSameContextAndLandInHistory() async {
        let p = FakeLLMProvider(deltas: ["First answer"])
        let c = make(p)
        XCTAssertEqual(c.chip(.shorter), .nothingToAnswer)   // nothing to follow up on yet
        c.answerNow(); await done(c)
        XCTAssertTrue(c.canFollowUp)

        XCTAssertEqual(c.chip(.addMetric), .started); await done(c)
        let r = p.requests[1]
        XCTAssertTrue(r.user.hasPrefix(p.requests[0].user), "same context")
        XCTAssertTrue(r.user.contains("Your previous answer:\nFirst answer"))
        XCTAssertTrue(r.user.contains("concrete metric"))
        XCTAssertEqual(r.system, p.requests[0].system)
        XCTAssertEqual(records.last?.kind, "metric")

        // a second chip builds on the original context, not on the first chip's prompt
        c.chip(.language(.spanish)); await done(c)
        XCTAssertEqual(p.requests[2].user.components(separatedBy: "Follow-up instruction:").count, 2)
        XCTAssertTrue(p.requests[2].user.contains("Español"))
        XCTAssertEqual(records.map(\.kind), ["answer", "metric", "language"])
    }

    func testMetricChipIsGenericUnderOtherPersonas() async {
        persona = Persona.builtIn(Persona.salesID)!
        let p = FakeLLMProvider(deltas: ["ok"])
        let c = make(p)
        c.answerNow(); await done(c)
        c.chip(.addMetric); await done(c)
        XCTAssertTrue(p.requests[1].user.contains("more specific"))
        XCTAssertFalse(p.requests[1].user.contains("concrete metric"))
    }

    func testHistoryNavigationShowsRecordsAndBlocksChipsOnOldOnes() async {
        let p = FakeLLMProvider(deltas: ["A"])
        let c = make(p)
        c.answerNow(); await done(c)
        c.reissue(); await done(c)
        XCTAssertTrue(c.canGoBack); XCTAssertFalse(c.canGoForward)
        c.goBack()
        XCTAssertEqual(c.history.position, "1 / 2")
        XCTAssertFalse(c.canFollowUp); XCTAssertFalse(c.canRegenerate)   // both act on the newest request
        XCTAssertTrue(c.canGoForward); XCTAssertFalse(c.canGoBack)
        c.goForward()
        XCTAssertTrue(c.canFollowUp); XCTAssertTrue(c.canRegenerate)
        c.goBack(); c.reissue(); await done(c)   // new answer after navigating appends at the end
        XCTAssertEqual(c.history.records.count, 3)
        XCTAssertEqual(c.history.position, "3 / 3")
    }

    func testNavigationIsIgnoredWhileStreaming() async {
        let p = FakeLLMProvider(deltas: ["a", "b"], delayBetween: .milliseconds(200))
        let c = make(p)
        c.answerNow(); await done(c)
        c.reissue()
        XCTAssertTrue(c.isStreaming)
        XCTAssertFalse(c.canGoBack)
        c.goBack()
        XCTAssertTrue(c.isStreaming)
        c.stop()
    }

    func testMeetingNotesAnswerButtonOffersSwitch() {
        persona = Persona.builtIn(Persona.meetingNotesID)!
        let p = FakeLLMProvider(deltas: ["x"])
        let c = make(p)
        XCTAssertEqual(c.answerNow(), .declined)
        XCTAssertEqual(c.state.switchTarget, Persona.default.id)
        XCTAssertEqual(OverlayState.from(sessionRunning: true, answer: c.state), .answering)
        XCTAssertTrue(p.requests.isEmpty)
    }

    func testSessionRecordKeepsAnswerHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let controller = SessionController(
            them: FakeAudioSource(script: [(0.1, 0.5)]), you: FakeAudioSource(script: [(0.3, 0.25)]),
            stt: FakeSTTProvider(scripts: [.them: [Segment(speaker: .them, text: "why?", start: 0.1, end: 0.5, isFinal: true)], .you: []]),
            store: store)
        let id = try await controller.start(locale: Locale(identifier: "en-US"))
        let answer = AnswerRecord(question: "why?", text: "because", persona: "interview", provider: "on-device", model: "", kind: "shorter")
        await controller.addAnswer(answer)
        let saved = try await controller.stop()
        XCTAssertEqual(saved?.answers, [answer])
        XCTAssertEqual(store.read(id)?.answers, [answer])
    }
}
