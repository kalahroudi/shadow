// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A run of text inside a paragraph or bullet (R17).
public enum MarkdownInline: Equatable, Sendable {
    case text(String), bold(String), code(String)
}

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case bullet([MarkdownInline])
    /// `isClosed` is false for a fence the model has not finished yet, so a streaming answer renders as code at once.
    case code(language: String?, text: String, isClosed: Bool)
}

/// A small, forgiving parser for the subset the answers use: bullets, bold, inline code and fenced code blocks.
/// It is run on every streamed update, so it never throws and tolerates half-written markup.
public enum MarkdownParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlines(paragraph.joined(separator: " "))))
            paragraph = []
        }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: fence!.language, text: fence!.lines.joined(separator: "\n"), isClosed: true))
                    fence = nil
                } else { fence!.lines.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fence = (lang.isEmpty ? nil : lang, [])
            } else if let item = bulletText(trimmed) {
                flushParagraph()
                blocks.append(.bullet(inlines(item)))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        if let fence { blocks.append(.code(language: fence.language, text: fence.lines.joined(separator: "\n"), isClosed: false)) }
        return blocks
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
        return nil
    }

    /// `**bold**` and `` `code` ``. Markup that is never closed stays plain text.
    public static func inlines(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var plain = ""
        var rest = Substring(text)
        func flush() { if !plain.isEmpty { out.append(.text(plain)); plain = "" } }
        while let c = rest.first {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                flush(); out.append(.bold(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])))
                rest = rest[end.upperBound...]
            } else if c == "`", let end = rest.dropFirst().firstIndex(of: "`"), end > rest.index(after: rest.startIndex) {
                flush(); out.append(.code(String(rest[rest.index(after: rest.startIndex)..<end])))
                rest = rest[rest.index(after: end)...]
            } else {
                plain.append(c); rest = rest.dropFirst()
            }
        }
        flush()
        return out
    }
}
