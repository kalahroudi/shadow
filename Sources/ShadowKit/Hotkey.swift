// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A global shortcut: Carbon key code plus modifiers (R18). Strings look like "cmd+shift+space".
public struct Hotkey: Sendable, Equatable, Hashable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers
    public init(keyCode: UInt32, modifiers: Modifiers) { self.keyCode = keyCode; self.modifiers = modifiers }

    // ANSI virtual key codes.
    fileprivate static let keys: [(String, UInt32)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ("return", 36), ("tab", 48), ("space", 49), ("escape", 53),
        ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]
    private static let modifierNames: [(String, Modifiers)] = [
        ("cmd", .command), ("shift", .shift), ("opt", .option), ("ctrl", .control),
    ]

    public init?(_ string: String) {
        var mods: Modifiers = []
        var key: UInt32?
        for raw in string.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let part = String(raw).trimmingCharacters(in: .whitespaces)
            if let m = Self.modifierNames.first(where: { $0.0 == part })?.1 {
                guard !mods.contains(m) else { return nil }
                mods.insert(m)
            } else if let k = Self.keys.first(where: { $0.0 == part })?.1 {
                guard key == nil else { return nil }
                key = k
            } else { return nil }
        }
        // A global shortcut without a modifier would hijack normal typing.
        guard let key, !mods.isEmpty else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    public var string: String {
        let mods = Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0)
        let key = Self.keys.first { $0.1 == keyCode }?.0 ?? "?"
        return (mods + [key]).joined(separator: "+")
    }
}

extension Hotkey {
    /// The keycap form for the UI, e.g. "⌘⇧Space".
    public var display: String {
        let glyphs: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.command, "⌘"), (.shift, "⇧")]
        let key = Self.keys.first { $0.1 == keyCode }?.0 ?? "?"
        let name = key.count == 1 ? key.uppercased() : key.capitalized
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + name
    }
}

public enum HotkeyAction: String, CaseIterable, Sendable, Codable {
    case toggleSession, toggleOverlay, toggleClickThrough, toggleCompact, answerNow, copyAnswer

    public var label: String {
        switch self {
        case .toggleSession: "Start / stop session"
        case .toggleOverlay: "Show / hide overlay"
        case .toggleClickThrough: "Toggle click-through"
        case .toggleCompact: "Compact / expand"
        case .answerNow: "Answer now"
        case .copyAnswer: "Copy answer"
        }
    }
}

public typealias HotkeyMap = [HotkeyAction: Hotkey]

extension Dictionary where Key == HotkeyAction, Value == Hotkey {
    public static var defaults: HotkeyMap {
        let cs: Hotkey.Modifiers = [.command, .shift]
        return [.toggleSession: Hotkey(keyCode: 49, modifiers: cs), .toggleOverlay: Hotkey(keyCode: 4, modifiers: cs),
                .toggleClickThrough: Hotkey(keyCode: 17, modifiers: cs), .toggleCompact: Hotkey(keyCode: 14, modifiers: cs),
                .answerNow: Hotkey(keyCode: 0, modifiers: cs), .copyAnswer: Hotkey(keyCode: 8, modifiers: cs)]
    }

    /// Binds `action` to the typed string, or explains in one friendly sentence why it can't.
    public func binding(_ action: HotkeyAction, to string: String) -> Result<HotkeyMap, UserFacingError> {
        guard let key = Hotkey(string) else {
            return .failure(UserFacingError("That shortcut isn't valid. Use at least one modifier key plus a letter, number or space."))
        }
        if let other = first(where: { $0.key != action && $0.value == key })?.key {
            return .failure(UserFacingError("That shortcut is already used for “\(other.label)”."))
        }
        var copy = self
        copy[action] = key
        return .success(copy)
    }
}
