// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the classifier made of a turn.
public enum QuestionResult: Equatable, Sendable {
    case question(String)
    case notQuestion

    public var text: String? { if case .question(let t) = self { t } else { nil } }
}

/// LLM-free detection of questions and requests in English, Spanish, German, French and Japanese (R11).
/// Judges the final sentence of a turn: a turn "ends in a question or request" when its last sentence is one.
public enum QuestionClassifier {
    public static func classify(_ turn: String) -> QuestionResult {
        let sentences = split(turn)
        guard let last = sentences.last else { return .notQuestion }
        return isQuestion(last) ? .question(last) : .notQuestion
    }

    /// Sentences with their terminators, trimmed; empty pieces dropped.
    static func split(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(text.replacingOccurrences(of: "’", with: "'"))
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // a "." inside "3.5" or "e.g.x" does not end a sentence; it must be followed by a space or the end
            let ends = ch == "." ? (i + 1 == chars.count || chars[i + 1].isWhitespace) : "!?。！？".contains(ch)
            if ends { out.append(cur); cur = "" }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let raw = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("¿") { return true }
        if raw.last == "?" || raw.last == "？" { return true }
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!。！ \t\n"))
        if japanese(body) { return true }
        let words = tokens(body)
        guard words.count >= 2 else { return false }
        return rules.contains { $0.matches(words, joined: words.joined(separator: " ")) }
    }

    // MARK: tokens

    private static func tokens(_ s: String) -> [String] {
        var t = s.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",;:\"“”()[]¡"))
        }.filter { !$0.isEmpty }
        // leading fillers never decide anything
        while let f = t.first, fillers.contains(f), t.count > 2 { t.removeFirst() }
        return t
    }

    private static let fillers: Set<String> = ["so", "ok", "okay", "well", "and", "um", "uh", "please", "now", "then", "alright",
                                               "bueno", "pues", "entonces", "also", "ja", "na", "ähm", "alors", "bon", "donc", "et", "eh"]

    // MARK: Latin-script rules

    private struct Rules {
        var wh: Set<String> = []                 // interrogative openers
        var whBlockedBy: Set<String> = []        // "what I mean" / "how I got here" are statements
        var aux: Set<String> = []                // verb-first openers, need a subject next
        var subjects: Set<String> = []
        var openers: Set<String> = []            // inverted forms that stand alone ("pouvez-vous")
        var requests: [String] = []              // word-prefix phrases

        func matches(_ w: [String], joined: String) -> Bool {
            if requests.contains(where: { joined == $0 || joined.hasPrefix($0 + " ") }) { return true }
            if wh.contains(w[0]), !whBlockedBy.contains(w[1]) { return true }
            if openers.contains(w[0]) { return true }
            if ["por", "para"].contains(w[0]), w[1] == "qué" { return true }
            if aux.contains(w[0]), subjects.contains(w[1]) { return true }
            return false
        }
    }

    private static let rules: [Rules] = [
        Rules(
            wh: ["what", "what's", "what're", "why", "how", "how's", "when", "where", "where's", "who", "who's", "whom", "whose", "which"],
            whBlockedBy: ["i", "we", "i'd", "i'm", "i've", "i'll", "you", "he", "she", "they"],
            aux: ["is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "shall", "have", "has", "had",
                  "am", "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't", "haven't", "hasn't"],
            subjects: ["you", "i", "we", "they", "he", "she", "it", "there", "this", "that", "anyone", "anybody"],
            requests: ["tell me", "tell us", "walk me through", "walk us through", "talk me through", "talk about", "explain", "describe",
                       "give me", "give us", "show me", "i'd like you to", "i would like you to", "i want to hear", "let's hear"]),
        Rules(
            wh: ["qué", "cómo", "cuándo", "cuál", "cuáles", "cuánto", "cuánta", "cuántos", "cuántas", "dónde", "quién", "quiénes", "adónde"],
            requests: ["dime", "cuéntame", "cuéntanos", "explícame", "explícanos", "háblame", "descríbeme", "explica", "describe", "dame",
                       "podrías", "podría", "puedes", "puede usted", "pueden", "me puedes", "me podrías", "me gustaría que", "quisiera saber"]),
        Rules(
            wh: ["was", "wie", "wann", "wo", "wer", "wen", "wem", "wessen", "warum", "wieso", "weshalb", "welche", "welcher", "welches",
                 "welchen", "wohin", "woher", "womit", "wofür", "wodurch"],
            whBlockedBy: ["ich", "wir", "gesagt", "erwähnt"],
            aux: ["kannst", "kann", "können", "könnten", "könntest", "könnt", "würdest", "würden", "würde", "hast", "haben", "habt",
                  "bist", "sind", "ist", "gibt", "darf", "dürfen", "soll", "sollen", "willst", "wollen", "muss", "musst", "müssen", "hat"],
            subjects: ["du", "sie", "ihr", "ich", "wir", "man", "es", "das", "er", "es", "mir", "uns", "jemand", "dies"],
            requests: ["erzähl", "erzähle", "erzählen sie", "erkläre", "erklär", "erklären sie", "beschreibe", "beschreiben sie",
                       "sag mir", "sagen sie mir", "gib mir", "nenne", "nennen sie"]),
        Rules(
            wh: ["comment", "pourquoi", "quand", "où", "qui", "quel", "quelle", "quels", "quelles", "combien", "qu'est-ce", "est-ce",
                 "lequel", "laquelle", "quoi"],
            whBlockedBy: ["je", "j'", "nous"],
            openers: ["pouvez-vous", "peux-tu", "pourriez-vous", "pourrais-tu", "avez-vous", "as-tu", "es-tu", "êtes-vous", "est-il", "est-elle",
                      "sommes-nous", "savez-vous", "sais-tu", "voulez-vous", "veux-tu", "peut-on", "a-t-il", "a-t-elle"],
            requests: ["dites-moi", "dis-moi", "explique", "expliquez", "explique-moi", "expliquez-moi", "décris", "décrivez", "raconte",
                       "racontez", "parlez-moi", "parle-moi", "donne-moi", "donnez-moi", "pouvez-vous", "peux-tu", "pourriez-vous", "pourrais-tu"]),
    ]

    // MARK: Japanese

    private static let jaEndings = ["か", "かな", "かね"]
    /// A request is a sentence that ends in the request; "教えてくれました" (he told me) and "よろしくお願いします" (a greeting) are not.
    private static let jaRequests = ["ください", "下さい", "お願いします", "お願いいたします", "お願い", "教えて", "説明して", "話して", "聞かせて", "答えて",
                                     "教えてほしい", "教えてもらいたい"]
    private static let jaWh = ["なぜ", "どうして", "どのよう", "どうやって", "どんな", "何", "いつ", "どこ", "誰", "どれ", "どの", "いくつ", "いくら", "どう"]

    private static func japanese(_ s: String) -> Bool {
        guard s.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) else { return false }
        if s.hasPrefix("なぜなら") { return false }
        if jaEndings.contains(where: { s.hasSuffix($0) }) { return true }
        if s.hasPrefix("よろしく") || s.hasPrefix("どうぞよろしく") { return false }
        if jaRequests.contains(where: { s.hasSuffix($0) }) { return true }
        // a question word with a closing の / かな / だろう is a question even without か
        return jaWh.contains(where: { s.contains($0) }) && (s.hasSuffix("の") || s.hasSuffix("だろう") || s.hasSuffix("でしょう"))
    }
}
