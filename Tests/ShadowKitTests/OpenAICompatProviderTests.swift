import XCTest
@testable import ShadowKit

/// R3 / A3.
final class OpenAICompatProviderTests: XCTestCase {
    private let req = LLMRequest(system: "SYS", user: "USER", model: "llama3.2")

    func testLoopbackValidation() throws {
        for ok in ["http://localhost:11434/v1", "http://127.0.0.1:8080/v1", "http://127.0.0.2/v1", "https://LOCALHOST/v1", "http://[::1]:11434/v1"] {
            XCTAssertNoThrow(try LoopbackURL.validate(ok), ok)
        }
        for bad in ["http://192.168.1.5:11434/v1", "https://api.openai.com/v1", "http://localhost.evil.com/v1", "http://127.0.0.1.evil.com/v1",
                    "http://0.0.0.0:8080/v1", "http://10.0.0.1/v1", "http://user:pw@localhost/v1", "ftp://localhost/v1", "localhost:11434", "", "http://128.0.0.1/v1",
                    "http://127.0.0/v1", "http://127.0.0.256/v1"] {
            XCTAssertThrowsError(try LoopbackURL.validate(bad), bad) { XCTAssertTrue(UserError.message(for: $0, action: "x").count > 10) }
        }
        XCTAssertNoThrow(try LoopbackURL.validate(LoopbackURL.defaultBase))
    }

