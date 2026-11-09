// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which build is running. Written into Info.plist by scripts/bundle.sh.
public struct BuildInfo: Equatable, Sendable {
    public var commit: String?
    public var repo: String
    public var branch: String
    public var version: String

    public init(commit: String?, repo: String = "kalahroudi/shadow", branch: String = "main", version: String = "0") {
        self.commit = commit; self.repo = repo; self.branch = branch; self.version = version
    }

    /// The running app's build info.
    public static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return BuildInfo(commit: info["ShadowCommit"] as? String, repo: info["ShadowRepo"] as? String ?? "kalahroudi/shadow",
                         branch: info["ShadowBranch"] as? String ?? "main", version: info["CFBundleShortVersionString"] as? String ?? "0.0.0")
    }

    /// The commit without a "-dirty" marker (the build had uncommitted changes).
    public var cleanCommit: String? {
        guard let c = commit, c != "unknown", !c.isEmpty else { return nil }
        return c.hasSuffix("-dirty") ? String(c.dropLast(6)) : c
    }
    public var isDirty: Bool { commit?.hasSuffix("-dirty") == true }
    public var shortCommit: String { cleanCommit.map { String($0.prefix(7)) } ?? "dev" }
}
