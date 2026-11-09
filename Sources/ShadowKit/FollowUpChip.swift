// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The follow-up chips under an answer (R19). Each one is a real request on the same context, not a canned reply.
public enum FollowUpChip: Equatable, Hashable, Sendable {
    case shorter, addMetric, likelyFollowUp, language(Language)

    public var title: String {
        switch self {
        case .shorter: "Shorter"
        case .addMetric: "Add a metric"
        case .likelyFollowUp: "Likely follow-up"
        case .language(let l): "Say it in \(l.label)"
        }
    }

    /// Stored in `AnswerRecord.kind`.
    public var kind: String {
        switch self {
        case .shorter: "shorter"
        case .addMetric: "metric"
        case .likelyFollowUp: "followUp"
        case .language: "language"
        }
    }

    /// The instruction appended to the conversation. "Add a metric" asks for a concrete number under Interview and for more detail elsewhere.
    public func instruction(personaID: String) -> String {
        switch self {
        case .shorter:
            "Rewrite your previous answer so it is much shorter. Keep only the key point."
        case .addMetric:
            personaID == Persona.interviewID
                ? "Rewrite your previous answer and add one concrete metric or measurable result, marked as a placeholder like [your number] if the conversation has not given one."
                : "Rewrite your previous answer to be more specific."
        case .likelyFollowUp:
            "Predict the most likely next question the other person will ask after this answer. State that question on one line, then draft the answer to it."
        case .language(let l):
            "Say your previous answer again in \(l.label), with the same content."
        }
    }

    /// The language chips offered: every concrete choice in the Settings language list.
    public static var languageChips: [FollowUpChip] { Language.allCases.filter { $0 != .auto }.map { .language($0) } }
}

/// Answers made in one session, with a cursor for the overlay's back and forward arrows (R20).
public struct AnswerHistory: Equatable, Sendable {
    public private(set) var records: [AnswerRecord] = []
    /// The record on screen; nil while the screen shows something that is not in the history (a new answer, an error).
    public private(set) var cursor: Int?

    public init(records: [AnswerRecord] = []) { self.records = records }

    public var canBack: Bool { cursor.map { $0 > 0 } ?? !records.isEmpty }
    public var canForward: Bool { cursor.map { $0 < records.count - 1 } ?? false }
    /// "2 / 5" while viewing a record.
    public var position: String? { cursor.map { "\($0 + 1) / \(records.count)" } }
    /// True when the screen shows the newest answer or something newer than any record.
    public var atLatest: Bool { cursor.map { $0 == records.count - 1 } ?? true }

    /// A new answer always lands at the end, wherever the user had navigated to.
    public mutating func append(_ record: AnswerRecord) { records.append(record); cursor = records.count - 1 }
    public mutating func detach() { cursor = nil }

    public mutating func back() -> AnswerRecord? {
        guard canBack else { return nil }
        cursor = cursor.map { $0 - 1 } ?? records.count - 1
        return cursor.map { records[$0] }
    }

    public mutating func forward() -> AnswerRecord? {
        guard canForward, let c = cursor else { return nil }
        cursor = c + 1
        return records[c + 1]
    }
}
