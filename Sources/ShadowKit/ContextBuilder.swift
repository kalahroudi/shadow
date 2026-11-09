// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The text a provider receives (R12). It carries no audio and no secrets by construction: the builder's only inputs are
/// the persona, the language, transcript text and the detected question.
public struct BuiltContext: Equatable, Sendable {
    public var system: String
    /// Speaker-labelled turns, oldest first, then the question.
    public var user: String
    public var includedTurns: Int
    public var droppedTurns: Int
    /// True when the newest turn alone is larger than the budget. It is kept whole: a turn is never split.
    public var newestExceedsBudget: Bool
    public var estimatedTokens: Int
}

public enum ContextBuilder {
    public static let defaultBudgetTokens = 1_500

    /// About four characters per token for Latin text, one per Japanese/Chinese/Korean character; good enough to size a prompt, and always rounds up.
    public static func estimateTokens(_ text: String) -> Int {
        var cjk = 0, other = 0
        for ch in text.unicodeScalars {
            switch ch.value {
            case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other + 3) / 4
    }

    public static func label(_ speaker: Speaker) -> String { speaker == .them ? "Them" : "You" }

    /// The language rule: answer in the question's language unless the persona says otherwise.
    public static func languageRule(_ language: Language) -> String {
        var rule = "Answer in the same language as the question, unless the instructions above say to use a different language."
        if language != .auto { rule += " The call is expected to be in \(language.label)." }
        return rule
    }

    /// Keeps the newest turns that fit `budgetTokens`, dropping the oldest first. Only final, non-empty turns count.
    /// The newest turn is always kept so there is something to answer from.
    public static func build(persona: Persona, language: Language, turns: [Segment], question: String?,
                             budgetTokens: Int = defaultBudgetTokens) -> BuiltContext {
        let lines = turns.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\(label($0.speaker)): \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
        var kept: [String] = [], used = 0
        for line in lines.reversed() {
            let cost = estimateTokens(line)
            if !kept.isEmpty, used + cost > max(0, budgetTokens) { break }
            kept.append(line); used += cost
        }
        kept.reverse()

        var user = kept.isEmpty ? "" : "Conversation so far:\n" + kept.joined(separator: "\n")
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            user += (user.isEmpty ? "" : "\n\n") + "Question to answer: \(q)"
        }
        let system = persona.effectivePrompt + "\n\n" + languageRule(language)
        return BuiltContext(system: system, user: user, includedTurns: kept.count, droppedTurns: lines.count - kept.count,
                            newestExceedsBudget: kept.count == 1 && used > max(0, budgetTokens),
                            estimatedTokens: estimateTokens(system) + estimateTokens(user))
    }
}
