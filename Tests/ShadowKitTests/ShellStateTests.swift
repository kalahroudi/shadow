import XCTest
@testable import ShadowKit

final class ShellStateTests: XCTestCase {
    func testGlyphStateMapsIdleAndRecording() {
        XCTAssertEqual(GlyphState.from(sessionRunning: false), .idle)
        XCTAssertEqual(GlyphState.from(sessionRunning: true), .recording)
    }

    func testDisplayShowsKeycaps() {
        XCTAssertEqual(HotkeyMap.defaults[.toggleSession]?.display, "⌘⇧Space")
        XCTAssertEqual(HotkeyMap.defaults[.toggleOverlay]?.display, "⌘⇧H")
    }

    func testPersonaDefaultsToInterview() {
        XCTAssertEqual(Persona.default.id, "interview")
        XCTAssertEqual(Persona.builtIns.map(\.label), ["Interview", "Sales", "Coding", "Meeting notes"])
    }

    func testStoredHotkeysFallBackToDefaults() {
        XCTAssertEqual(HotkeyMap.stored { _ in nil }, HotkeyMap.defaults)
        let map = HotkeyMap.stored { $0 == .toggleOverlay ? "cmd+opt+o" : "garbage" }
        XCTAssertEqual(map[.toggleOverlay], Hotkey("cmd+opt+o"))
        XCTAssertEqual(map[.toggleSession], HotkeyMap.defaults[.toggleSession])
    }

    func testStoredHotkeysRejectDuplicates() {
        // Click-through tries to take the session key: it keeps its own default instead.
        let map = HotkeyMap.stored { $0 == .toggleClickThrough ? "cmd+shift+space" : nil }
        XCTAssertEqual(map[.toggleClickThrough], HotkeyMap.defaults[.toggleClickThrough])
    }

    func testFreshInstallGetsCmdShiftA() {
        let r = HotkeyMap.storedResolvingAnswerNow { _ in nil }
        XCTAssertEqual(r.map[.answerNow], Hotkey("cmd+shift+a"))
        XCTAssertNil(r.move)
    }

    func testSavedBindingOnDefaultAnswerNowKeyWinsAndAnswerNowMoves() {
        let r = HotkeyMap.storedResolvingAnswerNow { $0 == .toggleCompact ? "cmd+shift+a" : nil }
        XCTAssertEqual(r.map[.toggleCompact], Hotkey("cmd+shift+a"), "the user's saved binding is kept")
        XCTAssertEqual(r.map[.answerNow], Hotkey("cmd+opt+a"))
        XCTAssertEqual(r.move?.message, "Answer now moved to ⌥⌘A because ⌘⇧A is already used by Compact / expand.")
        XCTAssertEqual(HotkeyMap.stored { $0 == .toggleCompact ? "cmd+shift+a" : nil }, r.map)
    }

    func testAnswerNowFallbackIsDeterministicAndNeverCollides() {
        let saved: [HotkeyAction: String] = [.toggleCompact: "cmd+shift+a", .toggleOverlay: "cmd+opt+a", .toggleClickThrough: "cmd+ctrl+a"]
        let r = HotkeyMap.storedResolvingAnswerNow { saved[$0] }
        XCTAssertEqual(r.map[.answerNow], Hotkey("cmd+opt+shift+a"))
        XCTAssertEqual(r.map.count, HotkeyAction.allCases.count, "Answer now is never unbound")
        XCTAssertEqual(Set(r.map.values).count, r.map.count, "no two actions share a shortcut")
        XCTAssertEqual(HotkeyMap.storedResolvingAnswerNow { saved[$0] }.map, r.map)
        let ctrl = HotkeyMap.storedResolvingAnswerNow { $0 == .toggleCompact ? "cmd+shift+a" : $0 == .toggleOverlay ? "cmd+opt+a" : nil }
        XCTAssertEqual(ctrl.map[.answerNow], Hotkey("cmd+ctrl+a"))
    }

    func testSavedAnswerNowBindingIsKeptAndEveryFallbackIsFree() {
        XCTAssertEqual(HotkeyMap.stored { $0 == .answerNow ? "cmd+opt+j" : nil }[.answerNow], Hotkey("cmd+opt+j"))
        // Even with every other action on an alternative, Answer now finds a free key.
        let saved: [HotkeyAction: String] = [.toggleSession: "cmd+shift+a", .toggleOverlay: "cmd+opt+a",
                                             .toggleClickThrough: "cmd+ctrl+a", .toggleCompact: "cmd+opt+shift+a"]
        let m = HotkeyMap.stored { saved[$0] }
        XCTAssertEqual(Set(m.values).count, m.count)
    }

    func testConflictMessageNamesRefusedActions() {
        XCTAssertNil(HotkeyAction.conflictMessage(for: [HotkeyAction]()))
        XCTAssertTrue(HotkeyAction.conflictMessage(for: [.toggleSession])!.contains("“\(HotkeyAction.toggleSession.label)”"))
        let two = HotkeyAction.conflictMessage(for: [.toggleCompact, .toggleOverlay])!
        XCTAssertTrue(two.contains("\(HotkeyAction.toggleOverlay.label)”, ") || two.contains("” and “"))
    }

    func testNoSourceUsesSharingTypeNone() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for f in files { XCTAssertFalse(try String(contentsOf: f, encoding: .utf8).contains("sharingType"), f.lastPathComponent) }
    }
}
