import XCTest
@testable import ShadowKit

private struct FakeChecker: PermissionChecker {
    var mic: PermissionState, screen: PermissionState
    func status(_ kind: PermissionKind) -> PermissionState { kind == .screen ? screen : mic }
    func request(_ kind: PermissionKind) async -> PermissionState { .granted }
}

final class OnboardingTests: XCTestCase {
    // A7: every combination of states
    func testChecklistForEveryCombination() {
        let states: [PermissionState] = [.granted, .notGranted, .notYetAsked]
        for mic in states { for screen in states {
            let items = Checklist.items(using: FakeChecker(mic: mic, screen: screen))
            var expected: [PermissionKind] = []
            if screen != .granted { expected.append(.screen) }
            if mic != .granted { expected.append(.microphone) }
            XCTAssertEqual(items.map(\.kind), expected, "mic \(mic) screen \(screen)")
            for i in items {
                XCTAssertTrue(i.settingsURL.hasPrefix("x-apple.systempreferences:"))
                XCTAssertFalse(i.explanation.isEmpty)
                XCTAssertEqual(i.canRequest, i.state == .notYetAsked)
                XCTAssertEqual(i.note != nil, i.kind == .screen)   // only screen recording needs the relaunch note
            }
        } }
    }

    // A8: step order, Back/Continue, consent gating
    func testStepsInOrderAndFinishBlockedUntilConsent() {
        var m = OnboardingModel()
        XCTAssertFalse(m.canGoBack)
        var seen = [m.step]
        for _ in 0..<3 { XCTAssertFalse(m.advance()); seen.append(m.step) }
        XCTAssertEqual(seen, [.welcome, .permissions, .provider, .consent])
        XCTAssertTrue(m.isLastStep)
        XCTAssertFalse(m.canAdvance)
        XCTAssertFalse(m.advance())            // blocked
        XCTAssertEqual(m.step, .consent)
        m.consentAcknowledged = true
        XCTAssertTrue(m.advance())             // finish
        m.back(); XCTAssertEqual(m.step, .provider)
    }

    func testOnlyOnDeviceProviderSelectable() {
        var m = OnboardingModel()
        XCTAssertEqual(ProviderOption.allCases.filter(\.isAvailable), [.onDevice])
        for o in ProviderOption.allCases where o != .onDevice { m.select(o); XCTAssertEqual(m.provider, .onDevice) }
    }

    func testPrefsDefaults() {
        let suite = "shadow-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        PrefsDefaults.register(in: d)
        XCTAssertTrue(d.bool(forKey: PrefsDefaults.remindBeforeSession))
        XCTAssertFalse(d.bool(forKey: PrefsDefaults.onboardingCompleted))
        XCTAssertTrue(PrefsDefaults.visibleMode)
        XCTAssertTrue(d.bool(forKey: PrefsDefaults.autoUpdateChecks))
        XCTAssertFalse(d.bool(forKey: PrefsDefaults.localOnly))
        XCTAssertNil(d.object(forKey: PrefsDefaults.lastUpdateCheck))
    }
}
