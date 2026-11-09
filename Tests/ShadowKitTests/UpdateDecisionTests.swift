import XCTest
@testable import ShadowKit

final class UpdateDecisionTests: XCTestCase {
    let installed = URL(fileURLWithPath: "/apps/Shadow.app")
    let staged = URL(fileURLWithPath: "/tmp/staging/Shadow.app")
    let hashA = String(repeating: "ab", count: 20)
    let hashB = String(repeating: "cd", count: 20)

    private func ident(_ kind: SigningKind) -> SigningIdentity {
        let req = try! DesignatedRequirement.build(bundleID: "com.kalahroudi.shadow", kind: kind)
        return SigningIdentity(kind: kind, identifier: "com.kalahroudi.shadow", requirement: req)
    }
    private func decide(_ old: Result<SigningIdentity, SigningError>, _ new: Result<SigningIdentity, SigningError>,
                        satisfied: Bool = true, confirmed: Bool = false) -> UpdateDecision {
        let inspector = FakeSigningInspector(identities: [installed: old, staged: new], satisfied: satisfied)
        return UpdateDecision.decide(installed: installed, staged: staged, userConfirmed: confirmed, inspector: inspector)
    }
    private func isRefusal(_ d: UpdateDecision) -> Bool { if case .refuse(let e) = d { return e.kind == .identityRefused } else { return false } }

    func testMatchingIdentitiesProceedAndCarryOver() {
        XCTAssertEqual(decide(.success(ident(.selfSigned(leafSHA1: hashA))), .success(ident(.selfSigned(leafSHA1: hashA)))), .proceed(.permissionsCarryOver))
        XCTAssertEqual(decide(.success(ident(.developerID(teamID: "ABC123DEF4"))), .success(ident(.developerID(teamID: "ABC123DEF4")))), .proceed(.permissionsCarryOver))
    }

    func testDifferentCertificateConfirmsThenProceedsOnceConfirmed() {
        let a = Result<SigningIdentity, SigningError>.success(ident(.selfSigned(leafSHA1: hashA)))
        let b = Result<SigningIdentity, SigningError>.success(ident(.selfSigned(leafSHA1: hashB)))
        XCTAssertEqual(decide(a, b, satisfied: false), .confirm)
        XCTAssertEqual(decide(a, b, satisfied: false, confirmed: true), .proceed(.permissionsWillReset))
    }

    func testStableToAdHocConfirms() {
        XCTAssertEqual(decide(.success(ident(.selfSigned(leafSHA1: hashA))), .success(ident(.adHoc)), satisfied: false), .confirm)
    }

    func testAdHocInstalledProceedsWithResetNote() {
        XCTAssertEqual(decide(.success(ident(.adHoc)), .success(ident(.adHoc))), .proceed(.permissionsWillReset))
        XCTAssertEqual(decide(.success(ident(.adHoc)), .success(ident(.selfSigned(leafSHA1: hashA)))), .proceed(.permissionsWillReset))
    }

    func testUnreadableInstalledIsTreatedAsAdHoc() {
        XCTAssertEqual(decide(.failure(.missingRequirement), .success(ident(.selfSigned(leafSHA1: hashA)))), .proceed(.permissionsWillReset))
    }

    func testMissingOrMalformedStagedRequirementRefuses() {
        let old = Result<SigningIdentity, SigningError>.success(ident(.selfSigned(leafSHA1: hashA)))
        XCTAssertTrue(isRefusal(decide(old, .failure(.missingRequirement))))
        XCTAssertTrue(isRefusal(decide(old, .failure(.malformedRequirement("x")))))
        XCTAssertTrue(isRefusal(decide(old, .failure(.missingRequirement), confirmed: true)))
        XCTAssertTrue(isRefusal(decide(.success(ident(.adHoc)), .failure(.missingRequirement))))
    }

    func testSameIdentityButStagedFailsValidityRefuses() {
        let a = Result<SigningIdentity, SigningError>.success(ident(.selfSigned(leafSHA1: hashA)))
        XCTAssertTrue(isRefusal(decide(a, a, satisfied: false)))
        XCTAssertTrue(isRefusal(decide(a, a, satisfied: false, confirmed: true)))
    }
}
