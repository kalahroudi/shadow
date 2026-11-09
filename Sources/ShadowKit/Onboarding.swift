// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A speech/answer provider choice shown in onboarding. Only on-device is selectable in milestone 1 (R8).
public enum ProviderOption: String, CaseIterable, Sendable {
    case onDevice, localModels, ownKey, claudeCLI

    public var isAvailable: Bool { self == .onDevice }
    public var title: String {
        switch self {
        case .onDevice: "On-device, no keys"
        case .localModels: "Local models"
        case .ownKey: "Bring your own key"
        case .claudeCLI: "Claude CLI"
        }
    }
    public var detail: String {
        switch self {
        case .onDevice: "Apple SpeechAnalyzer. Nothing leaves your Mac."
        case .localModels: "MLX or Ollama."
        case .ownKey: "Your own API keys."
        case .claudeCLI: "Use the claude you already logged into."
        }
    }
}

/// The four-step first-run flow as plain state, so the gating rules are testable (R8).
public struct OnboardingModel: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable { case welcome, permissions, provider, consent }

    public private(set) var step: Step = .welcome
    public private(set) var provider: ProviderOption = .onDevice
    public var consentAcknowledged = false
    public init() {}

    public var canGoBack: Bool { step != .welcome }
    public var isLastStep: Bool { step == .consent }
    /// Every step but the last just continues; the last needs the explicit acknowledgement.
    public var canAdvance: Bool { isLastStep ? consentAcknowledged : true }

    public mutating func back() { if let s = Step(rawValue: step.rawValue - 1) { step = s } }
    /// Moves on, or returns true when this was the last step and the user may finish.
    public mutating func advance() -> Bool {
        guard canAdvance else { return false }
        if let s = Step(rawValue: step.rawValue + 1) { step = s; return false }
        return true
    }
    /// Ignores options that are "coming soon".
    public mutating func select(_ option: ProviderOption) { if option.isAvailable { provider = option } }
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

    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [remindBeforeSession: true, onboardingCompleted: false, autoUpdateChecks: true, localOnly: false, autoSuggest: false])
    }
}
