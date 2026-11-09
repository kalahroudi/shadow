// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Which kind of signature a bundle carries. TCC keys grants on the designated requirement, so two builds keep their
/// permissions only when their requirements match; the kind and the leaf hash or team ID are what make them match.
public enum SigningKind: Equatable, Sendable {
    case selfSigned(leafSHA1: String)
    case developerID(teamID: String)
    case adHoc

    public var isStable: Bool { if case .adHoc = self { return false } else { return true } }
}

public enum SigningError: Error, Equatable, Sendable {
    case invalidValue(String)
    case missingRequirement
    case malformedRequirement(String)
}

/// Builds and reads designated requirements (R21). Pure: no Security framework, no processes.
public enum DesignatedRequirement {
    /// Quotes a value for the requirement language, escaping `\` and `"`.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The same text `bundle.sh` passes to `codesign -r=` (R5, R6, R8).
    public static func build(bundleID: String, kind: SigningKind) throws -> String {
        guard !bundleID.isEmpty, !bundleID.contains(where: \.isNewline) else { throw SigningError.invalidValue("bundle ID") }
        let id = "identifier \(quote(bundleID))"
        switch kind {
        case .selfSigned(let hash):
            guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { throw SigningError.invalidValue("leaf hash") }
            return "designated => \(id) and certificate leaf = H\"\(hash.lowercased())\""
        case .developerID(let team):
            guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw SigningError.invalidValue("team ID") }
            return "anchor apple generic and \(id) and certificate leaf[subject.OU] = \(quote(team))"
        case .adHoc:
            return "designated => \(id)"
        }
    }

    /// Reads a requirement as `SecRequirementCopyString` or `codesign -d -r-` prints it. A missing identifier, an
    /// unknown shape or trailing text is malformed: such a bundle never gets treated as matching anything.
    public static func parse(_ text: String) throws -> SigningIdentity {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw SigningError.missingRequirement }
        if s.hasPrefix("designated =>") { s = String(s.dropFirst("designated =>".count)).trimmingCharacters(in: .whitespaces) }
        func bad() -> SigningError { .malformedRequirement(String(text.prefix(200))) }

        var scanner = Scanner(s)
        var apple = false
        if scanner.take("anchor apple generic and ") { apple = true }
        guard scanner.take("identifier "), let identifier = scanner.quoted(), !identifier.isEmpty else { throw bad() }
        let kind: SigningKind
        if scanner.atEnd, !apple {
            kind = .adHoc
        } else if !apple, scanner.take(" and certificate leaf = H\""), let hash = scanner.hex(), scanner.take("\"") {
            guard hash.count == 40 else { throw bad() }
            kind = .selfSigned(leafSHA1: hash)
        } else if apple, scanner.take(" and certificate leaf[subject.OU] = "), let team = scanner.quoted(), !team.isEmpty {
            kind = .developerID(teamID: team)
        } else {
            throw bad()
        }
        guard scanner.atEnd else { throw bad() }
        return SigningIdentity(kind: kind, identifier: identifier, requirement: s)
    }

    private struct Scanner {
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }
        var atEnd: Bool { i >= chars.count }

        mutating func take(_ literal: String) -> Bool {
            let l = Array(literal)
            guard i + l.count <= chars.count, Array(chars[i..<i + l.count]) == l else { return false }
            i += l.count
            return true
        }
        mutating func quoted() -> String? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            var out = ""
            var j = i + 1
            while j < chars.count {
                let c = chars[j]
                if c == "\\" {
                    guard j + 1 < chars.count else { return nil }
                    out.append(chars[j + 1]); j += 2
                } else if c == "\"" {
                    i = j + 1
                    return out
                } else { out.append(c); j += 1 }
            }
            return nil
        }
        mutating func hex() -> String? {
            var out = ""
            while i < chars.count, chars[i].isHexDigit { out.append(chars[i]); i += 1 }
            return out.isEmpty ? nil : out.lowercased()
        }
    }
}

/// What a bundle's signature says about who built it (R21).
public struct SigningIdentity: Equatable, Sendable {
    public let kind: SigningKind
    public let identifier: String
    public let requirement: String

    public init(kind: SigningKind, identifier: String, requirement: String) {
        self.kind = kind; self.identifier = identifier; self.requirement = requirement
    }

    public enum Comparison: Equatable, Sendable { case same, different }

    /// Two ad-hoc identities never compare as the same: their requirement is pinned to nothing stable.
    public func compare(to other: SigningIdentity) -> Comparison {
        kind.isStable && kind == other.kind && identifier == other.identifier ? .same : .different
    }
}

/// Reads signing identities from bundles and checks one bundle against another's requirement. Behind a protocol so
/// the update decision is testable without signed bundles (R21).
public protocol SigningInspector: Sendable {
    /// Throws `SigningError.missingRequirement` or `.malformedRequirement` when the DR can't be read.
    func identity(of app: URL) throws -> SigningIdentity
    /// `SecStaticCodeCheckValidity` of `staged` against `requirement`.
    func satisfies(staged: URL, requirement: String) -> Bool
}

/// The Security framework implementation (R23): no `codesign` process involved.
public struct SecurityFrameworkInspector: SigningInspector {
    public init() {}

    public func identity(of app: URL) throws -> SigningIdentity {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw SigningError.missingRequirement }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else { throw SigningError.missingRequirement }
        var text: CFString?
        guard SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { throw SigningError.missingRequirement }
        return try DesignatedRequirement.parse(text as String)
    }

    public func satisfies(staged: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(staged as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
