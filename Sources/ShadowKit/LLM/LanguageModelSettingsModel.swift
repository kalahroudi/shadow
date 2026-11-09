// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The logic behind Settings → Language model (R21): live provider status, selection, models, key entry and Test key.
/// Keys go to the `SecretStore` and nowhere else.
@MainActor @Observable
public final class LanguageModelSettingsModel {
    public enum KeyTest: Equatable, Sendable { case idle, testing, passed, failed(String) }

    public private(set) var statuses: [String: ProviderStatus] = [:]
    public private(set) var selectedID: String
    public private(set) var localModels: [String] = []
    public private(set) var message: String?
    public private(set) var keyTests: [CloudKind: KeyTest] = [:]
    public private(set) var hasKey: [CloudKind: Bool] = [:]

    private let settings: LLMSettings
    private let secrets: any SecretStore
    private let makeProvider: @MainActor (String) -> (any LLMProvider)?
    private let listLocalModels: @Sendable (String) async throws -> [String]
    private let makeCloud: @Sendable (CloudKind) -> CloudProvider

    public init(settings: LLMSettings = LLMSettings(), secrets: any SecretStore = KeychainStore(),
                makeProvider: @escaping @MainActor (String) -> (any LLMProvider)?,
                listLocalModels: @escaping @Sendable (String) async throws -> [String] = { try await OpenAICompatProvider(baseURL: $0).models() },
                makeCloud: (@Sendable (CloudKind) -> CloudProvider)? = nil) {
        self.settings = settings; self.secrets = secrets; self.makeProvider = makeProvider; self.listLocalModels = listLocalModels
        let localOnly: @Sendable () -> Bool = { [settings] in settings.localOnly }
        self.makeCloud = makeCloud ?? { [secrets] in CloudProvider(kind: $0, secrets: secrets, localOnly: localOnly) }
        selectedID = settings.selectedProviderID
        for kind in CloudKind.allCases { hasKey[kind] = secrets.key(for: kind) != nil }
    }

    public var localOnly: Bool { settings.localOnly }
    public var localBaseURL: String { settings.localBaseURL }
    public var localModel: String { settings.localModel }
    public func model(for kind: CloudKind) -> String { settings.model(for: kind) }

    /// Cloud providers cannot be chosen while Local-only is on (R6); the reason is shown instead.
    public func isSelectable(_ id: String) -> Bool { !(CloudKind.isCloud(providerID: id) && settings.localOnly) }

    public func refresh() async {
        selectedID = settings.selectedProviderID
        for kind in CloudKind.allCases { hasKey[kind] = secrets.key(for: kind) != nil }
        for info in ProviderCatalog.all {
            statuses[info.id] = await makeProvider(info.id)?.availability() ?? .unavailable("Not available in this build.")
        }
        if let url = try? LoopbackURL.validate(settings.localBaseURL), statuses[OpenAICompatProvider.providerID]?.isReady == true {
            localModels = (try? await listLocalModels(url.absoluteString)) ?? []
        } else { localModels = [] }
    }

    public func select(_ id: String) {
        switch settings.select(id) {
        case .success: selectedID = id; message = nil
        case .failure(let e): message = e.message
        }
    }

    public func setLocalBaseURL(_ text: String) {
        do { try settings.setLocalBaseURL(text); message = nil } catch { message = (error as? UserFacingError)?.message ?? error.localizedDescription }
    }

    public func setLocalModel(_ model: String) { settings.setLocalModel(model) }
    public func setModel(_ model: String, for kind: CloudKind) { settings.setModel(model, for: kind) }

    /// Saves to the Keychain. An empty key removes the stored one.
    public func saveKey(_ key: String, for kind: CloudKind) {
        do {
            try secrets.saveKey(key, for: kind)
            hasKey[kind] = secrets.key(for: kind) != nil
            keyTests[kind] = .idle
            message = nil
        } catch { message = (error as? UserFacingError)?.message ?? "Couldn't save the key." }
    }

    /// A real minimal request with the typed key, or the saved one if the field is empty (R5).
    public func testKey(_ key: String, for kind: CloudKind) async {
        keyTests[kind] = .testing
        do {
            try await makeCloud(kind).testKey(key, model: settings.model(for: kind))
            keyTests[kind] = .passed
        } catch let e as LLMError { keyTests[kind] = .failed(e.message)
        } catch let e as UserFacingError { keyTests[kind] = .failed(e.message)
        } catch { keyTests[kind] = .failed(LLMError(.unavailable).message) }
    }
}
