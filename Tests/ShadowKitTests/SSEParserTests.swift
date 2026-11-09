import XCTest
@testable import ShadowKit

/// R3 / A3 parsers, R24 / A24 fuzzing.
final class SSEParserTests: XCTestCase {
    private func events(_ text: String, chunk: Int) -> [SSEParser.Event] {
        var p = SSEParser(), out: [SSEParser.Event] = []
        let bytes = Array(text.utf8)
        for i in stride(from: 0, to: bytes.count, by: chunk) { out += p.feed(Data(bytes[i..<min(i + chunk, bytes.count)])) }
        return out + p.finish()
    }

    private func texts(_ events: [SSEParser.Event], _ extract: (String) -> String?) -> [String] {
        events.compactMap { if case .data(let d) = $0 { extract(d) } else { nil } }
    }

    func testOllamaFixtureYieldsDeltasAndDoneAtAnyChunking() {
        for chunk in [1, 2, 3, 7, 64, 100_000] {
            let ev = events(LLMFixtures.ollamaSSE, chunk: chunk)
            XCTAssertEqual(texts(ev, SSEDelta.openAICompatible), LLMFixtures.ollamaText, "chunk \(chunk)")
            XCTAssertEqual(ev.last, .done)
        }
    }

    func testOpenAIFixtureSkipsKeepAliveAndRoleOnlyChunk() {
        let ev = events(LLMFixtures.openAISSE, chunk: 5)
        XCTAssertEqual(texts(ev, SSEDelta.openAICompatible), LLMFixtures.openAIText)
        XCTAssertEqual(ev.last, .done)
    }

    func testCRLFAndMultiLineData() {
        XCTAssertEqual(events("data: a\r\n\r\ndata: b\r\ndata: c\r\n\r\n", chunk: 4), [.data("a"), .data("b\nc")])
        XCTAssertEqual(events("event: x\nid: 1\nretry: 5\ndata:nospace\n\n", chunk: 100), [.data("nospace")])
    }

    func testTruncatedLastEventIsDeliveredAndItsBrokenJSONIsSkipped() {
        let ev = events(LLMFixtures.chunk("ok") + "data: {\"choices\":[{\"delta\":{\"cont", chunk: 9)
        XCTAssertEqual(texts(ev, SSEDelta.openAICompatible), ["ok"])
        XCTAssertEqual(ev.count, 2)
    }

    func testMultibyteCharactersSplitAcrossChunksSurvive() {
        let ev = events(LLMFixtures.chunk("日本語 ✓ é"), chunk: 1)
        XCTAssertEqual(texts(ev, SSEDelta.openAICompatible), ["日本語 ✓ é"])
    }

    func testOversizedLineIsDroppedNotBuffered() {
        var p = SSEParser(maxLineBytes: 64)
        var ev = p.feed("data: " + String(repeating: "x", count: 10_000) + "\n\n")
        ev += p.feed("data: fine\n\n")
        XCTAssertEqual(ev, [.data("fine")])
    }

    func testFuzzRandomTruncatedAndOversizedInputNeverCrashes() {
        var rng = SeededRNG(state: 42)
        for round in 0..<300 {
            var data = Data((0..<Int.random(in: 0...600, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if round % 3 == 0 { data = Data(Array(LLMFixtures.openAISSE.utf8).prefix(Int.random(in: 0...400, using: &rng))) + data }
            if round % 50 == 0 { data.append(Data(repeating: 0x61, count: 3_000_000)) }
            var p = SSEParser(), cli = StreamJSONParser()
            let step = Int.random(in: 1...97, using: &rng)
            for i in stride(from: 0, to: data.count, by: step) {
                let slice = data[i..<min(i + step, data.count)]
                for case .data(let j) in p.feed(Data(slice)) { _ = SSEDelta.openAICompatible(j); _ = SSEDelta.errorMessage(j) }
                _ = cli.feed(Data(slice))
            }
            _ = p.finish(); _ = cli.finish()
        }
    }

    // MARK: extractors

    func testErrorObjectsInsideTheStream() {
        XCTAssertEqual(SSEDelta.errorMessage(#"{"error":{"message":"model not found","type":"x"}}"#), "model not found")
        XCTAssertEqual(SSEDelta.errorMessage(#"{"error":"boom"}"#), "boom")
        XCTAssertNil(SSEDelta.errorMessage(LLMFixtures.ollamaSSE))
    }

    func testModelListParsing() {
        XCTAssertEqual(ModelListParser.parse(Data(LLMFixtures.modelsJSON.utf8)), ["llama3.2:latest", "qwen2.5:7b"])
        XCTAssertEqual(ModelListParser.parse(Data(#"{"models":[{"name":"llama3"}]}"#.utf8)), ["llama3"])
        XCTAssertEqual(ModelListParser.parse(Data("garbage".utf8)), [])
        XCTAssertEqual(ModelListParser.parse(Data(#"{"data":[]}"#.utf8)), [])
    }
}
