import XCTest
@testable import ShadowKit

/// A transport that never finishes until its task is cancelled, like a slow GitHub (R18).
private final class HangingTransport: UpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    private func hang() async throws {
        lock.withLock { _calls += 1 }
        while true { try await Task.sleep(for: .milliseconds(20)) }
    }
    func get(_ url: URL) async throws -> (data: Data, status: Int) { try await hang(); return (Data(), 200) }
    func download(_ url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> Int {
        // A partial file exists while the download hangs.
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: Data("partial".utf8))
        try await hang()
        return 200
    }
}

final class UpdateCancellationTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Shadow.app"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testCancellingAnInstallStopsItAndDeletesThePartialDownload() async throws {
        let transport = HangingTransport()
        let paths = AppPaths(root: tmp.appendingPathComponent("support"))
        let installer = UpdateInstaller(transport: transport, paths: paths)
        let base = "https://github.com/kalahroudi/shadow/releases/download/v1.1.0/"
        let update = AvailableUpdate(version: "1.1.0", notes: "",
                                     asset: .init(name: "Shadow-1.1.0.dmg", url: URL(string: base + "Shadow-1.1.0.dmg")!, size: nil),
                                     checksums: URL(string: base + "SHA256SUMS"))
        let bundle = tmp.appendingPathComponent("Shadow.app")
        let task = Task { try await installer.install(update, installedBundle: bundle) { _, _ in } }
        await waitUntil { transport.calls == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.updatesDir.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(UpdateCancellation.isCancellation(error)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.updatesDir.path), "partial download must be deleted")
        XCTAssertEqual(transport.calls, 1, "nothing else is requested after the cancel")
    }

    func testCancellingACheckIsNotReportedAsOffline() async {
        let transport = HangingTransport()
        let task = Task { try await UpdateChecker(transport: transport).check(current: "1.0.0") }
        await waitUntil { transport.calls == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "got \(error)") }
    }

    func testURLCancelledCountsAsCancellation() {
        XCTAssertTrue(UpdateCancellation.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(UpdateCancellation.isCancellation(URLError(.notConnectedToInternet)))
    }

    func testLocalOnlyGateWinsAndSaysPaused() {
        let build = BuildInfo(commit: "abc1234", repo: "kalahroudi/shadow", branch: "main", version: "1.0.0")
        let state = UpdateState.gate(build: build, bundleURL: URL(fileURLWithPath: "/Applications/Shadow.app"), localOnly: true)
        XCTAssertEqual(state, .pausedLocalOnly)
        XCTAssertEqual(UpdatesCopy.status(.pausedLocalOnly), UpdatesCopy.pausedNotice)
        XCTAssertTrue(UpdatesCopy.pausedNotice.contains("Local-only mode"))
    }
}
