import XCTest
@testable import ShadowKit

private struct FakeChecker: PermissionChecker {
    var screen: PermissionState, mic: PermissionState
    func status(_ kind: PermissionKind) -> PermissionState { kind == .screen ? screen : mic }
    func request(_ kind: PermissionKind) async -> PermissionState { status(kind) }
}

final class PermissionLossTests: XCTestCase {
    private var paths: AppPaths!
    override func setUp() {
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("loss-\(UUID().uuidString)"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    private func run(before: (PermissionState, PermissionState), after: (PermissionState, PermissionState)) -> Bool {
        PermissionLossCheck.record(checker: FakeChecker(screen: before.0, mic: before.1), paths: paths)
        return PermissionLossCheck.checkOnce(checker: FakeChecker(screen: after.0, mic: after.1), paths: paths)
    }

    func testGrantedThenNotGrantedIsLoss() {
        XCTAssertTrue(run(before: (.granted, .granted), after: (.notGranted, .granted)))
    }
    func testMicLossIsLoss() {
        XCTAssertTrue(run(before: (.granted, .granted), after: (.granted, .notGranted)))
    }
    func testGrantedThenGrantedIsNoLoss() {
        XCTAssertFalse(run(before: (.granted, .granted), after: (.granted, .granted)))
    }
    func testNotGrantedBeforeIsNoLoss() {
        XCTAssertFalse(run(before: (.notGranted, .notYetAsked), after: (.notGranted, .notGranted)))
    }
    func testSecondLaunchDoesNoCheck() {
        XCTAssertTrue(run(before: (.granted, .granted), after: (.notGranted, .notGranted)))
        XCTAssertFalse(PermissionLossCheck.checkOnce(checker: FakeChecker(screen: .notGranted, mic: .notGranted), paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.permissionSnapshotFile.path))
    }
    func testNoRecordMeansNoLoss() {
        XCTAssertFalse(PermissionLossCheck.checkOnce(checker: FakeChecker(screen: .notGranted, mic: .notGranted), paths: paths))
    }
}
