// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The part of a GitHub release the updater reads.
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int?
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", size }
    }
    public let tag: String
    public let draft: Bool
    public let prerelease: Bool
    public let body: String?
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tag = "tag_name", draft, prerelease, body, assets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        body = try c.decodeIfPresent(String.self, forKey: .body)
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let asset: ReleaseInfo.Asset
    public let checksums: URL?

    /// A fixed newer version for `--snapshot`, so the popover row can be captured.
    public static let sample = AvailableUpdate(
        version: "9.9.9", notes: "",
        asset: .init(name: "Shadow-9.9.9.dmg", url: URL(string: "https://github.com/kalahroudi/shadow/releases/download/v9.9.9/Shadow-9.9.9.dmg")!, size: nil),
        checksums: nil)
}

public enum UpdateOutcome: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
    case noDownloadableBuild
}

public enum UpdateCheck {
    public static let checksumsName = "SHA256SUMS"

    /// Decides what a release means for the running version (R4). Drafts and prereleases are ignored.
    public static func evaluate(_ release: ReleaseInfo, current: String) throws -> UpdateOutcome {
        if release.draft || release.prerelease { return .upToDate }
        guard let version = SemVer(release.tag) else { throw UpdateError(.badRelease, detail: "unreadable release tag") }
        if version.isPrerelease || !SemVer.isNewer(release.tag, than: current) { return .upToDate }
        guard let asset = pickAsset(release.assets, version: version) else { return .noDownloadableBuild }
        let sums = release.assets.first { $0.name == checksumsName }?.url
        return .available(AvailableUpdate(version: version.description, notes: summary(release.body ?? ""), asset: asset, checksums: sums))
    }

    /// `Shadow-<version>.dmg`, then any `.dmg`, then any `.zip`.
    static func pickAsset(_ assets: [ReleaseInfo.Asset], version: SemVer) -> ReleaseInfo.Asset? {
        let lower = { (a: ReleaseInfo.Asset) in a.name.lowercased() }
        return assets.first { lower($0) == "shadow-\(version).dmg" }
            ?? assets.first { lower($0).hasSuffix(".dmg") }
            ?? assets.first { lower($0).hasSuffix(".zip") }
    }

    /// First 8 non-empty lines of the release notes with bullet and heading markers stripped.
    public static func summary(_ notes: String) -> String {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { line in
                var s = Substring(line)
                while let f = s.first, "-*•+#".contains(f) { s.removeFirst() }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }
}

/// Fetches and evaluates the latest release over an `UpdateTransport`.
public struct UpdateChecker: Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/kalahroudi/shadow/releases/latest")!
    /// After a 403/429 the next check waits at least this long (R6).
    public static let rateLimitRetryAfter: TimeInterval = 3600

    let transport: any UpdateTransport
    public init(transport: any UpdateTransport) { self.transport = transport }

    public func check(current: String) async throws -> UpdateOutcome {
        let data: Data, status: Int
        do { (data, status) = try await transport.get(Self.latestURL) }
        catch let e as UpdateError { throw e }
        catch is URLError { throw UpdateError(.offline) }
        catch { throw UpdateError(.badRelease, detail: String(describing: error)) }
        switch status {
        case 200: break
        case 403, 429: throw UpdateError(.rateLimited, detail: "HTTP \(status)")
        default: throw UpdateError(.badRelease, detail: "HTTP \(status)")
        }
        let release: ReleaseInfo
        do { release = try JSONDecoder().decode(ReleaseInfo.self, from: data) }
        catch { throw UpdateError(.badRelease, detail: "release JSON did not decode") }
        return try UpdateCheck.evaluate(release, current: current)
    }
}
