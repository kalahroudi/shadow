// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A provider as Settings and the popover list it (R21, R22).
public struct ProviderInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let isCloud: Bool
}

public enum ProviderCatalog {
    public static let all: [ProviderInfo] = [
        ProviderInfo(id: OnDeviceProvider.providerID, title: "Apple on-device", detail: "Apple Intelligence on this Mac. No key, nothing leaves your Mac.", isCloud: false),
        ProviderInfo(id: OpenAICompatProvider.providerID, title: "Local server", detail: "Ollama, mlx_lm.server or LM Studio running on this Mac.", isCloud: false),
        ProviderInfo(id: ClaudeCLIProvider.providerID, title: "Claude CLI", detail: "The claude command you already signed in to.", isCloud: false),
    ] + CloudKind.allCases.map { ProviderInfo(id: $0.id, title: $0.displayName, detail: "Your own API key. Questions and context are sent to \($0.displayName).", isCloud: true) }

    public static func info(_ id: String) -> ProviderInfo? { all.first { $0.id == id } }
    public static func title(_ id: String) -> String { info(id)?.title ?? id }

    public static let cloudVersusLocal = "Local providers run on this Mac and only talk to localhost. Cloud providers send the question and recent transcript text to the provider's servers with your key; audio is never sent. Local-only mode turns cloud providers off."
}

public extension ProviderStatus {
    /// The short live status shown beside a provider (R21): ready / needs key / not running / unavailable.
    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsKey: "Needs key"
        case .notRunning: "Not running"
        case .unavailable: "Unavailable"
        }
    }

    /// The explanation shown under an unavailable provider, if there is one.
    var explanation: String? {
        switch self {
        case .ready: nil
        case .needsKey: "Add an API key to use this provider."
        case .notRunning: "Start the server, then check again."
        case .unavailable(let why): why
        }
    }
}

/// The two status rows in the popover (R22): speech and the language model, each with its own value.
public struct StatusRow: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let value: String
    public let isReady: Bool

    public static func rows(speech: String, providerID: String, status: ProviderStatus?) -> [StatusRow] {
        let name = ProviderCatalog.title(providerID)
        let llm = status.map { "\(name) · \($0.label)" } ?? "\(name) · Checking…"
        return [StatusRow(title: "Speech", value: speech, isReady: true),
                StatusRow(title: "Language model", value: llm, isReady: status?.isReady ?? false)]
    }
}
