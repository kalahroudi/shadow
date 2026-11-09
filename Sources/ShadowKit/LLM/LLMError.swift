// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a live-answer request failed (R24). `message` is the one friendly sentence people see; `detail` is technical and only
/// leaves the app through `copyDetails` / `issueURL`, scrubbed. Never put prompt or answer text in `detail`.
public struct LLMError: Error, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case offline, rateLimited, badKey, modelNotFound, contentFiltered, unavailable
    }
    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, detail: String = "") { self.kind = kind; self.detail = detail }

    public var message: String {
        switch kind {
        case .offline: return "Couldn't get an answer. Check your internet connection and try again."
        case .rateLimited: return "The language model is limiting requests right now. Wait a moment, then retry."
        case .badKey: return "The API key was rejected. Check it in Settings → Language model."
        case .modelNotFound: return "That model isn't available. Pick another one in Settings → Language model."
        case .contentFiltered: return "The language model declined to answer this one. Try Regenerate or rephrase."
        case .unavailable: return "The language model isn't available right now. Check Settings → Language model."
        }
    }

    public var userFacing: UserFacingError { UserFacingError(message) }

    /// Transient errors are worth one automatic retry (R24); a bad key, missing model or filtered answer is not.
    public var isTransient: Bool { kind == .offline || kind == .unavailable }

    /// HTTP status to class; nil for success statuses.
    public static func from(httpStatus status: Int, detail: String = "") -> LLMError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return LLMError(.badKey, detail: "HTTP \(status) \(detail)")
        case 404: return LLMError(.modelNotFound, detail: "HTTP \(status) \(detail)")
        case 429: return LLMError(.rateLimited, detail: "HTTP \(status) \(detail)")
        default: return LLMError(.unavailable, detail: "HTTP \(status) \(detail)")
        }
    }

    public static func from(urlError e: URLError) -> LLMError {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return LLMError(.offline, detail: "URLError \(e.code.rawValue)")
        default: return LLMError(.unavailable, detail: "URLError \(e.code.rawValue)")
        }
    }

    /// Text for "Copy details": version, category and technical detail, scrubbed of paths, users and secrets.
    public func copyDetails(appVersion: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var lines = ["Shadow \(appVersion)", "Language model error: \(kind.rawValue)", message]
        // the detail can carry a whole response body; keep the report (and the issue URL) a sane size
        if !detail.isEmpty { lines.append("Details: \(String(detail.prefix(500)))") }
        return LogScrubber.scrub(lines.joined(separator: "\n"), home: home, user: user)
    }

    /// "Report on GitHub": a prefilled new-issue URL whose body is the scrubbed details.
    public func issueURL(repo: String = "kalahroudi/shadow", appVersion: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "Answer problem: \(kind.rawValue)"),
                         URLQueryItem(name: "body", value: copyDetails(appVersion: appVersion, home: home, user: user))]
        return c?.url
    }
}
