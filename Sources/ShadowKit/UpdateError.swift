// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why an update check or install failed (R6, R8, R9, R10, R16). `message` is the one friendly sentence people see;
/// `detail` is technical and only ever leaves the app through `copyDetails` / `issueURL`, scrubbed.
public struct UpdateError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case offline, rateLimited, checksumMismatch, verificationFailed, badRelease, notWritable, noBuild, identityRefused
    }
    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, detail: String = "") { self.kind = kind; self.detail = detail }

    public var message: String {
        switch kind {
        case .offline: return "Couldn't check for updates: check your internet connection and try again."
        case .rateLimited: return "GitHub is limiting requests right now. Please try again in an hour."
        case .checksumMismatch: return "The downloaded update didn't match its checksum, so it wasn't installed."
        case .verificationFailed: return "The downloaded update didn't pass its safety checks, so your current version was kept."
        case .badRelease: return "Couldn't read the release information from GitHub. Please try again later."
        case .notWritable: return "Move Shadow to a folder you own, then try updating again."
        case .noBuild: return "This release has no downloadable build yet."
        case .identityRefused: return "The downloaded update's signature couldn't be checked against this app, so your current version was kept."
        }
    }

    public var userFacing: UserFacingError { UserFacingError(message) }

    /// Text for "Copy details": version, category and the technical detail, scrubbed of paths, users and secrets.
    public func copyDetails(appVersion: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var lines = ["Shadow \(appVersion)", "Update error: \(kind.rawValue)", message]
        if !detail.isEmpty { lines.append("Details: \(detail)") }
        return LogScrubber.scrub(lines.joined(separator: "\n"), home: home, user: user)
    }

    /// "Report on GitHub": a prefilled new-issue URL whose body is the scrubbed details.
    public func issueURL(repo: String = "kalahroudi/shadow", appVersion: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        let title = LogScrubber.scrub("Update problem: \(kind.rawValue)", home: home, user: user)
        c?.queryItems = [URLQueryItem(name: "title", value: title),
                         URLQueryItem(name: "body", value: copyDetails(appVersion: appVersion, home: home, user: user))]
        return c?.url
    }
}
