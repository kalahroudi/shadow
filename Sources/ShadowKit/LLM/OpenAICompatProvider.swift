// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Local servers only talk to this Mac (R3, R6): `localhost`, `127.0.0.0/8` and `::1`.
public enum LoopbackURL {
    public static let defaultBase = "http://localhost:11434/v1"

    public static func isLoopback(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let first = Int(parts[0]), parts.allSatisfy({ Int($0)! <= 255 }) else { return false }
        return first == 127
    }

    /// The base URL if it is http(s) on a loopback host without embedded credentials; otherwise a friendly error.
    public static func validate(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw UserFacingError("That isn't a valid server address. Use something like \(defaultBase).")
        }
        guard url.user == nil, url.password == nil, isLoopback(host: host) else {
            throw UserFacingError("Local models must run on this Mac, so the address has to be localhost or 127.0.0.1. Use a cloud provider for other servers.")
        }
        return url
    }
}

/// Any server that speaks the OpenAI chat API on this Mac: Ollama, mlx_lm.server, LM Studio (R3).
public struct OpenAICompatProvider: LLMProvider {
    public static let providerID = "localServer"
    public static let requestTimeout: TimeInterval = 60

    public let baseURL: String
    private let transport: any HTTPTransport
    private let apiKey: @Sendable () -> String?

    /// `apiKey` is read per request, so the key is never stored here; it is optional for local servers.
    public init(baseURL: String = LoopbackURL.defaultBase, transport: any HTTPTransport = URLSessionTransport(),
                apiKey: @escaping @Sendable () -> String? = { nil }) {
        self.baseURL = baseURL; self.transport = transport; self.apiKey = apiKey
    }

    public var id: String { Self.providerID }
    public var isCloud: Bool { false }

    /// Validated on every request, not just when saved.
    private func endpoint(_ path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        let base = try LoopbackURL.validate(baseURL)
        var url = base
        for part in path.split(separator: "/") { url.append(path: String(part)) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let key = apiKey(), !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func mapped(_ error: Error) -> Error {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                return LLMError(.unavailable, detail: "local server not running (URLError \(e.code.rawValue))")
            default: return LLMError.from(urlError: e)
            }
        }
        return error
    }

    /// `GET <base>/models`, e.g. `/v1/models`. Returns model ids.
    public func models() async throws -> [String] {
        let request = try endpoint("models", method: "GET", timeout: 10)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport.data(for: request) } catch { throw mapped(error) }
        if let e = LLMError.from(httpStatus: status) { throw e }
        return ModelListParser.parse(data)
    }

    public func availability() async -> ProviderStatus {
        do {
            let list = try await models()
            return list.isEmpty ? .unavailable("The server is running but has no models. Pull or load one first.") : .ready
        } catch let e as LLMError {
            if e.detail.contains("not running") { return .notRunning }
            return e.kind == .badKey ? .needsKey : .unavailable(e.message)
        } catch let e as UserFacingError { return .unavailable(e.message)
        } catch { return .notRunning }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        LLMStream.make { out in
            guard !request.model.isEmpty else { throw LLMError(.modelNotFound, detail: "no model selected") }
            var http = try endpoint("chat/completions", method: "POST", timeout: Self.requestTimeout)
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": request.model, "stream": true,
                "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.user]],
            ] as [String: Any])
            let body = http
            // Only a timeout or dropped connection while connecting is retried; a refused connection means "not running".
            let opened = try await LLMStream.withOneRetry(shouldRetry: { $0.kind == .offline }) { () -> HTTPStream in
                do { return try await transport.stream(for: body) } catch { throw mapped(error) }
            }
            if let e = LLMError.from(httpStatus: opened.status) { throw e }
            var parser = SSEParser()
            func deliver(_ events: [SSEParser.Event]) throws -> Bool {
                for event in events {
                    switch event {
                    case .done: return true
                    case .data(let json):
                        if let message = SSEDelta.errorMessage(json) { throw LLMError(.unavailable, detail: "server error: \(message)") }
                        if let text = SSEDelta.openAICompatible(json) { out.yield(text) }
                    }
                }
                return false
            }
            do {
                for try await chunk in opened.body { if try deliver(parser.feed(chunk)) { return } }
            } catch let e as URLError where e.code != .cancelled { throw mapped(e) }
            _ = try deliver(parser.finish())
        }
    }
}

/// `{"data": [{"id": "llama3.2"}, …]}` as served by Ollama, mlx_lm.server and OpenAI; also Ollama's older `{"models": [{"name": …}]}`.
public enum ModelListParser {
    public static func parse(_ data: Data) -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var ids = (o["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        if ids.isEmpty { ids = (o["models"] as? [[String: Any]])?.compactMap { ($0["name"] ?? $0["id"]) as? String } ?? [] }
        return ids.filter { !$0.isEmpty }
    }
}
