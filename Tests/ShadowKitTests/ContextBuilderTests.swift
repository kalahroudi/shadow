import XCTest
@testable import ShadowKit

/// R12 / A12.
final class ContextBuilderTests: XCTestCase {
    private func seg(_ s: Speaker, _ t: String, _ at: Double, final: Bool = true) -> Segment {
        Segment(speaker: s, text: t, start: at, end: at + 1, isFinal: final)
    }
    private let persona = Persona.default

    func testLabelsSpeakersAndKeepsOrder() {
        let c = ContextBuilder.build(persona: persona, language: .english, turns: [seg(.them, "Hi there", 0), seg(.you, "Hello", 2)], question: "How are you?")
        XCTAssertEqual(c.user, "Conversation so far:\nThem: Hi there\nYou: Hello\n\nQuestion to answer: How are you?")
        XCTAssertEqual(c.includedTurns, 2)
        XCTAssertEqual(c.droppedTurns, 0)
    }

    func testDropsOldestFirstAndNeverSplitsATurn() {
        let turns = (0..<6).map { seg($0 % 2 == 0 ? .them : .you, "turn-\($0) " + String(repeating: "x", count: 40), Double($0)) }
        // Each line is about 52 chars = 13 tokens; a 40-token budget keeps three whole turns.
        let c = ContextBuilder.build(persona: persona, language: .english, turns: turns, question: nil, budgetTokens: 40)
        XCTAssertEqual(c.includedTurns, 3)
        XCTAssertEqual(c.droppedTurns, 3)
        XCTAssertFalse(c.user.contains("turn-2"))
        for i in 3...5 { XCTAssertTrue(c.user.contains("turn-\(i) " + String(repeating: "x", count: 40))) }
    }

    func testNewestTurnAloneOverBudgetIsKeptWhole() {
        let long = String(repeating: "word ", count: 400)
        let c = ContextBuilder.build(persona: persona, language: .english, turns: [seg(.you, "old", 0), seg(.them, long, 1)], question: nil, budgetTokens: 50)
        XCTAssertEqual(c.includedTurns, 1)
        XCTAssertEqual(c.droppedTurns, 1)
        XCTAssertTrue(c.newestExceedsBudget)
        XCTAssertTrue(c.user.contains(long.trimmingCharacters(in: .whitespaces)))
    }

    func testPartialsAndEmptyTurnsAreIgnored() {
        let c = ContextBuilder.build(persona: persona, language: .english, turns: [seg(.them, "live", 0, final: false), seg(.you, "  ", 1), seg(.them, "done", 2)], question: nil)
        XCTAssertEqual(c.includedTurns, 1)
        XCTAssertFalse(c.user.contains("live"))
    }

    func testSystemHasPersonaLengthAndLanguageRule() {
        var p = Persona.builtIn("sales")!
        p.length = .short
        let c = ContextBuilder.build(persona: p, language: .german, turns: [], question: "Wie viel kostet es?")
        XCTAssertTrue(c.system.hasPrefix(p.systemPrompt))
        XCTAssertTrue(c.system.contains(AnswerLength.short.clause))
        XCTAssertTrue(c.system.contains("same language as the question"))
        XCTAssertTrue(c.system.contains("Deutsch"))
        XCTAssertFalse(ContextBuilder.build(persona: p, language: .auto, turns: [], question: nil).system.contains("expected to be in"))
    }

    func testPromptHoldsNoKeysOrAudio() {
        // The builder's inputs are persona, language and transcript text only; its output is plain text.
        let c = ContextBuilder.build(persona: persona, language: .english, turns: [seg(.them, "hello", 0)], question: "Hi?")
        for s in [c.system, c.user] {
            XCTAssertFalse(s.contains("sk-"))
            XCTAssertFalse(s.lowercased().contains("api key"))
            XCTAssertFalse(s.lowercased().contains("pcm"))
        }
    }
}
