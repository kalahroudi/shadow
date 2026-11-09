import XCTest
@testable import ShadowKit

/// R24 (error classes) and R13 (scrubbing) / A13, A24.
final class LLMErrorTests: XCTestCase {
    /// Key-shaped strings are assembled at runtime so no key-like literal sits in the source. They are made up, not real keys.
    private func fakeKey(_ prefix: String, _ body: String) -> String { prefix + body }
    private var fakeKeys: [String] {
        [fakeKey("sk-ant-", "api03-AbCdEfGhIjKlMnOpQrSt_uvwx-1234"), fakeKey("sk-proj-", "AbCdEfGhIjKlMnOpQrSt1234_xyz"),
         fakeKey("sk-", "AbCdEfGhIjKlMnOpQrSt1234567890"), fakeKey("AI", "zaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q")]
    }

    func testEveryClassHasADistinctFriendlyMessage() {
        let messages = LLMError.Kind.allCases.map { LLMError($0).message }
        XCTAssertEqual(Set(messages).count, LLMError.Kind.allCases.count)
        for m in messages { XCTAssertTrue(m.hasSuffix(".") && !m.contains("HTTP") && !m.contains("Error"), m) }
    }

    func testFunnelUsesTheMessage() {
        XCTAssertEqual(UserError.message(for: LLMError(.badKey), action: "answer"), LLMError(.badKey).message)
    }

    func testHTTPStatusMapping() {
        XCTAssertNil(LLMError.from(httpStatus: 200))
        XCTAssertEqual(LLMError.from(httpStatus: 401)?.kind, .badKey)
        XCTAssertEqual(LLMError.from(httpStatus: 403)?.kind, .badKey)
        XCTAssertEqual(LLMError.from(httpStatus: 404)?.kind, .modelNotFound)
        XCTAssertEqual(LLMError.from(httpStatus: 429)?.kind, .rateLimited)
        XCTAssertEqual(LLMError.from(httpStatus: 503)?.kind, .unavailable)
    }

    func testURLErrorMappingAndTransience() {
        XCTAssertEqual(LLMError.from(urlError: URLError(.notConnectedToInternet)).kind, .offline)
        XCTAssertEqual(LLMError.from(urlError: URLError(.timedOut)).kind, .offline)
        XCTAssertEqual(LLMError.from(urlError: URLError(.badServerResponse)).kind, .unavailable)
        XCTAssertTrue(LLMError(.offline).isTransient)
        XCTAssertFalse(LLMError(.badKey).isTransient)
        XCTAssertFalse(LLMError(.rateLimited).isTransient)
    }

    func testCopyDetailsAndIssueURLAreScrubbed() {
        let e = LLMError(.badKey, detail: "key \(fakeKeys[0]) at /Users/jdoe/x")
        let text = e.copyDetails(appVersion: "1.2", home: "/Users/jdoe", user: "jdoe")
        XCTAssertTrue(text.contains("badKey"))
        XCTAssertFalse(text.contains(fakeKeys[0]))
        XCTAssertFalse(text.contains("jdoe"))
        let url = e.issueURL(appVersion: "1.2", home: "/Users/jdoe", user: "jdoe")!
        XCTAssertEqual(url.host, "github.com")
        XCTAssertFalse(url.absoluteString.contains("AbCdEfGhIjKlMnOp"))
    }

    func testScrubberRedactsAllThreeKeyShapes() {
        let keys = fakeKeys
        for k in keys {
            let out = LogScrubber.scrub("request failed with \(k) while calling", home: "/Users/x", user: "x")
            XCTAssertFalse(out.contains(k), out)
            XCTAssertFalse(out.contains(String(k.dropFirst(8))), out)
        }
        XCTAssertFalse(LogScrubber.scrub("x-goog-api-key: \(fakeKeys[3])").contains(fakeKeys[3]))
    }

    func testScrubberRemovesPromptAndAnswerText() {
        let marked = LogScrubber.scrub("done \(LogScrubber.mark(prompt: "secret interview\nquestion")) and \(LogScrubber.mark(answer: "my answer")) ok")
        XCTAssertFalse(marked.contains("secret interview"))
        XCTAssertFalse(marked.contains("my answer"))
        XCTAssertTrue(marked.hasPrefix("done ") && marked.hasSuffix(" ok"))
        for line in ["prompt: tell me about yourself", "ANSWER=I led a team", "system_prompt: You are a coach", "provider=apple latency=120ms prompt: hi there"] {
            let out = LogScrubber.scrub(line)
            XCTAssertFalse(out.contains("yourself") || out.contains("led a team") || out.contains("coach") || out.contains("hi there"), out)
        }
        XCTAssertEqual(LogScrubber.scrub("provider=apple model=on-device latency=120ms tokens=300"), "provider=apple model=on-device latency=120ms tokens=300")
    }

    func testCopyDetailsKeepsTheFriendlyMessageAndCapsDetail() {
        for kind in LLMError.Kind.allCases {
            let out = LLMError(kind, detail: String(repeating: "z", count: 5000)).copyDetails(appVersion: "1")
            XCTAssertTrue(out.contains(LLMError(kind).message), "scrubber ate the message for \(kind)")
            XCTAssertLessThan(out.count, 1000)
        }
    }
}
