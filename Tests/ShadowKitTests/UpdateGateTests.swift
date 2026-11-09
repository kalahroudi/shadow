import XCTest
@testable import ShadowKit

private final class FakeConfirmer: UpdateConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
    var asked: Int { lock.withLock { _asked } }
    func confirmIdentityChange() async -> Bool { lock.withLock { _asked += 1 }; return answer }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false, _note: UpdateDecision.Note?
    var swapped: Bool { lock.withLock { _set } }
    var note: UpdateDecision.Note? { lock.withLock { _note } }
    func swap() { lock.withLock { _set = true } }
    func note(_ n: UpdateDecision.Note) { lock.withLock { _note = n } }
}

final class UpdateGateTests: XCTestCase {
    let hashA = String(repeating: "ab", count: 20)
    let hashB = String(repeating: "cd", count: 20)
    let installed = URL(fileURLWithPath: "/tmp/installed.app")
    let staged = URL(fileURLWithPath: "/tmp/staged.app")

    private func ident(_ kind: SigningKind) throws -> SigningIdentity {
        let req = try DesignatedRequirement.build(bundleID: "com.kalahroudi.shadow", kind: kind)
        return SigningIdentity(kind: kind, identifier: "com.kalahroudi.shadow", requirement: req)
    }

    private func gate(old: SigningKind, new: SigningKind, answer: Bool = true) throws -> (UpdateGate, FakeConfirmer) {
        let inspector = FakeSigningInspector(identities: [installed: .success(try ident(old)), staged: .success(try ident(new))])
        let c = FakeConfirmer(answer: answer)
        return (UpdateGate(inspector: inspector, confirmer: c), c)
    }

    func testMatchingIdentitiesSwapWithoutPromptAndCarryOver() async throws {
        let (g, c) = try gate(old: .selfSigned(leafSHA1: hashA), new: .selfSigned(leafSHA1: hashA))
        let flag = Flag()
        let outcome = try await g.run(installed: installed, staged: staged, onNote: { flag.note($0) }, swap: { flag.swap() })
        XCTAssertEqual(outcome, .swapped(.permissionsCarryOver))
        XCTAssertEqual(flag.note, .permissionsCarryOver)
        XCTAssertTrue(flag.swapped)
        XCTAssertEqual(c.asked, 0)
        XCTAssertEqual(UpdatesCopy.permissionsNote(.permissionsCarryOver), "Permissions will carry over")
    }

    func testDifferentIdentityThenCancelDoesNotSwap() async throws {
        let (g, c) = try gate(old: .selfSigned(leafSHA1: hashA), new: .selfSigned(leafSHA1: hashB), answer: false)
        let flag = Flag()
        let outcome = try await g.run(installed: installed, staged: staged, swap: { flag.swap() })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(flag.swapped)
        XCTAssertEqual(c.asked, 1)
    }

    func testDifferentIdentityThenUpdateAnywaySwaps() async throws {
        let (g, c) = try gate(old: .selfSigned(leafSHA1: hashA), new: .adHoc)
        let flag = Flag()
        let outcome = try await g.run(installed: installed, staged: staged, swap: { flag.swap() })
        XCTAssertEqual(outcome, .swapped(.permissionsWillReset))
        XCTAssertTrue(flag.swapped)
        XCTAssertEqual(c.asked, 1)
    }

    func testRefusalThrowsAndDoesNotSwap() async throws {
        let inspector = FakeSigningInspector(identities: [installed: .success(try ident(.adHoc)), staged: .failure(.missingRequirement)])
        let g = UpdateGate(inspector: inspector, confirmer: FakeConfirmer(answer: true))
        let flag = Flag()
        do { _ = try await g.run(installed: installed, staged: staged, swap: { flag.swap() }); XCTFail("expected refusal") }
        catch { XCTAssertEqual((error as? UpdateError)?.kind, .identityRefused) }
        XCTAssertFalse(flag.swapped)
    }

    func testConfirmTextIsExact() {
        XCTAssertEqual(UpdateGate.confirmText, "This update is signed with a different identity; Screen Recording and Microphone access will need to be granted again")
        XCTAssertEqual(UpdateGate.confirmButton, "Update anyway")
    }
}
