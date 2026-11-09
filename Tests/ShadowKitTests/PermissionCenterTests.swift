import XCTest
@testable import ShadowKit

private final class FakeRegistrar: PermissionRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [PermissionKind] = []
    var registered: [PermissionKind] { lock.withLock { calls } }
    func register(_ kind: PermissionKind) async { lock.withLock { calls.append(kind) } }
}

private final class MutableChecker: PermissionChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PermissionKind: PermissionState]
    init(mic: PermissionState, screen: PermissionState) { states = [.microphone: mic, .screen: screen] }
    func set(_ kind: PermissionKind, _ s: PermissionState) { lock.withLock { states[kind] = s } }
    func status(_ kind: PermissionKind) -> PermissionState { lock.withLock { states[kind]! } }
    func request(_ kind: PermissionKind) async -> PermissionState { status(kind) }
}

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
}