    func testNonLoopbackBaseIsRefusedWithoutAnyNetworkCall() async {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(LLMFixtures.ollamaSSE)])
        let p = OpenAICompatProvider(baseURL: "https://api.openai.com/v1", transport: t)
        do { _ = try await collect(p.stream(req)); XCTFail() }
        catch { XCTAssertTrue(error is UserFacingError); XCTAssertTrue(UserError.message(for: error, action: "answer").contains("this Mac")) }
        let status = await p.availability()
        XCTAssertEqual(t.callCount, 0)
        if case .unavailable = status {} else { XCTFail("\(status)") }
    }

    func testStreamsOllamaDeltasAndBuildsTheRequest() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(LLMFixtures.ollamaSSE)])
        let got = try await collect(OpenAICompatProvider(transport: t).stream(req))
        XCTAssertEqual(got, LLMFixtures.ollamaText)
        let r = try XCTUnwrap(t.streamRequests.first)
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.timeoutInterval, OpenAICompatProvider.requestTimeout)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "llama3.2"); XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "SYS"], ["role": "user", "content": "USER"]])
    }

    func testOpenAIFixtureAndOptionalKey() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(LLMFixtures.openAISSE)])
        let got = try await collect(OpenAICompatProvider(baseURL: "http://127.0.0.1:8080/v1", transport: t, apiKey: { "local-key" }).stream(req))
        XCTAssertEqual(got, LLMFixtures.openAIText)
        XCTAssertEqual(t.streamRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer local-key")
    }

    func testStreamStopsAtDoneEvenWithTrailingData() async throws {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(LLMFixtures.chunk("a") + "data: [DONE]\n\n" + LLMFixtures.chunk("late"))])
        let got = try await collect(OpenAICompatProvider(transport: t).stream(req))
        XCTAssertEqual(got, ["a"])
    }

    func testUnreachableServerIsNotRunningAndIsNotRetried() async {
        let t = FakeHTTPTransport()   // every call: connection refused
        let p = OpenAICompatProvider(transport: t)
        let status = await p.availability()
        XCTAssertEqual(status, .notRunning)
        do { _ = try await collect(p.stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .unavailable); XCTAssertTrue((error as? LLMError)?.detail.contains("not running") == true) }
        XCTAssertEqual(t.streamRequests.count, 1)
    }

    func testTimeoutWhileConnectingIsRetriedOnce() async throws {
        let t = FakeHTTPTransport(open: [.fail(URLError(.timedOut)), FakeHTTPTransport.sse(LLMFixtures.ollamaSSE)])
        let got = try await collect(OpenAICompatProvider(transport: t).stream(req))
        XCTAssertEqual(got, LLMFixtures.ollamaText)
        XCTAssertEqual(t.streamRequests.count, 2)

        let t2 = FakeHTTPTransport(open: [.fail(URLError(.timedOut))])
        do { _ = try await collect(OpenAICompatProvider(transport: t2).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .offline) }
        XCTAssertEqual(t2.streamRequests.count, 2)
    }

    func testHTTPErrorsMapAndAreNotRetried() async {
        for (status, kind) in [(401, LLMError.Kind.badKey), (404, .modelNotFound), (429, .rateLimited), (500, .unavailable)] {
            let t = FakeHTTPTransport(open: [.ok(status: status, chunks: [Data("{}".utf8)], keepOpen: false)])
            do { _ = try await collect(OpenAICompatProvider(transport: t).stream(req)); XCTFail() }
            catch { XCTAssertEqual((error as? LLMError)?.kind, kind, "\(status)") }
            XCTAssertEqual(t.streamRequests.count, 1, "\(status)")
        }
    }

    func testMissingModelAndInStreamErrors() async {
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(#"data: {"error":{"message":"boom"}}"# + "\n\n")])
        do { _ = try await collect(OpenAICompatProvider(transport: t).stream(LLMRequest(system: "s", user: "u"))); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .modelNotFound) }
        XCTAssertEqual(t.callCount, 0)
        do { _ = try await collect(OpenAICompatProvider(transport: t).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .unavailable) }
    }

    func testTruncatedAndGarbageStreamsDoNotCrashAndKeepWhatArrived() async throws {
        let text = LLMFixtures.chunk("kept") + "data: {not json}\n\n" + "data: {\"choices\":[{\"del"
        let t = FakeHTTPTransport(open: [FakeHTTPTransport.sse(text)])
        let got = try await collect(OpenAICompatProvider(transport: t).stream(req))
        XCTAssertEqual(got, ["kept"])
    }

    func testCancellingStopsReadingTheBody() async throws {
        let t = FakeHTTPTransport(open: [.ok(status: 200, chunks: [Data(LLMFixtures.chunk("a").utf8)], keepOpen: true)])
        let p = OpenAICompatProvider(transport: t), r = req
        let task = Task { try await collect(p.stream(r)) }
        let started = await eventually { t.streamRequests.count == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result
        let stopped = await eventually { t.bodyTerminations == 1 }
        XCTAssertTrue(stopped)
    }

    func testModelsAndAvailabilityStates() async throws {
        func provider(_ r: Result<(Data, Int), Error>) -> OpenAICompatProvider { OpenAICompatProvider(transport: FakeHTTPTransport(data: [r])) }
        let ok = provider(.success((Data(LLMFixtures.modelsJSON.utf8), 200)))
        let listed = try await ok.models()
        XCTAssertEqual(listed, ["llama3.2:latest", "qwen2.5:7b"])
        var status = await ok.availability(); XCTAssertEqual(status, .ready)
        status = await provider(.success((Data(#"{"data":[]}"#.utf8), 200))).availability()
        if case .unavailable(let m) = status { XCTAssertTrue(m.contains("no models")) } else { XCTFail("\(status)") }
        status = await provider(.success((Data(), 401))).availability(); XCTAssertEqual(status, .needsKey)
        status = await provider(.failure(URLError(.cannotConnectToHost))).availability(); XCTAssertEqual(status, .notRunning)
        let t = FakeHTTPTransport(data: [.success((Data(LLMFixtures.modelsJSON.utf8), 200))])
        _ = try await OpenAICompatProvider(baseURL: "http://localhost:8080/v1/", transport: t).models()
        XCTAssertEqual(t.dataRequests.first?.url?.absoluteString, "http://localhost:8080/v1/models")
        XCTAssertEqual(t.dataRequests.first?.httpMethod, "GET")
    }

    func testIsLocalNotCloud() { XCTAssertFalse(OpenAICompatProvider().isCloud) }
}
