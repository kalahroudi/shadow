import XCTest
@testable import ShadowKit

final class UpdateSwapTests: XCTestCase {
    private var tmp: URL!
    private var apps: URL!
    private var paths: AppPaths!
    private var openLog: URL!
    private var opener: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        apps = tmp.appendingPathComponent("apps")
        paths = AppPaths(root: tmp.appendingPathComponent("support"))
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try makeApp(apps.appendingPathComponent("Shadow.app"), tag: "old")
        try makeApp(paths.updatesDir.appendingPathComponent("staging/Shadow.app"), tag: "new")
        openLog = tmp.appendingPathComponent("open.log")
        opener = tmp.appendingPathComponent("open-stub.sh")
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func makeApp(_ app: URL, tag: String) throws {
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: app.appendingPathComponent("Contents/tag"))
    }
    private func tag(_ app: URL) -> String? { (try? String(contentsOf: app.appendingPathComponent("Contents/tag"), encoding: .utf8)) }

    /// Stub `open`: records which app it was asked to open and, if `confirm`, writes the marker like a healthy new app.
    private func writeOpener(confirm: Bool) throws {
        let marker = confirm ? "touch '\(paths.updateOKFile.path)'" : ":"
        let body = "#!/bin/sh\nif [ -e '\(paths.updateOKFile.path)' ]; then echo marker-present >> '\(openLog.path)'; fi\necho \"$1 $(cat \"$1/Contents/tag\")\" >> '\(openLog.path)'\n\(marker)\n"
        try Data(body.utf8).write(to: opener)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
    }
    private var staged: URL { paths.updatesDir.appendingPathComponent("staging/Shadow.app") }
    private func swap(wait: Int = 1, confirm: Int = 1) -> UpdateSwap {
        UpdateSwap(installedApp: apps.appendingPathComponent("Shadow.app"), stagedApp: staged, paths: paths,
                   opener: opener.path, waitSeconds: wait, confirmSeconds: confirm)
    }
    /// Runs the real script against a stand-in "old app" process that exits after `lifetime` seconds.
    private func run(_ swap: UpdateSwap, lifetime: String = "0.3") throws -> Int32 {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep"); old.arguments = [lifetime]
        try old.run()
        let p = try swap.makeProcess(pid: old.processIdentifier)
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
    private func opened() -> [String] { ((try? String(contentsOf: openLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    // MARK: swap (R11)
    func testSwapMovesOldAsideAndStagedIntoPlaceThenDeletesPreviousOnMarker() throws {
        try writeOpener(confirm: true)
        let s = swap()
        XCTAssertEqual(s.previousApp.lastPathComponent, "Shadow.previous.app")
        XCTAssertEqual(try run(s), 0)
        XCTAssertEqual(tag(s.installedApp), "new")
        XCTAssertFalse(fm.fileExists(atPath: s.previousApp.path), "previous deleted once the marker appeared (R12)")
        XCTAssertFalse(fm.fileExists(atPath: staged.path))
        XCTAssertEqual(opened().count, 1)
        XCTAssertFalse(fm.fileExists(atPath: paths.updateFailedFile.path))
    }

    func testStaleMarkerIsRemovedBeforeOpeningNewApp() throws {
        try writeOpener(confirm: false)
        try Data().write(to: paths.updateOKFile)
        // a stale marker must not count as confirmation: the new app never confirms, so we roll back
        XCTAssertEqual(try run(swap()), 1)
        XCTAssertFalse(opened().contains("marker-present"), "marker was removed before the new app was opened")
        XCTAssertEqual(opened().count, 2)
        XCTAssertEqual(tag(swap().installedApp), "old")
    }

    func testFailedMoveOfStagedAppRestoresOldOne() throws {
        try writeOpener(confirm: true)
        try fm.removeItem(at: staged)
        XCTAssertEqual(try run(swap()), 1)
        XCTAssertEqual(tag(swap().installedApp), "old")
        XCTAssertFalse(fm.fileExists(atPath: swap().previousApp.path))
        XCTAssertEqual(try String(contentsOf: paths.updateFailedFile, encoding: .utf8).contains("moved into place"), true)
        XCTAssertEqual(opened().last?.hasSuffix("old"), true, "old app reopened")
    }

    func testOldProcessIsForceKilledAfterWaitLimit() throws {
        try writeOpener(confirm: true)
        let start = Date()
        XCTAssertEqual(try run(swap(wait: 1), lifetime: "30"), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(tag(swap().installedApp), "new")
    }

    // MARK: rollback (R12)
    func testNoMarkerRestoresPreviousWritesReasonAndReopensOldApp() throws {
        try writeOpener(confirm: false)
        let s = swap()
        XCTAssertEqual(try run(s), 1)
        XCTAssertEqual(tag(s.installedApp), "old")
        XCTAssertFalse(fm.fileExists(atPath: s.previousApp.path))
        XCTAssertTrue(try String(contentsOf: paths.updateFailedFile, encoding: .utf8).contains("did not confirm"))
        let log = opened()
        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(log[0].hasSuffix("new")); XCTAssertTrue(log[1].hasSuffix("old"))
    }

    func testSwapRunsAsSeparateShellProcessWithPathsAsArguments() throws {
        let s = swap()
        let p = try s.makeProcess(pid: 4242)
        XCTAssertEqual(p.executableURL?.path, "/bin/sh")
        XCTAssertFalse(p.isRunning, "makeProcess does not start anything")
        XCTAssertEqual(p.arguments, [s.scriptURL.path, "4242", s.installedApp.path, s.previousApp.path, s.stagedApp.path,
                                     paths.updateOKFile.path, paths.updateFailedFile.path, opener.path, "1", "1"])
        XCTAssertTrue(fm.fileExists(atPath: s.scriptURL.path))
    }

    // MARK: confirm step (R12)
    func testConfirmWritesMarkerOnlyAfterDelayAndOnlyIfAlive() async throws {
        let marker = paths.updateOKFile
        let sawMarkerBeforeDelayEnded = Flag()
        await UpdateHandoff.confirmLaunch(paths: paths, delay: .seconds(4), isAlive: { true },
                                          sleep: { d in
            XCTAssertEqual(d, .seconds(4))
            sawMarkerBeforeDelayEnded.set(FileManager.default.fileExists(atPath: marker.path))
        })
        XCTAssertFalse(sawMarkerBeforeDelayEnded.value)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))

        try fm.removeItem(at: marker)
        await UpdateHandoff.confirmLaunch(paths: paths, isAlive: { false }, sleep: { _ in })
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "not alive: no marker")
    }

    // MARK: startup cleanup (R13)
    func testCleanupRemovesLeftoversAndReportsUpdatedOnce() throws {
        try Data("1.1.0".utf8).write(to: paths.updatePendingFile)
        XCTAssertEqual(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.1.0"), .updated("1.1.0"))
        XCTAssertEqual(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.1.0")?.text, nil, "only once")
        XCTAssertFalse(fm.fileExists(atPath: paths.updatesDir.path), "staging and the script are removed")
        XCTAssertEqual(UpdateHandoff.Notice.updated("1.1.0").text, "Updated to 1.1.0")
    }

    func testCleanupDoesNotClaimUpdateWhenVersionDiffers() throws {
        try Data("1.1.0".utf8).write(to: paths.updatePendingFile)
        XCTAssertNil(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.0.0"))
        XCTAssertFalse(fm.fileExists(atPath: paths.updatePendingFile.path))
    }

    func testCleanupSurfacesScrubbedRollbackReasonOnce() throws {
        let reason = "failed under /Users/zed/Library with token=abcd1234secret for user zed"
        try Data(reason.utf8).write(to: paths.updateFailedFile)
        try Data("1.1.0".utf8).write(to: paths.updatePendingFile)
        let notice = try XCTUnwrap(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.0.0", home: "/Users/zed", user: "zed"))
        XCTAssertEqual(notice, .rolledBack("failed under ~/Library with token=<redacted> for user <user>"))
        for leaked in ["/Users/zed", "abcd1234secret", "zed"] { XCTAssertFalse(notice.text.contains(leaked), leaked) }
        XCTAssertNil(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.0.0", home: "/Users/zed", user: "zed"))
        XCTAssertFalse(fm.fileExists(atPath: paths.updateFailedFile.path))
    }

    func testCleanupWithNothingPendingReportsNothing() {
        XCTAssertNil(UpdateHandoff.cleanup(paths: paths, currentVersion: "1.0.0"))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
