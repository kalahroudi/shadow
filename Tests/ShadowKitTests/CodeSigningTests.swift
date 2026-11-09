import XCTest
@testable import ShadowKit

struct FakeSigningInspector: SigningInspector {
    var identities: [URL: Result<SigningIdentity, SigningError>] = [:]
    var satisfied = true
    func identity(of app: URL) throws -> SigningIdentity {
        switch identities[app] { case .success(let i): return i; case .failure(let e): throw e; case nil: throw SigningError.missingRequirement }
    }
    func satisfies(staged: URL, requirement: String) -> Bool { satisfied }
}

final class CodeSigningTests: XCTestCase {
    let hashA = String(repeating: "ab", count: 20)
    let hashB = String(repeating: "cd", count: 20)
    let id = "com.kalahroudi.shadow"

    func testBuildSelfSigned() throws {
        XCTAssertEqual(try DesignatedRequirement.build(bundleID: id, kind: .selfSigned(leafSHA1: hashA)),
                       "designated => identifier \"com.kalahroudi.shadow\" and certificate leaf = H\"\(hashA)\"")
    }

    func testBuildDeveloperIDAndAdHoc() throws {
        XCTAssertEqual(try DesignatedRequirement.build(bundleID: id, kind: .developerID(teamID: "ABC123DEF4")),
                       "anchor apple generic and identifier \"com.kalahroudi.shadow\" and certificate leaf[subject.OU] = \"ABC123DEF4\"")
        XCTAssertEqual(try DesignatedRequirement.build(bundleID: id, kind: .adHoc), "designated => identifier \"com.kalahroudi.shadow\"")
    }

    func testBuildEscapesQuotesAndBackslashes() throws {
        let req = try DesignatedRequirement.build(bundleID: "a\"b\\c", kind: .adHoc)
        XCTAssertEqual(req, "designated => identifier \"a\\\"b\\\\c\"")
        XCTAssertEqual(try DesignatedRequirement.parse(req).identifier, "a\"b\\c")
    }

    func testBuildRejectsBadValues() {
        XCTAssertThrowsError(try DesignatedRequirement.build(bundleID: id, kind: .selfSigned(leafSHA1: "zz")))
        XCTAssertThrowsError(try DesignatedRequirement.build(bundleID: id, kind: .selfSigned(leafSHA1: hashA + "0")))
        XCTAssertThrowsError(try DesignatedRequirement.build(bundleID: id, kind: .developerID(teamID: "A\" or anchor apple")))
        XCTAssertThrowsError(try DesignatedRequirement.build(bundleID: "", kind: .adHoc))
    }

    func testParseRoundTrips() throws {
        for kind in [SigningKind.selfSigned(leafSHA1: hashA), .developerID(teamID: "ABC123DEF4"), .adHoc] {
            let parsed = try DesignatedRequirement.parse(try DesignatedRequirement.build(bundleID: id, kind: kind))
            XCTAssertEqual(parsed.kind, kind)
            XCTAssertEqual(parsed.identifier, id)
        }
    }

    func testParseAcceptsRequirementWithoutDesignatedPrefix() throws {
        let p = try DesignatedRequirement.parse("identifier \"\(id)\" and certificate leaf = H\"\(hashA.uppercased())\"")
        XCTAssertEqual(p.kind, .selfSigned(leafSHA1: hashA))
    }

    func testParseMissingAndMalformed() {
        XCTAssertThrowsError(try DesignatedRequirement.parse("  ")) { XCTAssertEqual($0 as? SigningError, .missingRequirement) }
        for bad in ["cdhash H\"abcd\"", "anchor apple", "identifier \"\(id)\" and certificate leaf = H\"abcd\"",
                    "identifier \"\(id)\" and certificate leaf = H\"\(hashA)\" or anchor apple",
                    "identifier \"unterminated", "designated => identifier \"\(id)\" extra"] {
            XCTAssertThrowsError(try DesignatedRequirement.parse(bad), bad) {
                guard case .malformedRequirement = $0 as? SigningError else { return XCTFail("\(bad): \($0)") }
            }
        }
    }

    private func ident(_ kind: SigningKind, _ identifier: String = "com.kalahroudi.shadow") -> SigningIdentity {
        SigningIdentity(kind: kind, identifier: identifier, requirement: (try? DesignatedRequirement.build(bundleID: identifier, kind: kind)) ?? "")
    }

    func testComparison() {
        XCTAssertEqual(ident(.selfSigned(leafSHA1: hashA)).compare(to: ident(.selfSigned(leafSHA1: hashA))), .same)
        XCTAssertEqual(ident(.selfSigned(leafSHA1: hashA)).compare(to: ident(.selfSigned(leafSHA1: hashB))), .different)
        XCTAssertEqual(ident(.selfSigned(leafSHA1: hashA)).compare(to: ident(.adHoc)), .different)
        XCTAssertEqual(ident(.adHoc).compare(to: ident(.selfSigned(leafSHA1: hashA))), .different)
        XCTAssertEqual(ident(.adHoc).compare(to: ident(.adHoc)), .different)
        XCTAssertEqual(ident(.selfSigned(leafSHA1: hashA)).compare(to: ident(.developerID(teamID: "ABC123DEF4"))), .different)
        XCTAssertEqual(ident(.selfSigned(leafSHA1: hashA)).compare(to: ident(.selfSigned(leafSHA1: hashA), "other.app")), .different)
    }

    func testSecurityInspectorFailsClosedOnMissingBundle() {
        let missing = URL(fileURLWithPath: "/nonexistent/Shadow.app")
        XCTAssertThrowsError(try SecurityFrameworkInspector().identity(of: missing))
        XCTAssertFalse(SecurityFrameworkInspector().satisfies(staged: missing, requirement: "anchor apple"))
    }

    func testComparisonPathHasNoCodesignCall() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShadowKit")
        for file in ["CodeSigning.swift", "UpdateDecision.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("\"codesign\"") || text.contains("Process("), file)
        }
    }
}
