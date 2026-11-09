// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The three cloud providers (R5). Model lists are fixed arrays kept here so they are easy to update.
public enum CloudKind: String, CaseIterable, Sendable {
    case anthropic, openAI, gemini

    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .anthropic: "Anthropic"; case .openAI: "OpenAI"; case .gemini: "Google Gemini" }
    }
    /// The Keychain account holding this provider's key.
    public var keyAccount: String { "apiKey.\(rawValue)" }
    public var models: [String] {
        switch self {
        case .anthropic: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
        case .openAI: ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
        }
    }
    public var defaultModel: String { models[0] }

    public static func isCloud(providerID: String) -> Bool { CloudKind(rawValue: providerID) != nil }
}

public enum LocalOnlyPolicy {
    public static let message = "Local-only is on, so cloud providers are turned off. Switch it off in Settings → Privacy to use one."
    public static var error: UserFacingError { UserFacingError(message) }
}

/// Anthropic, OpenAI or Gemini over HTTPS with a user-supplied key (R5). The key is read from the `SecretStore` per request
/// and only ever goes into a request header; it is never stored here, logged or put in a URL.
public struct CloudProvider: LLMProvider {
    public static let requestTimeout: TimeInterval = 60
    public static let testTimeout: TimeInterval = 20
    public static let maxOutputTokens = 1024

    public let kind: CloudKind
    private let transport: any HTTPTransport
    private let secrets: any SecretStore
    private let localOnly: @Sendable () -> Bool

    /// `localOnly` is checked on every call, so Local-only holds even if the UI lets a selection through (R6).
    public init(kind: CloudKind, transport: any HTTPTransport = URLSessionTransport(), secrets: any SecretStore,
                localOnly: @escaping @Sendable () -> Bool = { false }) {
        self.kind = kind; self.transport = transport; self.secrets = secrets; self.localOnly = localOnly
    }

    public var id: String { kind.id }
    public var isCloud: Bool { true }

    public func availability() async -> ProviderStatus {
        if localOnly() { return .unavailable(LocalOnlyPolicy.message) }
        return secrets.key(for: kind) == nil ? .needsKey : .ready
    }

    // MARK: Requests

