// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Notice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
}

public enum NoticeText {
    /// Trims the text and makes it end in exactly one full stop (or keeps a trailing "!" or "?"), so joined sentences never show "..".
    public static func sentence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") || s.hasSuffix("…") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        if s.isEmpty { return "" }
        return s.hasSuffix("!") || s.hasSuffix("?") ? s : s + "."
    }
}

/// The notices the popover shows: one per line, identical ones collapsed, each dismissible on its own.
public struct NoticeCenter: Sendable, Equatable {
    public private(set) var notices: [Notice] = []
    public init() {}

    /// Returns true when a new line was added (false for a blank or already-shown notice).
    @discardableResult
    public mutating func add(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !notices.contains(where: { $0.text == t }) else { return false }
        notices.append(Notice(id: UUID(), text: t))
        return true
    }

    public mutating func dismiss(id: Notice.ID) { notices.removeAll { $0.id == id } }
    public mutating func clear() { notices = [] }
    public var joined: String? { notices.isEmpty ? nil : notices.map(\.text).joined(separator: "\n") }
}
