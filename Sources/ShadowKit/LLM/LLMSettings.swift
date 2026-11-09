// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The language-model choices (R5, R6, R21): which provider is active, each provider's model, the local server address.
/// Backed by an injected `UserDefaults`. It holds no keys: those live only in a `SecretStore`.
/// Local-only is enforced here as well as in `CloudProvider`, so the UI is never the only guard.
public struct LLMSettings: @unchecked Sendable {   // UserDefaults is thread-safe
    public static let selectedKey = "llm.provider"
    public static let baseURLKey = "llm.localBaseURL"
    public static let fallbackProviderID = OnDeviceProvider.providerID

    public struct LocalOnlyOutcome: Equatable, Sendable {
        /// The local provider selected instead, when a cloud one was active.
        public var reselected: String?
        /// Always true when Local-only is turned on: the owner of the in-flight answer must cancel it if it is a cloud one.
        public var shouldCancelCloud: Bool
    }

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var localOnly: Bool { defaults.bool(forKey: PrefsDefaults.localOnly) }

    /// The active provider. A stored cloud choice is ignored while Local-only is on.
    public var selectedProviderID: String {
        let stored = defaults.string(forKey: Self.selectedKey) ?? Self.fallbackProviderID
        return CloudKind.isCloud(providerID: stored) && localOnly ? Self.fallbackProviderID : stored
    }

    /// True while a cloud provider is active: the overlay shows its "cloud" badge (R6).
    public var showsCloudBadge: Bool { CloudKind.isCloud(providerID: selectedProviderID) }

    /// Selects a provider. A cloud provider is refused while Local-only is on (R6).
    @discardableResult
    public func select(_ providerID: String) -> Result<Void, UserFacingError> {
        if CloudKind.isCloud(providerID: providerID) && localOnly { return .failure(LocalOnlyPolicy.error) }
        defaults.set(providerID, forKey: Self.selectedKey)
        return .success(())
    }

    /// Call after Local-only changes. Turning it on moves a cloud selection back to a local provider.
    @discardableResult
    public func localOnlyChanged(to on: Bool) -> LocalOnlyOutcome {
        guard on else { return LocalOnlyOutcome(reselected: nil, shouldCancelCloud: false) }
        let stored = defaults.string(forKey: Self.selectedKey) ?? Self.fallbackProviderID
        guard CloudKind.isCloud(providerID: stored) else { return LocalOnlyOutcome(reselected: nil, shouldCancelCloud: true) }
        defaults.set(Self.fallbackProviderID, forKey: Self.selectedKey)
        return LocalOnlyOutcome(reselected: Self.fallbackProviderID, shouldCancelCloud: true)
    }

    /// The chosen model for a cloud provider; falls back to its default if unset or no longer offered.
    public func model(for kind: CloudKind) -> String {
        let stored = defaults.string(forKey: "llm.model.\(kind.id)")
        return stored.flatMap { kind.models.contains($0) ? $0 : nil } ?? kind.defaultModel
    }

    public func setModel(_ model: String, for kind: CloudKind) {
        guard kind.models.contains(model) else { return }
        defaults.set(model, forKey: "llm.model.\(kind.id)")
    }

    public var localBaseURL: String { defaults.string(forKey: Self.baseURLKey) ?? LoopbackURL.defaultBase }

    /// Saves the local server address only if it is loopback (R3, R6).
    public func setLocalBaseURL(_ string: String) throws {
        _ = try LoopbackURL.validate(string)
        defaults.set(string.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
    }
}
