import XCTest
@testable import ShadowKit

final class SettingsContentTests: XCTestCase {
    func testPanesAreExactlyTheFourWithContent() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Speech", "Hotkeys", "Privacy", "General"])
        XCTAssertFalse(SettingsPane.allCases.contains { $0.title.lowercased().contains("update") })
    }

    func testFooterSaysSettingsSaveAutomatically() {
        XCTAssertEqual(SettingsPane.footer, "Settings save automatically.")
    }

    func testPrivacyCopyStatesVisibleModeAndNoAudioOnDisk() {
        XCTAssertTrue(PrivacyCopy.noAudioOnDisk.contains("never written to disk"))
        XCTAssertTrue(PrivacyCopy.visibleMode.contains("cannot be hidden"))
        XCTAssertTrue(PrivacyCopy.consentNote.contains("consent"))
    }

    func testRecordedUnknownKeyIsRejectedWithFriendlyMessage() {
        // The recorder builds a Hotkey from raw key codes; one we can't name must not bind.
        let odd = Hotkey(keyCode: 200, modifiers: [.command])
        if case .success = HotkeyMap.defaults.binding(.toggleOverlay, to: odd.string) { XCTFail("accepted unknown key") }
    }

    func testMicDeviceUIDReadsTheKeyTheSettingsPickerWrites() {
        let d = UserDefaults(suiteName: "mic-test-\(UUID().uuidString)")!
        XCTAssertNil(PrefsDefaults.micDeviceUID(in: d))
        d.set("", forKey: PrefsDefaults.micDeviceID)
        XCTAssertNil(PrefsDefaults.micDeviceUID(in: d))
        d.set("AppleUSBAudio:1234", forKey: PrefsDefaults.micDeviceID)
        XCTAssertEqual(PrefsDefaults.micDeviceUID(in: d), "AppleUSBAudio:1234")
    }
}
