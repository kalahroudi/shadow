import XCTest
@testable import ShadowKit

/// R1 / A1, R2 / A2, R24 retry.
final class LLMProviderTests: XCTestCase {
    func testDeltasArriveInOrder() async throws {
        let p = FakeLLMProvider(deltas: ["a", "b", "c"])
        let got = try await collect(p.stream(LLMRequest(system: "s", user: "u")))
        XCTAssertEqual(got, ["a", "b", "c"])
        XCTAssertEqual(p.requests.first?.user, "u")
        XCTAssertEqual(p.cancelCount, 0)
    }

    func testCancellingTheConsumerEndsTheStreamAndCallsTheCancelHook() async throws {
        let p = FakeLLMProvider(deltas: Array(repeating: "x", count: 1000), delayBetween: .milliseconds(5))
        let task = Task { try await collect(p.stream(LLMRequest(system: "s", user: "u"))) }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        _ = await task.result
        let called = await eventually { p.cancelCount == 1 }
        XCTAssertTrue(called)
    }

    func testStoppingEarlyAlsoCallsTheCancelHook() async throws {
        let p = FakeLLMProvider(deltas: Array(repeating: "x", count: 1000), delayBetween: .milliseconds(5))
        for try await _ in p.stream(LLMRequest(system: "s", user: "u")) { break }
        let called = await eventually { p.cancelCount == 1 }
        XCTAssertTrue(called)
    }

    func testProviderErrorsReachTheConsumerAfterTheDeltas() async {
        let p = FakeLLMProvider(deltas: ["a"], failure: LLMError(.rateLimited))
        var got: [String] = []
        do { for try await d in p.stream(LLMRequest(system: "s", user: "u")) { got.append(d) } }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .rateLimited) }
        XCTAssertEqual(got, ["a"])
    }

    func testRequestFromContextCarriesNoExtraFields() {
        let persona = Persona.default
        let ctx = ContextBuilder.build(persona: persona, language: .english, turns: [], question: "Why?")
        let r = LLMRequest(context: ctx, persona: persona, language: .english, model: "m")
        XCTAssertEqual(r.system, ctx.system); XCTAssertEqual(r.user, ctx.user)
        XCTAssertEqual(r.personaID, persona.id); XCTAssertEqual(r.model, "m")
    }

    // MARK: retry

    private actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }

    func testTransientErrorIsRetriedOnce() async throws {
        let c = Counter()
        let v: Int = try await LLMStream.withOneRetry { let n = await c.bump(); if n == 1 { throw LLMError(.offline) }; return n }
        XCTAssertEqual(v, 2)
    }

    func testSecondFailureIsNotRetriedAgain() async {
        let c = Counter()
        do { _ = try await LLMStream.withOneRetry { () -> Int in _ = await c.bump(); throw LLMError(.offline) }; XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .offline) }
        let n = await c.n
        XCTAssertEqual(n, 2)
    }

    func testBadKeyIsNotRetried() async {
        let c = Counter()
        do { _ = try await LLMStream.withOneRetry { () -> Int in _ = await c.bump(); throw LLMError(.badKey) }; XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .badKey) }
        let n = await c.n
        XCTAssertEqual(n, 1)
    }

    // MARK: on-device

    private struct FakeModel: OnDeviceModel {
        var state: AppleStatus
        var deltas: [String] = ["Hi", " there"]
        func status() -> AppleStatus { state }
        func respond(system: String, user: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in deltas.forEach { c.yield($0) }; c.finish() }
        }
    }

    func testEachAppleStateHasAMessageAndGuidance() {
        XCTAssertEqual(AppleStatus.ready.providerStatus, .ready)
        for s in [AppleStatus.deviceNotEligible, .appleIntelligenceOff, .modelNotReady] {
            XCTAssertFalse(s.message.isEmpty); XCTAssertFalse(s.guidance.isEmpty)
            XCTAssertEqual(s.providerStatus, .unavailable(s.message + " " + s.guidance))
        }
        XCTAssertEqual(Set([AppleStatus.deviceNotEligible, .appleIntelligenceOff, .modelNotReady].map(\.message)).count, 3)
        XCTAssertTrue(AppleStatus.appleIntelligenceOff.guidance.contains("System Settings"))
    }

    func testOnDeviceProviderReportsTheModelState() async {
        for s in [AppleStatus.ready, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady] {
            let status = await OnDeviceProvider(model: FakeModel(state: s)).availability()
            XCTAssertEqual(status, s.providerStatus)
        }
        XCTAssertFalse(OnDeviceProvider(model: FakeModel(state: .ready)).isCloud)
    }

    func testOnDeviceProviderStreamsWhenReadyAndRefusesWhenNot() async throws {
        let ok = try await collect(OnDeviceProvider(model: FakeModel(state: .ready)).stream(LLMRequest(system: "s", user: "u")))
        XCTAssertEqual(ok, ["Hi", " there"])
        do { _ = try await collect(OnDeviceProvider(model: FakeModel(state: .appleIntelligenceOff)).stream(LLMRequest(system: "s", user: "u"))); XCTFail() }
        catch { XCTAssertEqual(UserError.message(for: error, action: "answer"), AppleStatus.appleIntelligenceOff.message + " " + AppleStatus.appleIntelligenceOff.guidance) }
    }

    func testCumulativeSnapshotsBecomeDeltas() {
        var c = CumulativeDelta()
        XCTAssertEqual(c.delta(from: "He"), "He")
        XCTAssertEqual(c.delta(from: "Hello"), "llo")
        XCTAssertEqual(c.delta(from: "Hello"), "")
        XCTAssertEqual(c.delta(from: "Hello world"), " world")
        XCTAssertEqual(c.delta(from: "Rewritten"), "")   // earlier text can't be taken back
    }

    func testOnDeviceErrorsMapWithoutCopyingTheirText() {
        let secretPrompt = "my secret prompt"
        let e = OnDeviceErrorMapper.map("guardrailViolation(Context(debugDescription: \"\(secretPrompt)\"))")
        XCTAssertEqual(e.kind, .contentFiltered)
        XCTAssertFalse(e.detail.contains(secretPrompt))
        XCTAssertEqual(OnDeviceErrorMapper.map("rateLimited(...)").kind, .rateLimited)
        XCTAssertEqual(OnDeviceErrorMapper.map("something else").kind, .unavailable)
    }
}
