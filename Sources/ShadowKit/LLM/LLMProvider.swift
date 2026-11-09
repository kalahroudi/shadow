// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One question to a model (R1). It carries text only: no audio and, by construction, no key (R12).
public struct LLMRequest: Sendable, Equatable {
    public var system: String
    /// Speaker-labelled turns and the question, as built by `ContextBuilder`.
    public var user: String
    public var personaID: String
    public var language: Language
    /// Provider-specific model name; empty means the provider's own default.
    public var model: String

    public init(system: String, user: String, personaID: String = Persona.interviewID, language: Language = .auto, model: String = "") {
        self.system = system; self.user = user; self.personaID = personaID; self.language = language; self.model = model
    }

    public init(context: BuiltContext, persona: Persona, language: Language, model: String = "") {
        self.init(system: context.system, user: context.user, personaID: persona.id, language: language, model: model)
    }
}

/// Live state of a provider, shown in Settings and the popover (R21, R22).
public enum ProviderStatus: Equatable, Sendable {
    case ready, needsKey, notRunning
    case unavailable(String)

    public var isReady: Bool { self == .ready }
}

/// A source of streamed answers. Cancelling the consuming task (or dropping the stream) must stop all network or process work (R1).
public protocol LLMProvider: Sendable {
    var id: String { get }
    /// Cloud providers are blocked by Local-only and get the "cloud" badge (R6).
    var isCloud: Bool { get }
    func availability() async -> ProviderStatus
    /// Text deltas in order. Throws `LLMError` or `UserFacingError`; finishes normally at the end of the answer.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

public enum LLMStream {
    /// Runs `body` in a task that feeds the stream. When the consumer cancels or stops reading, the task is cancelled and
    /// `onCancel` runs, so a provider can kill its process or cancel its URL task (R1).
    public static func make(onCancel: @escaping @Sendable () -> Void = {},
                            _ body: @escaping @Sendable (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await body(continuation); continuation.finish() }
                catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { onCancel() }
                task.cancel()
            }
        }
    }

    /// Runs `operation`, retrying once when it throws an `LLMError` the predicate accepts (R24). Never retries after cancellation.
    public static func withOneRetry<T: Sendable>(shouldRetry: @Sendable (LLMError) -> Bool = { $0.isTransient },
                                                 _ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let e as LLMError where shouldRetry(e) && !Task.isCancelled { return try await operation() }
    }
}

/// The Apple on-device model's state (R2). Each unavailable state has a message and guidance.
public enum AppleStatus: Equatable, Sendable {
    case ready, deviceNotEligible, appleIntelligenceOff, modelNotReady

    public var message: String {
        switch self {
        case .ready: "Apple on-device model is ready."
        case .deviceNotEligible: "This Mac can't run Apple Intelligence, so the on-device model isn't available."
        case .appleIntelligenceOff: "Apple Intelligence is turned off."
        case .modelNotReady: "The on-device model is still getting ready."
        }
    }

    public var guidance: String {
        switch self {
        case .ready: ""
        case .deviceNotEligible: "Choose a local server, the Claude CLI or your own key instead."
        case .appleIntelligenceOff: "Turn it on in System Settings → Apple Intelligence & Siri."
        case .modelNotReady: "It downloads in the background. Try again in a few minutes."
        }
    }

    public var providerStatus: ProviderStatus {
        self == .ready ? .ready : .unavailable(message + " " + guidance)
    }
}

/// The system seam for the on-device model. The real one wraps FoundationModels in the app target.
public protocol OnDeviceModel: Sendable {
    func status() -> AppleStatus
    /// Text deltas for `user` under `system`.
    func respond(system: String, user: String) -> AsyncThrowingStream<String, Error>
}

/// The default provider: Apple's on-device model, no key and no network (R2).
public struct OnDeviceProvider: LLMProvider {
    public static let providerID = "onDevice"
    public let model: any OnDeviceModel
    public init(model: any OnDeviceModel) { self.model = model }

    public var id: String { Self.providerID }
    public var isCloud: Bool { false }

    public func availability() async -> ProviderStatus { model.status().providerStatus }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        let model = model
        return LLMStream.make { out in
            let status = model.status()
            guard status == .ready else { throw UserFacingError(status.message + " " + status.guidance) }
            for try await delta in model.respond(system: request.system, user: request.user) { out.yield(delta) }
        }
    }
}

/// FoundationModels streams the whole answer so far each time; providers here stream deltas. This turns one into the other.
public struct CumulativeDelta: Sendable {
    private var previous = ""
    public init() {}

    /// The new text since the last call. If the model rewrote earlier text, nothing can be taken back, so only a
    /// longer common-prefix continuation is emitted.
    public mutating func delta(from cumulative: String) -> String {
        defer { previous = cumulative }
        if cumulative.hasPrefix(previous) { return String(cumulative.dropFirst(previous.count)) }
        return ""
    }
}

/// Classifies a FoundationModels error from its case name. The error's own text can echo the prompt, so it is only
/// inspected here and never copied into the result (R13).
public enum OnDeviceErrorMapper {
    public static func map(_ description: String) -> LLMError {
        let d = description.lowercased()
        if d.contains("guardrail") || d.contains("refusal") { return LLMError(.contentFiltered, detail: "on-device guardrail") }
        if d.contains("ratelimited") { return LLMError(.rateLimited, detail: "on-device rate limit") }
        if d.contains("assetsunavailable") { return LLMError(.unavailable, detail: "on-device model assets unavailable") }
        if d.contains("contextwindow") || d.contains("contextsize") { return LLMError(.unavailable, detail: "on-device context too large") }
        return LLMError(.unavailable, detail: "on-device error")
    }
}
