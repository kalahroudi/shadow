import CryptoKit
import XCTest
@testable import ShadowKit

/// Writes canned bodies to disk like the real streaming download, in two chunks so progress is reported.
private final class StreamingFake: UpdateTransport, @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var statuses: [String: Int] = [:]
    private(set) var downloads: [URL] = []
    private(set) var progress: [Double] = []
    func get(_ url: URL) async throws -> (data: Data, status: Int) { (Data(), 200) }
    func download(_ url: URL, to destination: URL, progress report: @Sendable (Double) -> Void) async throws -> Int {
        downloads.append(url)
        let status = statuses[url.lastPathComponent] ?? 200
        guard status == 200 else { return status }
        let body = bodies[url.lastPathComponent] ?? Data()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let h = try { FileManager.default.createFile(atPath: destination.path, contents: nil); return try FileHandle(forWritingTo: destination) }()
        defer { try? h.close() }
        let half = body.count / 2
        try h.write(contentsOf: body.prefix(half)); report(0.5); progress.append(0.5)
        try h.write(contentsOf: body.dropFirst(half)); report(1); progress.append(1)
        return status
    }
}

private final class FakeMounter: DiskImageMounter, @unchecked Sendable {
    var appName: String? = "Shadow.app"
    var attachError: Error?
    private(set) var attached = 0, detached = 0
    func attach(_ image: URL, at mountPoint: URL) async throws {
        attached += 1
        if let attachError { throw attachError }
        if let appName { try FakeBundle.make(at: mountPoint.appendingPathComponent(appName)) }
    }
    func detach(_ mountPoint: URL) async { detached += 1 }
}

private struct FakeExtractor: ArchiveExtractor {
    func extract(_ archive: URL, into directory: URL) async throws { try FakeBundle.make(at: directory.appendingPathComponent("Shadow.app")) }
}

private final class FakeRunner: CommandRunner, @unchecked Sendable {
    var codesign = ShellResult(stdout: "", stderr: "", status: 0)
    var selfTest = ShellResult(stdout: "ok abc1234\n", stderr: "", status: 0)
    private(set) var calls: [String] = []
    func run(_ tool: String, _ args: [String]) async throws -> ShellResult {
        calls.append(tool)
        return tool == "codesign" ? codesign : selfTest
    }
}

private enum FakeBundle {
    static func make(at app: URL, mcpExecutable: Bool = true) throws {
        let fm = FileManager.default
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        for (name, exec) in [("Shadow", true), ("shadow-mcp", mcpExecutable)] {
            let f = macos.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: f)
            try fm.setAttributes([.posixPermissions: exec ? 0o755 : 0o644], ofItemAtPath: f.path)
        }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.shadow", "ShadowCommit": "abc1234"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}

final class UpdateInstallerTests: XCTestCase {
    private var tmp: URL!
    private var installed: URL!
    private let transport = StreamingFake()
    private let mounter = FakeMounter()
    private let runner = FakeRunner()
    private let dmg = Data((0..<1000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        installed = tmp.appendingPathComponent("apps/Shadow.app")
        try FakeBundle.make(at: installed)
        transport.bodies["Shadow-1.1.0.dmg"] = dmg
        transport.bodies["SHA256SUMS"] = Data("\(digest(dmg))  Shadow-1.1.0.dmg\n".utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private var paths: AppPaths { AppPaths(root: tmp.appendingPathComponent("support")) }
    private func update(asset: String = "Shadow-1.1.0.dmg", sums: Bool = true) -> AvailableUpdate {
        let base = "https://github.com/kalahroudi/shadow/releases/download/v1.1.0/"
        return AvailableUpdate(version: "1.1.0", notes: "", asset: .init(name: asset, url: URL(string: base + asset)!, size: nil),
                               checksums: sums ? URL(string: base + "SHA256SUMS") : nil)
    }
    private func installer() -> UpdateInstaller {
        UpdateInstaller(transport: transport, paths: paths, mounter: mounter, extractor: FakeExtractor(), verifier: BundleVerifier(runner: runner))
    }
    private func installedSnapshot() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: installed.path).sorted()
    }
    private func assertFails(_ kind: UpdateError.Kind, _ u: AvailableUpdate? = nil, line: UInt = #line) async throws {
        let before = try installedSnapshot()
        do { _ = try await installer().install(u ?? update(), installedBundle: installed) { _, _ in }; XCTFail("expected \(kind)", line: line) }
        catch { XCTAssertEqual((error as? UpdateError)?.kind, kind, "\(error)", line: line) }
        XCTAssertEqual(try installedSnapshot(), before, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.updatesDir.path), "temp files removed", line: line)
    }

