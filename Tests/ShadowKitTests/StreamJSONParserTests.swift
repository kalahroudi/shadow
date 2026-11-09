import XCTest
@testable import ShadowKit

/// R4 / A4: stream-json fixtures.
final class StreamJSONParserTests: XCTestCase {
    private func parse(_ text: String, chunk: Int = 11) -> (events: [StreamJSONParser.Event], parser: StreamJSONParser) {
        var p = StreamJSONParser(), out: [StreamJSONParser.Event] = []
        let bytes = Array(text.utf8)
        for i in stride(from: 0, to: bytes.count, by: chunk) { out += p.feed(Data(bytes[i..<min(i + chunk, bytes.count)])) }
        return (out + p.finish(), p)
    }

    func testNormalRunStreamsDeltasAndIgnoresTheRepeatedAssistantMessage() {
        let r = parse(LLMFixtures.cliNormal)
        XCTAssertEqual(r.events, [.text("2+2 is"), .text(" 4.")])
        XCTAssertTrue(r.parser.sawResult)
    }

    func testWithoutPartialMessagesTheAssistantMessageIsTheText() {
        let r = parse(LLMFixtures.cliInit + LLMFixtures.cliAssistant("Whole answer") + LLMFixtures.cliResult("Whole answer"))
        XCTAssertEqual(r.events, [.text("Whole answer")])
    }

    func testResultTextIsUsedWhenNothingElseArrived() {
        XCTAssertEqual(parse(LLMFixtures.cliInit + LLMFixtures.cliResult("Only result")).events, [.text("Only result")])
    }

    func testTruncatedRunKeepsTheTextSoFarAndHasNoResult() {
        let cut = LLMFixtures.cliInit + LLMFixtures.cliDelta("Partial") + String(LLMFixtures.cliDelta(" answer").dropLast(40))
        let r = parse(cut)
        XCTAssertEqual(r.events, [.text("Partial")])
        XCTAssertFalse(r.parser.sawResult)
        XCTAssertTrue(r.parser.emittedText)
    }

    func testErrorLineIsReported() {
        let r = parse(LLMFixtures.cliInit + LLMFixtures.cliResult("Invalid API key · Please run /login", isError: true))
        XCTAssertEqual(r.events, [.error("Invalid API key · Please run /login")])
    }

    func testGarbageAndUnknownLinesAreSkipped() {
        let r = parse("not json\n{\"type\":\"rate_limit_event\"}\n[1,2]\n{}\n" + LLMFixtures.cliDelta("ok"))
        XCTAssertEqual(r.events, [.text("ok")])
    }
}
