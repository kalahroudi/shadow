// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which form the menu bar glyph takes. The two forms differ in shape, not only colour (R16).
public enum GlyphState: Sendable, Equatable {
    case idle, recording

    public static func from(sessionRunning: Bool) -> GlyphState { sessionRunning ? .recording : .idle }
}

/// The persona choices in the popover. UI only in milestone 1: nothing reads the value yet (R17).
public enum Persona: String, CaseIterable, Sendable, Codable {
    case interview, sales, coding, meetingNotes

    public static let `default` = Persona.interview
    public var label: String {
        switch self {
        case .interview: "Interview"
        case .sales: "Sales"
        case .coding: "Coding"
        case .meetingNotes: "Meeting notes"
        }
    }
}

extension Dictionary where Key == HotkeyAction, Value == Hotkey {
    /// Reads one string per action; a missing, invalid or conflicting entry falls back to the default, so a bad value never unbinds an action.
    public static func stored(_ read: (HotkeyAction) -> String?) -> HotkeyMap {
        var map = HotkeyMap.defaults
        for action in HotkeyAction.allCases {
            guard let text = read(action), let key = Hotkey(text),
                  !map.contains(where: { $0.key != action && $0.value == key }) else { continue }
            map[action] = key
        }
        return map
    }
}

extension HotkeyAction {
    /// One friendly sentence for shortcuts macOS refused to register, or nil when none failed. Order follows `allCases`.
    public static func conflictMessage(for failed: some Collection<HotkeyAction>) -> String? {
        let names = allCases.filter(failed.contains).map { "“\($0.label)”" }
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Another app already uses the shortcut for \(list). Pick a different one in Settings."
    }
}
