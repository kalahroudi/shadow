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
        m.record(.ready, for: .onDevice)
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

    private func readyModel(_ option: ProviderOption) -> OnboardingModel {
        var m = OnboardingModel()
        m.record(.ready, for: option)
        m.select(option)
        return m
    }

    func testEachChoiceConfiguresItsProvider() {
        let suite = "onb-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        PrefsDefaults.register(in: d)
        let expected: [ProviderOption: String] = [.onDevice: "onDevice", .localServer: "localServer", .claudeCLI: "claudeCLI", .ownKey: "anthropic"]
        XCTAssertEqual(Set(ProviderOption.allCases), Set(expected.keys))
        for (option, id) in expected {
            let m = readyModel(option)
            XCTAssertEqual(m.provider, option)
            XCTAssertNoThrow(try m.configure(LLMSettings(defaults: d)).get())
            XCTAssertEqual(LLMSettings(defaults: d).selectedProviderID, id)
        }
        var m = readyModel(.ownKey)
        m.ownKeyKind = .gemini
        XCTAssertEqual(m.providerID, "gemini")
    }

    func testOwnKeyIsRefusedWhileLocalOnly() {
        let d = UserDefaults(suiteName: "onb-\(UUID().uuidString)")!
        PrefsDefaults.register(in: d)
        d.set(true, forKey: PrefsDefaults.localOnly)
        if case .success = readyModel(.ownKey).configure(LLMSettings(defaults: d)) { XCTFail("cloud selected under Local-only") }
    }

    func testFinishingNeedsAPassingAvailabilityCheck() {
        var m = OnboardingModel(startingAt: .provider)
        XCTAssertFalse(m.canAdvance, "unchecked")
        XCTAssertFalse(m.advance())
        XCTAssertEqual(m.step, .provider)
        m.record(.needsKey, for: .onDevice)
        XCTAssertFalse(m.canAdvance, "checked but not ready")
        m.record(.ready, for: .onDevice)
        XCTAssertTrue(m.canAdvance)
        XCTAssertFalse(m.advance())
        m.consentAcknowledged = true
        XCTAssertTrue(m.canAdvance)
        // A provider that stops being ready after the user moved on still blocks finishing.
        m.record(.notRunning, for: .onDevice)
        XCTAssertFalse(m.canAdvance)
    }

    func testUnavailableOptionsExplainThemselvesAndAreNotSelectable() {
        var m = OnboardingModel()
        m.record(.unavailable("This Mac can't run Apple Intelligence."), for: .onDevice)
        m.record(.notRunning, for: .localServer)
        m.record(.needsKey, for: .ownKey)
        XCTAssertEqual(m.unavailableReason(.onDevice), "This Mac can't run Apple Intelligence.")
        XCTAssertNotNil(m.unavailableReason(.localServer))
        XCTAssertFalse(m.isSelectable(.onDevice))
        m.select(.localServer); XCTAssertEqual(m.provider, .onDevice, "unavailable choice is ignored")
        m.select(.ownKey)   // a missing key can be fixed on the spot
        XCTAssertEqual(m.provider, .ownKey)
    }

    func testSourcesHaveNoComingSoonOrAppleFMStub() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let banned = ["Coming " + "soon", "coming " + "soon", "Apple " + "FM"]
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for b in banned { XCTAssertFalse(text.contains(b), "\(url.lastPathComponent) contains \(b)") }
        }
        XCTAssertGreaterThan(checked, 20)
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
