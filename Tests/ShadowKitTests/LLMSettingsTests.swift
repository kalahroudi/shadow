import XCTest
@testable import ShadowKit

/// R5, R6 / A5, A6.
final class LLMSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "llm-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        PrefsDefaults.register(in: defaults)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultsToOnDeviceAndCloudIsNotBadged() {
        let s = LLMSettings(defaults: defaults)
        XCTAssertEqual(s.selectedProviderID, OnDeviceProvider.providerID)
        XCTAssertFalse(s.showsCloudBadge)
        XCTAssertEqual(s.localBaseURL, LoopbackURL.defaultBase)
    }

    func testSelectingCloudWorksAndShowsTheBadge() throws {
        let s = LLMSettings(defaults: defaults)
        try s.select("anthropic").get()
        XCTAssertEqual(s.selectedProviderID, "anthropic")
        XCTAssertTrue(s.showsCloudBadge)
        try s.select(OpenAICompatProvider.providerID).get()
        XCTAssertFalse(s.showsCloudBadge)
    }

    func testSelectingCloudWithLocalOnlyIsRejectedWithTheMessage() {
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        let s = LLMSettings(defaults: defaults)
        for kind in CloudKind.allCases {
            guard case .failure(let e) = s.select(kind.id) else { return XCTFail(kind.id) }
            XCTAssertEqual(e.message, LocalOnlyPolicy.message)
        }
        XCTAssertEqual(s.selectedProviderID, OnDeviceProvider.providerID)
        if case .failure = s.select(ClaudeCLIProvider.providerID) { XCTFail("local providers stay selectable") }
    }

    func testTurningLocalOnlyOnReselectsALocalProvider() throws {
        let s = LLMSettings(defaults: defaults)
        try s.select("gemini").get()
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        let outcome = s.localOnlyChanged(to: true)
        XCTAssertEqual(outcome, .init(reselected: LLMSettings.fallbackProviderID, shouldCancelCloud: true))
        XCTAssertEqual(s.selectedProviderID, LLMSettings.fallbackProviderID)
        XCTAssertFalse(CloudKind.isCloud(providerID: LLMSettings.fallbackProviderID))
        // Turning it off again does not bring the cloud choice back or cancel anything.
        XCTAssertEqual(s.localOnlyChanged(to: false), .init(reselected: nil, shouldCancelCloud: false))
        XCTAssertEqual(s.selectedProviderID, LLMSettings.fallbackProviderID)
    }

    func testLocalOnlyOnWithALocalProviderKeepsItButStillCancelsCloud() throws {
        let s = LLMSettings(defaults: defaults)
        try s.select(ClaudeCLIProvider.providerID).get()
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        XCTAssertEqual(s.localOnlyChanged(to: true), .init(reselected: nil, shouldCancelCloud: true))
        XCTAssertEqual(s.selectedProviderID, ClaudeCLIProvider.providerID)
    }

    func testAStoredCloudChoiceIsIgnoredWhileLocalOnlyIsOn() {
        defaults.set("openAI", forKey: LLMSettings.selectedKey)
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        XCTAssertEqual(LLMSettings(defaults: defaults).selectedProviderID, LLMSettings.fallbackProviderID)
    }

    func testModelPickerPerProviderWithFallback() {
        let s = LLMSettings(defaults: defaults)
        for kind in CloudKind.allCases { XCTAssertEqual(s.model(for: kind), kind.defaultModel) }
        s.setModel("gemini-2.5-pro", for: .gemini)
        s.setModel("not-a-real-model", for: .openAI)
        XCTAssertEqual(s.model(for: .gemini), "gemini-2.5-pro")
        XCTAssertEqual(s.model(for: .openAI), CloudKind.openAI.defaultModel)
        defaults.set("retired-model", forKey: "llm.model.anthropic")
        XCTAssertEqual(s.model(for: .anthropic), CloudKind.anthropic.defaultModel)
    }

    func testLocalBaseURLMustBeLoopback() throws {
        let s = LLMSettings(defaults: defaults)
        XCTAssertThrowsError(try s.setLocalBaseURL("https://api.openai.com/v1"))
        XCTAssertEqual(s.localBaseURL, LoopbackURL.defaultBase)
        try s.setLocalBaseURL(" http://127.0.0.1:8080/v1 ")
        XCTAssertEqual(s.localBaseURL, "http://127.0.0.1:8080/v1")
    }

    // MARK: Keys live only in the SecretStore (R5)

    func testSavingAKeyWritesOnlyToTheStoreAndNothingElseHoldsIt() throws {
        let key = FakeKeys.anthropicWithMarker
        let store = InMemorySecretStore()
        let s = LLMSettings(defaults: defaults)
        try store.saveKey("  \(key)\n", for: .anthropic)
        try s.select("anthropic").get(); s.setModel("claude-haiku-5-5", for: .anthropic)
        XCTAssertEqual(store.all, [CloudKind.anthropic.keyAccount: key])
        XCTAssertEqual(store.key(for: .anthropic), key)

        // Neither this suite nor the standard defaults contain the key.
        let dump = String(describing: defaults.persistentDomain(forName: suite) ?? [:]) + String(describing: UserDefaults.standard.dictionaryRepresentation())
        XCTAssertFalse(dump.contains(FakeKeys.marker))

        // Nor does a session file written in the same state.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("key-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: dir)
        let answer = AnswerRecord(question: "q", text: "a", persona: Persona.interviewID, provider: "anthropic", model: "claude-haiku-5-5")
        try sessions.write(SessionRecord(id: UUID(), startedAt: Date(), answers: [answer]))
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            XCTAssertFalse(String(decoding: try Data(contentsOf: f), as: UTF8.self).contains(FakeKeys.marker))
        }

        try store.saveKey("   ", for: .anthropic)   // empty removes it
        XCTAssertNil(store.key(for: .anthropic)); XCTAssertTrue(store.all.isEmpty)
    }

    func testKeysAreKeptPerProvider() throws {
        let store = InMemorySecretStore()
        for kind in CloudKind.allCases { try store.saveKey("key-\(kind.id)-0123456789", for: kind) }
        for kind in CloudKind.allCases { XCTAssertEqual(store.key(for: kind), "key-\(kind.id)-0123456789") }
        XCTAssertEqual(Set(CloudKind.allCases.map(\.keyAccount)).count, 3)
    }

    func testKeyShapesAreScrubbedFromAnyLoggedError() {
        for key in [FakeKeys.anthropic, FakeKeys.openAI, FakeKeys.gemini] {
            XCTAssertFalse(LLMError(.badKey, detail: "echo \(key)").copyDetails(appVersion: "1").contains(key))
        }
    }
}

/// The real Keychain adapter, with a throwaway service name.
final class KeychainStoreTests: XCTestCase {
    func testRoundTripUpdateAndDelete() throws {
        let store = KeychainStore(service: "shadow-tests-\(UUID().uuidString)")
        let account = "apiKey.test"
        _ = try store.get(account: account)
        defer { try? store.delete(account: account) }
        XCTAssertNil(try store.get(account: account))
        try store.set("first-secret", account: account)
        XCTAssertEqual(try store.get(account: account), "first-secret")
        try store.set("second-secret", account: account)
        XCTAssertEqual(try store.get(account: account), "second-secret")
        try store.delete(account: account)
        XCTAssertNil(try store.get(account: account))
        XCTAssertNoThrow(try store.delete(account: account), "deleting a missing key is fine")
    }
}
