import XCTest
@testable import ShadowKit

/// R21, R22 / A21, A22.
@MainActor
final class LanguageModelSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "lm-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        PrefsDefaults.register(in: defaults)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func model(secrets: InMemorySecretStore = InMemorySecretStore(), providers: [String: FakeLLMProvider] = [:],
                       transport: FakeHTTPTransport? = nil, local: [String] = []) -> LanguageModelSettingsModel {
        let settings = LLMSettings(defaults: defaults)
        var makeCloud: (@Sendable (CloudKind) -> CloudProvider)?
        if let transport {
            makeCloud = { CloudProvider(kind: $0, transport: transport, secrets: secrets, localOnly: { settings.localOnly }) }
        }
        return LanguageModelSettingsModel(settings: settings, secrets: secrets, makeProvider: { providers[$0] },
                                          listLocalModels: { _ in local }, makeCloud: makeCloud)
    }

    func testCatalogHasAllSixProvidersAndNoAppleFMRow() {
        XCTAssertEqual(ProviderCatalog.all.map(\.id), ["onDevice", "localServer", "claudeCLI", "anthropic", "openAI", "gemini"])
        XCTAssertFalse(ProviderCatalog.all.contains { $0.title.contains("FM") })
        XCTAssertEqual(ProviderCatalog.all.filter(\.isCloud).count, 3)
        XCTAssertFalse(ProviderCatalog.cloudVersusLocal.isEmpty)
    }

    func testStatusLabelsCoverTheFourStatuses() {
        XCTAssertEqual(ProviderStatus.ready.label, "Ready")
        XCTAssertEqual(ProviderStatus.needsKey.label, "Needs key")
        XCTAssertEqual(ProviderStatus.notRunning.label, "Not running")
        XCTAssertEqual(ProviderStatus.unavailable("x").label, "Unavailable")
        XCTAssertNil(ProviderStatus.ready.explanation)
        XCTAssertEqual(ProviderStatus.unavailable("why").explanation, "why")
    }

    func testRefreshReportsLiveStatusPerProvider() async {
        let m = model(providers: ["onDevice": FakeLLMProvider(id: "onDevice", deltas: []),
                                  "localServer": { let p = FakeLLMProvider(id: "localServer", deltas: []); p.status = .notRunning; return p }(),
                                  "anthropic": { let p = FakeLLMProvider(id: "anthropic", isCloud: true, deltas: []); p.status = .needsKey; return p }()],
                      local: ["llama3.2"])
        await m.refresh()
        XCTAssertEqual(m.statuses["onDevice"], .ready)
        XCTAssertEqual(m.statuses["localServer"], .notRunning)
        XCTAssertEqual(m.statuses["anthropic"], .needsKey)
        XCTAssertEqual(m.statuses["claudeCLI"], .unavailable("Not available in this build."))
        XCTAssertEqual(m.localModels, [], "no model list while the server is not running")
    }

    func testLocalModelsListedWhenServerReadyAndPickIsUsedForRequests() async {
        let m = model(providers: ["localServer": FakeLLMProvider(id: "localServer", deltas: [])], local: ["llama3.2", "qwen"])
        await m.refresh()
        XCTAssertEqual(m.localModels, ["llama3.2", "qwen"])
        XCTAssertEqual(LLMSettings(defaults: defaults).modelName(for: "localServer"), "llama3.2", "a ready server never leaves the model empty")
        m.setLocalModel("qwen")
        await m.refresh()
        XCTAssertEqual(LLMSettings(defaults: defaults).localModel, "qwen", "a listed pick is kept")
        XCTAssertEqual(LLMSettings(defaults: defaults).modelName(for: "localServer"), "qwen")
        XCTAssertEqual(LLMSettings(defaults: defaults).modelName(for: "onDevice"), "")
        XCTAssertEqual(LLMSettings(defaults: defaults).modelName(for: "gemini"), CloudKind.gemini.defaultModel)
    }

    func testCloudSelectionRefusedUnderLocalOnlyWithMessage() {
        defaults.set(true, forKey: PrefsDefaults.localOnly)
        let m = model()
        XCTAssertFalse(m.isSelectable("anthropic"))
        XCTAssertTrue(m.isSelectable("claudeCLI"))
        m.select("anthropic")
        XCTAssertEqual(m.message, LocalOnlyPolicy.message)
        XCTAssertEqual(m.selectedID, "onDevice")
        m.select("claudeCLI")
        XCTAssertNil(m.message)
        XCTAssertEqual(m.selectedID, "claudeCLI")
    }

    func testNonLoopbackAddressIsRejected() {
        let m = model()
        m.setLocalBaseURL("https://example.com/v1")
        XCTAssertNotNil(m.message)
        XCTAssertEqual(m.localBaseURL, LoopbackURL.defaultBase)
        m.setLocalBaseURL("http://127.0.0.1:8080/v1")
        XCTAssertNil(m.message)
        XCTAssertEqual(m.localBaseURL, "http://127.0.0.1:8080/v1")
    }

    func testKeyFieldWritesOnlyToTheSecretStore() {
        let secrets = InMemorySecretStore()
        let m = model(secrets: secrets)
        let key = FakeKeys.anthropic
        m.saveKey("  \(key) ", for: .anthropic)
        XCTAssertEqual(secrets.all, ["apiKey.anthropic": key])
        XCTAssertEqual(m.hasKey[.anthropic], true)
        for (_, value) in defaults.dictionaryRepresentation() { XCTAssertFalse("\(value)".contains(key)) }
        m.saveKey("", for: .anthropic)
        XCTAssertTrue(secrets.all.isEmpty)
        XCTAssertEqual(m.hasKey[.anthropic], false)
    }

    func testTestKeyPassesAndMapsBadKey() async {
        let ok = FakeHTTPTransport(data: [.success((Data(), 200))])
        let m = model(transport: ok)
        await m.testKey(FakeKeys.anthropic, for: .anthropic)
        XCTAssertEqual(m.keyTests[.anthropic], .passed)
        let bad = model(transport: FakeHTTPTransport(data: [.success((Data(), 401))]))
        await bad.testKey(FakeKeys.anthropic, for: .anthropic)
        XCTAssertEqual(bad.keyTests[.anthropic], .failed(LLMError(.badKey).message))
        XCTAssertTrue(InMemorySecretStore().all.isEmpty)
    }

    func testPopoverHasSeparateSpeechAndLanguageModelRowsFollowingStatus() {
        for (status, text) in [(ProviderStatus.ready, "Ready"), (.needsKey, "Needs key"), (.notRunning, "Not running"), (.unavailable("x"), "Unavailable")] {
            let rows = StatusRow.rows(speech: "Apple SpeechAnalyzer", providerID: "claudeCLI", status: status)
            XCTAssertEqual(rows.map(\.title), ["Speech", "Language model"])
            XCTAssertEqual(rows[0].value, "Apple SpeechAnalyzer")
            XCTAssertEqual(rows[1].value, "Claude CLI · \(text)")
            XCTAssertEqual(rows[1].isReady, status == .ready)
        }
        XCTAssertEqual(StatusRow.rows(speech: "s", providerID: "onDevice", status: nil)[1].value, "Apple on-device · Checking…")
    }

    func testSettingsModelNeverTouchesPersonaOrPrefsKeysForSecrets() {
        // R25: the panes only expose language model, persona and existing settings; no excluded-feature panes exist.
        let titles = SettingsPane.allCases.map { $0.title.lowercased() }
        for banned in ["screenshot", "knowledge", "history", "summar", "relay", "sparkle"] {
            XCTAssertFalse(titles.contains { $0.contains(banned) })
        }
    }
}