    // MARK: success, streaming and progress (R7)
    func testInstallStagesVerifiedBundleAndReportsMonotonicProgress() async throws {
        let seen = Box()
        let staged = try await installer().install(update(), installedBundle: installed) { step, f in seen.add(step, f) }
        XCTAssertEqual(staged.lastPathComponent, "Shadow.app")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: staged.appendingPathComponent("Contents/MacOS/shadow-mcp").path))
        XCTAssertEqual(transport.downloads.map(\.lastPathComponent), ["SHA256SUMS", "Shadow-1.1.0.dmg"])
        XCTAssertEqual(transport.progress, [0.5, 1, 0.5, 1], "both files are written in two chunks")
        let dl = seen.values.filter { $0.0 == .downloading }.map(\.1)
        XCTAssertEqual(dl, dl.sorted())
        XCTAssertEqual(dl, [0, 0.5, 1])
        XCTAssertEqual(mounter.attached, 1); XCTAssertEqual(mounter.detached, 1)
        XCTAssertEqual(runner.calls.count, 2); XCTAssertEqual(runner.calls.first, "codesign")
    }

    func testZipIsExtractedWithoutMounting() async throws {
        let zip = Data("zip".utf8)
        transport.bodies["Shadow-1.1.0.zip"] = zip
        transport.bodies["SHA256SUMS"] = Data("\(digest(zip))  Shadow-1.1.0.zip\n".utf8)
        _ = try await installer().install(update(asset: "Shadow-1.1.0.zip"), installedBundle: installed) { _, _ in }
        XCTAssertEqual(mounter.attached, 0)
    }

    // MARK: checksums (R8)
    func testUppercaseDigestMatches() async throws {
        transport.bodies["SHA256SUMS"] = Data("\(digest(dmg).uppercased()) *Shadow-1.1.0.dmg\n".utf8)
        _ = try await installer().install(update(), installedBundle: installed) { _, _ in }
    }

    func testMismatchDeletesDownloadAndNeverMounts() async throws {
        transport.bodies["SHA256SUMS"] = Data("\(digest(Data("other".utf8)))  Shadow-1.1.0.dmg\n".utf8)
        try await assertFails(.checksumMismatch)
        XCTAssertEqual(mounter.attached, 0); XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMissingEntryOrMissingSumsFileAborts() async throws {
        transport.bodies["SHA256SUMS"] = Data("\(digest(dmg))  Other.dmg\n".utf8)
        try await assertFails(.checksumMismatch)
        try await assertFails(.checksumMismatch, update(sums: false))
        transport.statuses["SHA256SUMS"] = 404
        try await assertFails(.checksumMismatch)
        XCTAssertEqual(mounter.attached, 0)
    }

    func testDigestParsing() {
        let h = String(repeating: "A", count: 64)
        XCTAssertEqual(UpdateInstaller.expectedDigest(for: "a.dmg", in: "junk\n\(h)  a.dmg\n"), String(repeating: "a", count: 64))
        XCTAssertNil(UpdateInstaller.expectedDigest(for: "a.dmg", in: "abc  a.dmg"))
        XCTAssertNil(UpdateInstaller.expectedDigest(for: "b.dmg", in: "\(h)  a.dmg"))
    }

    func testAssetNameWithPathSeparatorIsRefused() async throws {
        let base = "https://github.com/kalahroudi/shadow/releases/download/v1.1.0/"
        let evil = AvailableUpdate(version: "1.1.0", notes: "", asset: .init(name: "a/b.dmg", url: URL(string: base + "a%2Fb.dmg")!, size: nil),
                                   checksums: URL(string: base + "SHA256SUMS"))
        try await assertFails(.badRelease, evil)
        XCTAssertTrue(transport.downloads.isEmpty)
    }

    func testDownloadErrorStatusAborts() async throws {
        transport.statuses["Shadow-1.1.0.dmg"] = 404
        try await assertFails(.badRelease)
    }

    // MARK: verification (R9)
    func testMissingAppInImageAborts() async throws {
        mounter.appName = nil
        try await assertFails(.verificationFailed)
        XCTAssertEqual(mounter.detached, 1)
    }

    func testNonExecutableMcpAborts() async throws {
        final class Making: DiskImageMounter, @unchecked Sendable {
            func attach(_ image: URL, at mountPoint: URL) async throws { try FakeBundle.make(at: mountPoint.appendingPathComponent("Shadow.app"), mcpExecutable: false) }
            func detach(_ mountPoint: URL) async {}
        }
        let i = UpdateInstaller(transport: transport, paths: paths, mounter: Making(), verifier: BundleVerifier(runner: runner))
        do { _ = try await i.install(update(), installedBundle: installed) { _, _ in }; XCTFail() }
        catch { XCTAssertEqual((error as? UpdateError)?.kind, .verificationFailed) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailingCodesignAborts() async throws {
        runner.codesign = ShellResult(stdout: "", stderr: "invalid signature", status: 1)
        try await assertFails(.verificationFailed)
        XCTAssertEqual(mounter.detached, 1)
    }

    func testSelfTestFailuresAbort() async throws {
        runner.selfTest = ShellResult(stdout: "ok abc1234", stderr: "", status: 1)
        try await assertFails(.verificationFailed)
        runner.selfTest = ShellResult(stdout: "hello", stderr: "", status: 0)
        try await assertFails(.verificationFailed)
        runner.selfTest = ShellResult(stdout: "ok deadbee", stderr: "", status: 0)
        try await assertFails(.verificationFailed)
    }

    func testDetachRunsWhenAttachFails() async throws {
        mounter.attachError = UpdateError(.verificationFailed, detail: "hdiutil attach exited 1")
        try await assertFails(.verificationFailed)
        XCTAssertEqual(mounter.detached, 1)
    }

    // MARK: preflight (R10)
    func testPreflightRejectsNonBundleAndReadOnlyParent() throws {
        XCTAssertThrowsError(try UpdateInstaller.preflight(bundleURL: tmp.appendingPathComponent("apps/Shadow"))) {
            XCTAssertEqual(($0 as? UpdateError)?.kind, .notWritable)
        }
        let ro = tmp.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        XCTAssertThrowsError(try UpdateInstaller.preflight(bundleURL: ro.appendingPathComponent("Shadow.app"))) {
            XCTAssertTrue(($0 as? UpdateError)?.message.contains("Move Shadow to a folder you own") == true)
        }
        XCTAssertNoThrow(try UpdateInstaller.preflight(bundleURL: installed))
    }

    func testFailedPreflightDownloadsNothing() async {
        do { _ = try await installer().install(update(), installedBundle: tmp.appendingPathComponent("Shadow")) { _, _ in }; XCTFail() } catch {}
        XCTAssertTrue(transport.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.updatesDir.path))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [(InstallStep, Double)] = []
    func add(_ s: InstallStep, _ f: Double) { lock.withLock { v.append((s, f)) } }
    var values: [(InstallStep, Double)] { lock.withLock { v } }
}