    private func endpoint(model: String, stream: Bool, key: String, timeout: TimeInterval, system: String, user: String, maxTokens: Int) throws -> URLRequest {
        // A key goes straight into a header, so only printable ASCII is allowed (no CR/LF header injection).
        guard key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw LLMError(.badKey, detail: "key has invalid characters") }
        var r: URLRequest
        let body: [String: Any]
        switch kind {
        case .anthropic:
            r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "stream": stream, "system": system,
                    "messages": [["role": "user", "content": user]]]
        case .openAI:
            r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: timeout)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "stream": stream, "max_completion_tokens": maxTokens,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .gemini:
            // The model name goes into the path, so it must be a plain identifier.
            guard model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
                throw LLMError(.modelNotFound, detail: "invalid model name")
            }
            let action = stream ? "streamGenerateContent?alt=sse" : "generateContent"
            r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(action)")!, timeoutInterval: timeout)
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": user]]]],
                    "generationConfig": ["maxOutputTokens": maxTokens]]
        }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { r.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private func requireKey() throws -> String {
        if localOnly() { throw LocalOnlyPolicy.error }
        guard let key = secrets.key(for: kind) else { throw LLMError(.badKey, detail: "no key saved") }
        return key
    }

    private static func mapped(_ error: Error) -> Error {
        if let e = error as? URLError { return LLMError.from(urlError: e) }
        return error
    }

    /// Maps a failure status to a class. Gemini reports a bad key as 400 with `API_KEY_INVALID`. The body is only inspected, never kept.
    static func classify(status: Int, body: Data) -> LLMError? {
        if status == 400 {
            let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
            if text.contains("api_key_invalid") || text.contains("api key not valid") || text.contains("invalid x-api-key") || text.contains("incorrect api key") {
                return LLMError(.badKey, detail: "HTTP 400 key rejected")
            }
        }
        return LLMError.from(httpStatus: status)
    }

    // MARK: Test key (R5)

    /// A real one-token request. Pass `key` to test a key before saving it; otherwise the stored key is used.
    /// Throws an `LLMError` whose class says what is wrong (bad key, rate limited, offline, …).
    public func testKey(_ key: String? = nil, model: String? = nil) async throws {
        if localOnly() { throw LocalOnlyPolicy.error }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = (trimmed?.isEmpty == false ? trimmed : nil) ?? secrets.key(for: kind) else {
            throw LLMError(.badKey, detail: "no key entered")
        }
        let request = try endpoint(model: model ?? kind.defaultModel, stream: false, key: key, timeout: Self.testTimeout,
                                   system: "Reply with one word.", user: "Say OK.", maxTokens: 16)
        try await LLMStream.withOneRetry {
            if localOnly() { throw LocalOnlyPolicy.error }
            let result: (data: Data, status: Int)
            do { result = try await transport.data(for: request) } catch { throw Self.mapped(error) }
            if let e = Self.classify(status: result.status, body: result.data) { throw e }
        }
    }

    // MARK: Streaming (R1, R5, R24)

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        LLMStream.make { out in
            let key = try requireKey()
            let model = request.model.isEmpty ? kind.defaultModel : request.model
            let http = try endpoint(model: model, stream: true, key: key, timeout: Self.requestTimeout,
                                    system: request.system, user: request.user, maxTokens: Self.maxOutputTokens)
            // One retry for a transient failure (offline, 5xx); never for a bad key or other client errors.
            let opened = try await LLMStream.withOneRetry { () -> HTTPStream in
                if localOnly() { throw LocalOnlyPolicy.error }   // also before the retry
                let s: HTTPStream
                do { s = try await transport.stream(for: http) } catch { throw Self.mapped(error) }
                if s.status >= 300 {
                    var body = Data()
                    for try await chunk in s.body { body.append(chunk); if body.count >= 4096 { break } }
                    throw Self.classify(status: s.status, body: body) ?? LLMError(.unavailable, detail: "HTTP \(s.status)")
                }
                return s
            }
            var parser = SSEParser()
            func deliver(_ events: [SSEParser.Event]) throws -> Bool {
                // Turning Local-only on ends an answer that is already streaming.
                if localOnly() { throw LocalOnlyPolicy.error }
                for event in events {
                    switch event {
                    case .done: return true
                    case .data(let json):
                        if let message = SSEDelta.errorMessage(json) { throw LLMError(.unavailable, detail: "provider error: \(message)") }
                        if let text = SSEDelta.text(json, for: kind) { out.yield(text) }
                        if SSEDelta.isContentFiltered(json) { throw LLMError(.contentFiltered, detail: "stopped by provider filter") }
                        if kind == .anthropic, SSEDelta.isAnthropicStop(json) { return true }
                    }
                }
                return false
            }
            do {
                for try await chunk in opened.body { if try deliver(parser.feed(chunk)) { return } }
            } catch let e as URLError where e.code != .cancelled { throw Self.mapped(e) }
            _ = try deliver(parser.finish())
        }
    }
}

public extension SSEDelta {
    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Anthropic: `content_block_delta` events carrying a `text_delta`.
    static func anthropic(_ json: String) -> String? {
        guard let o = object(json), o["type"] as? String == "content_block_delta",
              let d = o["delta"] as? [String: Any], d["type"] as? String == "text_delta",
              let t = d["text"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// Gemini: `candidates[0].content.parts[].text`, joined.
    static func gemini(_ json: String) -> String? {
        guard let c = ((object(json)?["candidates"] as? [[String: Any]])?.first),
              let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return nil }
        let t = parts.compactMap { $0["text"] as? String }.joined()
        return t.isEmpty ? nil : t
    }

    static func text(_ json: String, for kind: CloudKind) -> String? {
        switch kind {
        case .anthropic: anthropic(json)
        case .openAI: openAICompatible(json)
        case .gemini: gemini(json)
        }
    }

    static func isAnthropicStop(_ json: String) -> Bool { object(json)?["type"] as? String == "message_stop" }

    /// The provider's own safety filter ended the answer: Gemini `SAFETY` / blocked prompt, OpenAI `content_filter`, Anthropic `refusal`.
    static func isContentFiltered(_ json: String) -> Bool {
        guard let o = object(json) else { return false }
        if (o["promptFeedback"] as? [String: Any])?["blockReason"] != nil { return true }
        if let c = (o["candidates"] as? [[String: Any]])?.first, let r = c["finishReason"] as? String, ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"].contains(r) { return true }
        if let c = (o["choices"] as? [[String: Any]])?.first, c["finish_reason"] as? String == "content_filter" { return true }
        if let d = o["delta"] as? [String: Any], d["stop_reason"] as? String == "refusal" { return true }
        return false
    }
}
