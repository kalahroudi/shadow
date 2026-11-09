// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// How long answers should be. Changes the prompt, not a token limit (R15).
public enum AnswerLength: String, CaseIterable, Sendable, Codable {
    case short, medium, long

    public var label: String { rawValue.capitalized }

    public var clause: String {
        switch self {
        case .short: "Keep the answer short: at most three sentences."
        case .medium: "Keep the answer medium length: a short paragraph or a few bullets."
        case .long: "Give a thorough answer with structure, but stay under about 300 words."
        }
    }
}

/// A persona: who the assistant is for this call (R14). Built-in ids are stable and double as the legacy stored values.
public struct Persona: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var systemPrompt: String
    public var length: AnswerLength
    public var isBuiltIn: Bool
    /// Meeting notes takes notes; it never suggests answers (R16).
    public var suggestsAnswers: Bool

    public init(id: String, name: String, isBuiltIn: Bool = false, suggestsAnswers: Bool = true, systemPrompt: String, length: AnswerLength = .medium) {
        self.id = id; self.name = name; self.systemPrompt = systemPrompt; self.length = length
        self.isBuiltIn = isBuiltIn; self.suggestsAnswers = suggestsAnswers
    }

    public var label: String { name }

    /// The system prompt the model receives: the persona text plus its length clause.
    public var effectivePrompt: String { systemPrompt + "\n\n" + length.clause }

    public static let interviewID = "interview", salesID = "sales", codingID = "coding", meetingNotesID = "meetingNotes"

    public static let builtIns: [Persona] = [
        Persona(id: interviewID, name: "Interview", isBuiltIn: true, systemPrompt: """
            You are a discreet real-time coach for a candidate in a job interview. The interviewer's latest question is given below. \
            Write the answer the candidate can say out loud: first person, natural spoken language, confident and honest, no filler. \
            Lead with the point, then one concrete example using the situation, action and result. Never invent employers, dates or numbers \
            the conversation has not mentioned; if a detail is missing, use a clearly marked placeholder such as [your result].
            """),
        Persona(id: salesID, name: "Sales", isBuiltIn: true, systemPrompt: """
            You are a real-time assistant for a salesperson on a live call. The prospect's latest question or objection is given below. \
            Suggest what to say next: acknowledge the concern, answer it directly, and move the conversation forward with a question. \
            Be truthful, never promise features or prices the conversation has not established, and keep a warm, consultative tone.
            """),
        Persona(id: codingID, name: "Coding", isBuiltIn: true, systemPrompt: """
            You are a real-time assistant for a software engineer in a technical discussion or coding interview. Answer the question \
            precisely: state the approach first, then the key steps, then complexity or trade-offs. Use fenced code blocks with a language \
            tag for code and inline code for identifiers. Prefer clear, idiomatic solutions over clever ones.
            """),
        Persona(id: meetingNotesID, name: "Meeting notes", isBuiltIn: true, suggestsAnswers: false, systemPrompt: """
            You are a quiet note-taker in a meeting. You do not suggest answers. When asked, summarise what was said as short bullets, \
            listing decisions and open questions separately.
            """),
    ]

    public static func builtIn(_ id: String) -> Persona? { builtIns.first { $0.id == id } }
    public static let `default` = builtIns[0]
}

/// The persona list and which one is active, persisted in `UserDefaults` (R14, R15).
@MainActor @Observable
public final class PersonaStore {
    public static let listKey = "personas.v1"
    /// Same key the old enum used, so an existing choice ("interview", "meetingNotes"…) carries over.
    public static let activeKey = "persona"

    public private(set) var personas: [Persona]
    public private(set) var activeID: String

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var list = (defaults.data(forKey: Self.listKey).flatMap { try? JSONDecoder().decode([Persona].self, from: $0) }) ?? []
        // Built-ins always exist, are flagged as built-in and never lose their place at the front.
        for b in Persona.builtIns.reversed() where !list.contains(where: { $0.id == b.id }) { list.insert(b, at: 0) }
        for i in list.indices {
            let builtIn = Persona.builtIn(list[i].id)
            list[i].isBuiltIn = builtIn != nil
            if let builtIn { list[i].suggestsAnswers = builtIn.suggestsAnswers }
        }
        personas = list
        let stored = defaults.string(forKey: Self.activeKey) ?? ""
        activeID = list.contains { $0.id == stored } ? stored : Persona.default.id
    }

    public var active: Persona { personas.first { $0.id == activeID } ?? Persona.default }

    /// For pickers: reading gives the active id, writing selects it.
    public var selection: String { get { activeID } set { select(newValue) } }

    public func persona(_ id: String) -> Persona? { personas.first { $0.id == id } }

    public func select(_ id: String) {
        guard persona(id) != nil else { return }
        activeID = id
        defaults.set(id, forKey: Self.activeKey)
    }

    public func update(_ id: String, name: String? = nil, systemPrompt: String? = nil, length: AnswerLength? = nil) {
        guard let i = personas.firstIndex(where: { $0.id == id }) else { return }
        if let name, !personas[i].isBuiltIn { personas[i].name = name }
        if let systemPrompt { personas[i].systemPrompt = systemPrompt }
        if let length { personas[i].length = length }
        save()
    }

    /// Restores a built-in's prompt and length. Custom personas have no default, so this does nothing for them.
    public func reset(_ id: String) {
        guard let i = personas.firstIndex(where: { $0.id == id }), let original = Persona.builtIn(id) else { return }
        personas[i] = original
        save()
    }

    @discardableResult
    public func create(name: String, systemPrompt: String) -> Persona {
        let p = Persona(id: "custom-" + UUID().uuidString, name: uniqueName(name), systemPrompt: systemPrompt)
        personas.append(p)
        save()
        return p
    }

    @discardableResult
    public func duplicate(_ id: String) -> Persona? {
        guard let src = persona(id) else { return nil }
        var copy = src
        copy.id = "custom-" + UUID().uuidString
        copy.name = uniqueName(src.name + " copy")
        copy.isBuiltIn = false
        personas.append(copy)
        save()
        return copy
    }

    /// Built-ins cannot be deleted. Deleting the active persona selects the first built-in (Interview).
    @discardableResult
    public func delete(_ id: String) -> Bool {
        guard let i = personas.firstIndex(where: { $0.id == id }), !personas[i].isBuiltIn else { return false }
        personas.remove(at: i)
        if activeID == id { select(Persona.default.id) }
        save()
        return true
    }

    private func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "New persona" : trimmed
        guard personas.contains(where: { $0.name == name }) else { return name }
        var n = 2
        while personas.contains(where: { $0.name == "\(name) \(n)" }) { n += 1 }
        return "\(name) \(n)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(personas) { defaults.set(data, forKey: Self.listKey) }
    }
}
