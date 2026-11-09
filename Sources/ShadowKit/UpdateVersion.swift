// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A semantic version (R4). Accepts a leading `v`, one to three numeric parts and a `-prerelease` / `+build` suffix.
public struct SemVer: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = String(s[..<dash])
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let n = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        major = n[0]; minor = n[1]; patch = n[2]; prerelease = pre
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        // A version with a prerelease sorts before the same version without one.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true      // numeric identifiers sort before alphanumeric ones
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// True only when `release` is strictly newer than `current`. Unparseable input offers nothing.
    public static func isNewer(_ release: String, than current: String) -> Bool {
        guard let r = SemVer(release), let c = SemVer(current) else { return false }
        return c < r
    }
}
