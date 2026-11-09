// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which form the menu bar glyph takes. The two forms differ in shape, not only colour (R16).
public enum GlyphState: Sendable, Equatable {
    case idle, recording

    public static func from(sessionRunning: Bool) -> GlyphState { sessionRunning ? .recording : .idle }
}

/// Answer now could not keep its default shortcut because a saved shortcut already uses it.
public struct AnswerNowMove: Equatable, Sendable {
    public var wanted: Hotkey
    public var moved: Hotkey
    public var usedBy: HotkeyAction

    /// "Answer now moved to ⌘⌥A because ⌘⇧A is already used by Compact / expand."
    public var message: String {
        "Answer now moved to \(moved.display) because \(wanted.display) is already used by \(usedBy.label)."
    }
}

extension Dictionary where Key == HotkeyAction, Value == Hotkey {
    /// Reads one string per action; a missing, invalid or conflicting entry falls back to the default, so a bad value never unbinds an action.
    /// A saved shortcut always wins over Answer now's default: Answer now moves to the first free alternative instead.
    public static func stored(_ read: (HotkeyAction) -> String?) -> HotkeyMap { storedResolvingAnswerNow(read).map }

    /// `stored` plus, when Answer now had to leave its shortcut, what moved and why.
    public static func storedResolvingAnswerNow(_ read: (HotkeyAction) -> String?) -> (map: HotkeyMap, move: AnswerNowMove?) {
        var map = HotkeyMap.defaults
        map[.answerNow] = nil
        for action in HotkeyAction.allCases where action != .answerNow {
            guard let text = read(action), let key = Hotkey(text),
                  !map.contains(where: { $0.key != action && $0.value == key }) else { continue }
            map[action] = key
        }
        let taken = Set(map.values)
        let defaultKey = HotkeyMap.defaults[.answerNow]!
        let wanted = read(.answerNow).flatMap { Hotkey($0) } ?? defaultKey
        if !taken.contains(wanted) { map[.answerNow] = wanted; return (map, nil) }
        // A saved Answer now shortcut that clashes falls back to the default first, then the alternatives, in a fixed order.
        let alternatives = [defaultKey] + Hotkey.answerNowAlternatives
        let chosen = alternatives.first { !taken.contains($0) } ?? Hotkey.answerNowAlternatives.last!
        map[.answerNow] = chosen
        let owner = map.first { $0.value == wanted }?.key ?? .answerNow
        return (map, chosen == wanted ? nil : AnswerNowMove(wanted: wanted, moved: chosen, usedBy: owner))
    }
}

extension Hotkey {
    /// Cmd-Option-A, Cmd-Control-A, then the three-modifier forms: more than there are other actions, so one is always free.
    public static let answerNowAlternatives: [Hotkey] = [
        Hotkey(keyCode: 0, modifiers: [.command, .option]), Hotkey(keyCode: 0, modifiers: [.command, .control]),
        Hotkey(keyCode: 0, modifiers: [.command, .option, .shift]), Hotkey(keyCode: 0, modifiers: [.command, .control, .shift]),
        Hotkey(keyCode: 0, modifiers: [.command, .option, .control]),
    ]
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
