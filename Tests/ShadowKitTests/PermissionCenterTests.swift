import XCTest
@testable import ShadowKit

@MainActor
final class PermissionCenterTests: XCTestCase {
    private func history() -> PermissionHistory {
        let d = UserDefaults(suiteName: "perm-\(UUID().uuidString)")!
        return PermissionHistory(defaults: d)
    }

    // A2
    func testAllowRegistersEveryTimeEvenAfterDenial() async {
        let checker = MutableChecker(mic: .notGranted, screen: .notGranted), reg = FakeRegistrar()
        let center = PermissionCenter(checker: checker, registrar: reg, history: history())
        _ = await center.allow(.screen)
        let items = await center.allow(.screen)
        XCTAssertEqual(reg.registered, [.screen, .screen])
        XCTAssertEqual(items.map(\.kind), [.screen, .microphone])
        _ = await center.allow(.microphone)
        XCTAssertEqual(reg.registered, [.screen, .screen, .microphone])
    }

    // A8
    func testStaleOnlyAfterRecordedGrantAndClearsWhenGrantedAgain() async {
        let checker = MutableChecker(mic: .granted, screen: .notGranted), h = history()
        let center = PermissionCenter(checker: checker, registrar: FakeRegistrar(), history: h)
        XCTAssertEqual(center.items().map(\.isStale), [false])   // never granted: not stale
        XCTAssertNil(center.items()[0].staleText)
        checker.set(.screen, .granted)
        XCTAssertTrue(center.items().isEmpty)                    // records the grant
        XCTAssertTrue(h.wasGranted(.screen))
        checker.set(.screen, .notGranted)
        let stale = center.items()
        XCTAssertEqual(stale.map(\.isStale), [true])
        XCTAssertEqual(stale[0].staleText, "macOS no longer lists Shadow as allowed (this happens when the app is rebuilt or its signature changed)")
        checker.set(.screen, .granted)
        XCTAssertTrue(center.items().isEmpty)                    // granted again: no row, no stale text
    }

    func testHistoryKeepsOnlyBooleans() {
        let d = UserDefaults(suiteName: "perm-\(UUID().uuidString)")!
        let h = PermissionHistory(defaults: d)
        h.record(.microphone, state: .notGranted)
        XCTAssertFalse(h.wasGranted(.microphone))
        h.record(.microphone, state: .granted)
        XCTAssertTrue(h.wasGranted(.microphone))
        XCTAssertFalse(h.wasGranted(.screen))
        XCTAssertEqual(d.object(forKey: PrefsDefaults.permissionGrantedMicrophone) as? Bool, true)
    }

    // A4 (Start path): one registration per missing kind, none for granted ones
    func testRegisterMissingRegistersOnlyMissingOnce() async {
        let reg = FakeRegistrar()
        let center = PermissionCenter(checker: MutableChecker(mic: .granted, screen: .notYetAsked), registrar: reg, history: history())
        await center.registerMissing()
        XCTAssertEqual(reg.registered, [.screen])
        let none = FakeRegistrar()
        await PermissionCenter(checker: MutableChecker(mic: .granted, screen: .granted), registrar: none, history: history()).registerMissing()
        XCTAssertEqual(none.registered, [])
    }

    // A5
    func testLaunchDecisionTable() {
        typealias L = LaunchRegistration
        XCTAssertEqual(L.decide(onboardingCompleted: true, missing: [.microphone, .screen, .screen], alreadyRan: false), .register([.screen, .microphone]))
        XCTAssertEqual(L.decide(onboardingCompleted: true, missing: [.microphone], alreadyRan: false), .register([.microphone]))
        XCTAssertEqual(L.decide(onboardingCompleted: false, missing: [.screen], alreadyRan: false), .skip)
        XCTAssertEqual(L.decide(onboardingCompleted: true, missing: [], alreadyRan: false), .skip)
        XCTAssertEqual(L.decide(onboardingCompleted: true, missing: [.screen], alreadyRan: true), .skip)
    }

    func testRegisterOnLaunchRunsAtMostOncePerLaunch() async {
        let reg = FakeRegistrar()
        let center = PermissionCenter(checker: MutableChecker(mic: .notGranted, screen: .notGranted), registrar: reg, history: history())
        await center.registerOnLaunch(onboardingCompleted: true)
        await center.registerOnLaunch(onboardingCompleted: true)
        XCTAssertEqual(reg.registered, [.screen, .microphone])
    }

    func testRegisterOnLaunchDoesNothingBeforeOnboardingOrWhenGranted() async {
        let reg = FakeRegistrar()
        await PermissionCenter(checker: MutableChecker(mic: .notGranted, screen: .notGranted), registrar: reg, history: history())
            .registerOnLaunch(onboardingCompleted: false)
        await PermissionCenter(checker: MutableChecker(mic: .granted, screen: .granted), registrar: reg, history: history())
            .registerOnLaunch(onboardingCompleted: true)
        XCTAssertEqual(reg.registered, [])
    }

    // A6
    func testNeedsAttentionWhileMissingAfterLaunchAndClearsWhenGranted() async {
        let checker = MutableChecker(mic: .granted, screen: .notGranted)
        let center = PermissionCenter(checker: checker, registrar: FakeRegistrar(), history: history())
        XCTAssertFalse(center.needsAttention)
        await center.registerOnLaunch(onboardingCompleted: true)
        XCTAssertTrue(center.needsAttention)
        checker.set(.screen, .granted)
        center.items()
        XCTAssertFalse(center.needsAttention)
    }
}
