// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The answer provider choices in onboarding (R23).
public enum ProviderOption: String, CaseIterable, Sendable {
    case onDevice, localServer, claudeCLI, ownKey

    public var title: String {
        switch self {
        case .onDevice: "On-device"
        case .localServer: "Local server"
        case .claudeCLI: "Claude CLI"
        case .ownKey: "Bring your own key"
        }
    }
    public var detail: String {
        switch self {
        case .onDevice: "Apple Intelligence on this Mac. No keys. Nothing leaves your Mac."
        case .localServer: "Ollama or MLX running on this Mac."
        case .claudeCLI: "Use the claude you already logged into."
        case .ownKey: "Anthropic, OpenAI or Gemini with your own API key."
        }
    }
    public var isRecommended: Bool { self == .onDevice }

    /// The provider this option configures; "Bring your own key" means the chosen cloud provider.
    public func providerID(ownKeyKind: CloudKind) -> String {
        switch self {
        case .onDevice: OnDeviceProvider.providerID
        case .localServer: OpenAICompatProvider.providerID
        case .claudeCLI: ClaudeCLIProvider.providerID
        case .ownKey: ownKeyKind.id
        }
    }
}

/// The four-step first-run flow as plain state, so the gating rules are testable (R23).
public struct OnboardingModel: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable { case welcome, permissions, provider, consent }

    public private(set) var step: Step = .welcome
    public private(set) var provider: ProviderOption = .onDevice
    /// Which cloud provider "Bring your own key" means.
    public var ownKeyKind: CloudKind = .anthropic
    /// The latest availability check per option. A missing entry means it has not been checked.
    public private(set) var statuses: [ProviderOption: ProviderStatus] = [:]
    public var consentAcknowledged = false
    public init() {}
    /// Starts at a given step (snapshots), without walking through the gates.
    public init(startingAt step: Step) { self.step = step }

    public var canGoBack: Bool { step != .welcome }
    public var isLastStep: Bool { step == .consent }
    /// The chosen provider has been checked and is ready.
    public var providerIsReady: Bool { statuses[provider] == .ready }
    /// The provider step needs a passing availability check; the last step also needs the acknowledgement.
    public var canAdvance: Bool {
        switch step {
        case .provider: providerIsReady
        case .consent: consentAcknowledged && providerIsReady
        default: true
        }
    }

    public mutating func back() { if let s = Step(rawValue: step.rawValue - 1) { step = s } }
    /// Moves on, or returns true when this was the last step and the user may finish.
    public mutating func advance() -> Bool {
        guard canAdvance else { return false }
        if let s = Step(rawValue: step.rawValue + 1) { step = s; return false }
        return true
    }

    public mutating func record(_ status: ProviderStatus, for option: ProviderOption) { statuses[option] = status }

    /// Why an option can't be chosen right now, or nil. A missing key is fixable on the spot, so it doesn't block the choice.
    public func unavailableReason(_ option: ProviderOption) -> String? {
        switch statuses[option] {
        case .unavailable(let why)?: why
        case .notRunning?: "Not running. Start the server, then check again."
        default: nil
        }
    }

    public func isSelectable(_ option: ProviderOption) -> Bool { unavailableReason(option) == nil }

    /// Ignores options that are unavailable.
    public mutating func select(_ option: ProviderOption) { if isSelectable(option) { provider = option } }

    /// The provider id the current choice configures.
    public var providerID: String { provider.providerID(ownKeyKind: ownKeyKind) }

    /// Makes the current choice the active provider.
    @discardableResult
    public func configure(_ settings: LLMSettings) -> Result<Void, UserFacingError> { settings.select(providerID) }
}

/// Default values for every preference, in one place so a test can check them without the app target (A8).
public enum PrefsDefaults {
    public static let remindBeforeSession = "remindBeforeSession"
    public static let onboardingCompleted = "onboardingCompleted"
    /// The one key the Settings mic picker writes and the capture path reads.
    public static let micDeviceID = "micDeviceID"
    /// The stored microphone UID, or nil (system default) when it is missing or empty.
    public static func micDeviceUID(in defaults: UserDefaults = .standard) -> String? {
        let uid = defaults.string(forKey: micDeviceID)
        return uid?.isEmpty == false ? uid : nil
    }
    /// Visible mode is a fixed rule, not a setting: there is no way to hide the overlay from capture (R20).
    public static let visibleMode = true

    /// Update checks (R1, R14, R18). Automatic checks are on and Local-only is off by default.
    public static let autoUpdateChecks = "autoUpdateChecks"
    public static let localOnly = "localOnly"
    /// Answer automatically when a Them turn ends in a question (R8). Off by default.
    public static let autoSuggest = "autoSuggest"
    /// When the last successful check finished, and the earliest time to try again after GitHub rate-limited us.
    public static let lastUpdateCheck = "lastUpdateCheck"
    public static let lastUpdateRetryAfter = "lastUpdateRetryAfter"

    /// One boolean per permission: Shadow saw it granted at some point (R8). Nothing else is stored.
    public static let permissionGrantedScreen = "permissionGranted.screen"
    public static let permissionGrantedMicrophone = "permissionGranted.microphone"

    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [remindBeforeSession: true, onboardingCompleted: false, autoUpdateChecks: true, localOnly: false, autoSuggest: false])
    }
}
