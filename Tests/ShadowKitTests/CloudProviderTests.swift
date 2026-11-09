import XCTest
@testable import ShadowKit

/// R5, R6, R24 / A5, A6, A24.
final class CloudProviderTests: XCTestCase {
    private let secret = FakeKeys.anthropic
    private let req = LLMRequest(system: "SYS", user: "USER")

    private func store(_ kind: CloudKind, key: String? = nil) throws -> InMemorySecretStore {
        let s = InMemorySecretStore()
        try s.saveKey(key ?? secret, for: kind)
        return s
    }

    static func ev(_ json: String) -> String { "data: \(json)\n\n" }
    static let anthropicSSE = "event: message_start\n" + ev(#"{"type":"message_start","message":{"id":"m","content":[]}}"#)
        + ev(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        + "event: ping\n" + ev(#"{"type":"ping"}"#)
        + ev(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Lead with "}}"#)
        + ev(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"**impact**."}}"#)
        + ev(#"{"type":"content_block_stop","index":0}"#)
        + ev(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#)
        + ev(#"{"type":"message_stop"}"#)
    static let anthropicText = ["Lead with ", "**impact**."]
    static let geminiSSE = ev(#"{"candidates":[{"content":{"parts":[{"text":"Hi "}],"role":"model"},"index":0}]}"#)
        + ev(#"{"candidates":[{"content":{"parts":[{"text":"there"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"totalTokenCount":9}}"#)

    func testAnthropicStreamsAndBuildsRequest() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.anthropicSSE)])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic))
        let got = try await collect(p.stream(LLMRequest(system: "SYS", user: "USER", model: "claude-haiku-5-5")))
        XCTAssertEqual(got, Self.anthropicText)
        let r = try XCTUnwrap(t.streamRequests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), secret)
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(r.timeoutInterval, CloudProvider.requestTimeout)
        XCTAssertFalse(r.url!.absoluteString.contains(secret))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5"); XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["tools"])
        XCTAssertFalse(String(decoding: r.httpBody!, as: UTF8.self).contains(secret), "the key must never be in the body")
    }

    func testOpenAIStreamsFixtureWithBearerKey() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(LLMFixtures.openAISSE)])
        let p = CloudProvider(kind: .openAI, transport: t, secrets: try store(.openAI, key: FakeKeys.openAI))
        let got = try await collect(p.stream(req))
        XCTAssertEqual(got, LLMFixtures.openAIText)
        let r = try XCTUnwrap(t.streamRequests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(FakeKeys.openAI)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, CloudKind.openAI.defaultModel)
    }

    func testGeminiStreamsFixtureWithHeaderKey() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.geminiSSE)])
        let key = FakeKeys.gemini
        let p = CloudProvider(kind: .gemini, transport: t, secrets: try store(.gemini, key: key))
        let got = try await collect(p.stream(LLMRequest(system: "SYS", user: "USER", model: "gemini-2.5-pro")))
        XCTAssertEqual(got, ["Hi ", "there"])
        let r = try XCTUnwrap(t.streamRequests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertFalse(r.url!.absoluteString.contains(key))
    }

    func testGeminiRejectsModelNamesThatCouldChangeThePath() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.geminiSSE)])
        let p = CloudProvider(kind: .gemini, transport: t, secrets: try store(.gemini))
        do { _ = try await collect(p.stream(LLMRequest(system: "s", user: "u", model: "x/../../evil"))); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .modelNotFound) }
        XCTAssertEqual(t.callCount, 0)
    }

    func testMissingKeyIsBadKeyWithoutNetwork() async {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.anthropicSSE)])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: InMemorySecretStore())
        let status = await p.availability()
        XCTAssertEqual(status, .needsKey)
        do { _ = try await collect(p.stream(req)); XCTFail() } catch { XCTAssertEqual((error as? LLMError)?.kind, .badKey) }
        XCTAssertEqual(t.callCount, 0)
    }

    func testStatusMapping() async throws {
        let cases: [(Int, LLMError.Kind)] = [(401, .badKey), (403, .badKey), (404, .modelNotFound), (429, .rateLimited)]
        for (status, kind) in cases {
            let t = FakeHTTPTransport(open: [.ok(status: status, chunks: [Data("{}".utf8)], keepOpen: false)])
            let p = CloudProvider(kind: .openAI, transport: t, secrets: try store(.openAI))
            do { _ = try await collect(p.stream(req)); XCTFail("\(status)") } catch { XCTAssertEqual((error as? LLMError)?.kind, kind, "\(status)") }
        }
    }

    func testGeminiBadKeyArrivesAs400() async throws {
        let body = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)
        let t = FakeHTTPTransport(open: [.ok(status: 400, chunks: [body], keepOpen: false)])
        let p = CloudProvider(kind: .gemini, transport: t, secrets: try store(.gemini))
        do { _ = try await collect(p.stream(req)); XCTFail() } catch { XCTAssertEqual((error as? LLMError)?.kind, .badKey) }
        XCTAssertEqual(t.streamRequests.count, 1)
    }

    // MARK: Retry (R24)

    func testTransientFailureIsRetriedOnceAndABadKeyIsNot() async throws {
        let ok = FakeHTTPTransport.sse(Self.anthropicSSE)
        let t = FakeHTTPTransport(open: [.ok(status: 503, chunks: [], keepOpen: false), ok])
        let got = try await collect(CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic)).stream(req))
        XCTAssertEqual(got, Self.anthropicText); XCTAssertEqual(t.streamRequests.count, 2)

        let t2 = FakeHTTPTransport(open: [.fail(URLError(.timedOut))])
        do { _ = try await collect(CloudProvider(kind: .anthropic, transport: t2, secrets: try store(.anthropic)).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .offline) }
        XCTAssertEqual(t2.streamRequests.count, 2, "one retry, no more")

        let t3 = FakeHTTPTransport(open: [.ok(status: 401, chunks: [], keepOpen: false), ok])
        do { _ = try await collect(CloudProvider(kind: .anthropic, transport: t3, secrets: try store(.anthropic)).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .badKey) }
        XCTAssertEqual(t3.streamRequests.count, 1, "no retry on 401")
    }

    // MARK: Robustness

    func testErrorEventAndContentFilterInStream() async throws {
        let err = Self.ev(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.ev(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"a"}}"#) + err)])
        let out = CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic)).stream(req)
        var got: [String] = []
        do { for try await d in out { got.append(d) }; XCTFail() } catch { XCTAssertEqual((error as? LLMError)?.kind, .unavailable) }
        XCTAssertEqual(got, ["a"])

        let blocked = Self.ev(#"{"candidates":[{"finishReason":"SAFETY","index":0}]}"#)
        let t2 = FakeHTTPTransport(open: [FakeHTTPTransport.sse(blocked)])
        do { _ = try await collect(CloudProvider(kind: .gemini, transport: t2, secrets: try store(.gemini)).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .contentFiltered) }
    }

    func testTruncatedAndGarbageStreamsDoNotCrash() async throws {
        var rng = SeededRNG(state: 42)
        for kind in CloudKind.allCases {
            for i in 0..<20 {
                var text = kind == .anthropic ? Self.anthropicSSE : kind == .gemini ? Self.geminiSSE : LLMFixtures.openAISSE
                text = String(text.prefix(Int(rng.next() % UInt64(text.count))))
                if i % 2 == 0 { text += String(decoding: (0..<64).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, as: UTF8.self) }
                let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(text)])
                _ = try? await collect(CloudProvider(kind: kind, transport: t, secrets: try store(kind)).stream(req))
            }
        }
    }

    func testCancelClosesTheConnection() async throws {
        let t = FakeHTTPTransport(open: [.ok(status: 200, chunks: [Data(Self.ev(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"a"}}"#).utf8)], keepOpen: true)])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic))
        let request = req
        let task = Task { try await collect(p.stream(request)) }
        let started = await eventually { t.streamRequests.count == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        let closed = await eventually { t.bodyTerminations >= 1 }
        XCTAssertTrue(closed, "cancelling must end the network work")
    }

    // MARK: Test key (R5)

    func testTestKeySucceedsWithOneSmallRequest() async throws {
        let t = FakeHTTPTransport(data: [.success((Data("{}".utf8), 200))])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: InMemorySecretStore())
        try await p.testKey("  \(secret) \n")   // not saved anywhere: tested as typed
        let r = try XCTUnwrap(t.dataRequests.first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), secret)
        XCTAssertEqual(r.timeoutInterval, CloudProvider.testTimeout)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, false); XCTAssertLessThanOrEqual(body["max_tokens"] as? Int ?? 99, 16)
        XCTAssertEqual(t.callCount, 1)
    }

    func testTestKeyMapsFailures() async throws {
        let cases: [(Result<(Data, Int), Error>, LLMError.Kind)] = [
            (.success((Data(), 401)), .badKey), (.success((Data(), 404)), .modelNotFound), (.success((Data(), 429)), .rateLimited),
            (.failure(URLError(.notConnectedToInternet)), .offline),
        ]
        for (result, kind) in cases {
            let p = CloudProvider(kind: .openAI, transport: FakeHTTPTransport(data: [result]), secrets: InMemorySecretStore())
            do { try await p.testKey(FakeKeys.openAI); XCTFail() } catch { XCTAssertEqual((error as? LLMError)?.kind, kind) }
        }
    }

    func testTestKeyDoesNotRetryA401ButRetriesAServerError() async throws {
        let t = FakeHTTPTransport(data: [.success((Data(), 401)), .success((Data(), 200))])
        do { try await CloudProvider(kind: .openAI, transport: t, secrets: InMemorySecretStore()).testKey(FakeKeys.openAI); XCTFail() } catch {}
        XCTAssertEqual(t.dataRequests.count, 1)
        let t2 = FakeHTTPTransport(data: [.success((Data(), 500)), .success((Data(), 200))])
        try await CloudProvider(kind: .openAI, transport: t2, secrets: InMemorySecretStore()).testKey(FakeKeys.openAI)
        XCTAssertEqual(t2.dataRequests.count, 2)
    }

    func testTestKeyWithNothingToTestIsABadKey() async {
        let t = FakeHTTPTransport()
        do { try await CloudProvider(kind: .gemini, transport: t, secrets: InMemorySecretStore()).testKey("  "); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .badKey) }
        XCTAssertEqual(t.callCount, 0)
    }

    // MARK: Local-only (R6)

    func testLocalOnlyBlocksEveryCloudCallWithoutNetwork() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.anthropicSSE)], data: [.success((Data(), 200))])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic), localOnly: { true })
        do { _ = try await collect(p.stream(req)); XCTFail() }
        catch { XCTAssertEqual(UserError.message(for: error, action: "x"), LocalOnlyPolicy.message) }
        do { try await p.testKey(); XCTFail() } catch { XCTAssertEqual((error as? UserFacingError)?.message, LocalOnlyPolicy.message) }
        let status = await p.availability()
        XCTAssertEqual(status, .unavailable(LocalOnlyPolicy.message))
        XCTAssertEqual(t.callCount, 0)
    }

    func testLocalOnlyFlagIsReadPerCall() async throws {
        let flag = LockedFlag()
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(Self.anthropicSSE)])
        let p = CloudProvider(kind: .anthropic, transport: t, secrets: try store(.anthropic), localOnly: { flag.value })
        let first = try await collect(p.stream(req))
        XCTAssertEqual(first, Self.anthropicText)
        flag.value = true
        do { _ = try await collect(p.stream(req)); XCTFail() } catch {}
        XCTAssertEqual(t.streamRequests.count, 1)
    }

    func testCloudProvidersAreCloudAndLocalOnesAreNot() {
        for kind in CloudKind.allCases {
            XCTAssertTrue(CloudProvider(kind: kind, secrets: InMemorySecretStore()).isCloud)
            XCTAssertTrue(CloudKind.isCloud(providerID: kind.id))
            XCTAssertTrue(kind.models.contains(kind.defaultModel))
        }
        for id in [OnDeviceProvider.providerID, OpenAICompatProvider.providerID, ClaudeCLIProvider.providerID] { XCTAssertFalse(CloudKind.isCloud(providerID: id)) }
        XCTAssertFalse(OpenAICompatProvider().isCloud)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var _v = false
    var value: Bool { get { lock.withLock { _v } } set { lock.withLock { _v = newValue } } }
}
