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
