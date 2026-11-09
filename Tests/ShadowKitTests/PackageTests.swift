import XCTest
@testable import ShadowKit

/// Guards the scaffold decisions of milestone 1 (R1, R25): they live in files, so the tests read the files.
final class PackageTests: XCTestCase {
    private func repoFile(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/ShadowKitTests/<file> -> repo root
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func testPackageDeclaresMacOS26Swift6AndNoDependencies() throws {
        let manifest = try repoFile("Package.swift")
        XCTAssertTrue(manifest.contains(".macOS(.v26)"))
        XCTAssertTrue(manifest.contains("swiftLanguageModes: [.v6]"))
        XCTAssertFalse(manifest.contains(".package("), "no third-party packages")
        for target in ["\"ShadowKit\"", "\"Shadow\"", "\"shadow-mcp\""] { XCTAssertTrue(manifest.contains("name: \(target)"), target) }
    }

    func testBundleScriptWritesRequiredInfoPlistKeys() throws {
        let script = try repoFile("scripts/bundle.sh")
        for key in ["LSUIElement", "LSMultipleInstancesProhibited", "NSMicrophoneUsageDescription",
                    "NSAudioCaptureUsageDescription", "NSScreenCaptureUsageDescription"] {
            XCTAssertTrue(script.contains("<key>\(key)</key>"), key)
        }
        XCTAssertTrue(script.contains("<string>26.0</string>"))
    }

    func testUsageDescriptionsHaveNonEmptyStrings() throws {
        let script = try repoFile("scripts/bundle.sh")
        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSScreenCaptureUsageDescription"] {
            let marker = "<key>\(key)</key>"
            let range = try XCTUnwrap(script.range(of: marker), key)
            let rest = script[range.upperBound...].drop(while: { $0.isWhitespace })
            XCTAssertTrue(rest.hasPrefix("<string>"), "\(key) must be followed by a <string>")
            let value = rest.dropFirst("<string>".count)
            let end = try XCTUnwrap(value.range(of: "</string>"), key)
            XCTAssertFalse(value[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) must not be empty")
        }
    }

    func testResetScriptIsGuardedAndScopedToShadow() throws {
        let script = try repoFile("scripts/reset-permissions.sh")
        XCTAssertTrue(script.contains("BUNDLE_ID=\"com.kalahroudi.shadow\""))
        XCTAssertTrue(script.contains("[y/N]"))
        XCTAssertTrue(script.contains("$BUNDLE_ID? [y/N]"), "prompt names the bundle id")
        XCTAssertTrue(script.contains("[ ! -t 0 ]"), "refuses without a terminal")
        let commands = script.split(separator: "\n").filter { $0.hasPrefix("tccutil") }
        XCTAssertFalse(commands.isEmpty)
        for line in commands {
            XCTAssertTrue(line.hasSuffix("\"$BUNDLE_ID\""), "tccutil must target the bundle id: \(line)")
            XCTAssertFalse(line.contains("All"), "never reset all services")
        }
        XCTAssertFalse(script.contains("reset All"))
        XCTAssertEqual(script.components(separatedBy: "com.").count - 1, 1, "only one bundle id appears")
    }

    /// Runs the reset script with a fake `tccutil` first on PATH, so real TCC state is never touched.
    /// With `tty` the script gets a pseudo-terminal via `script`; `input` is typed after a short delay.
    private func runReset(tty: Bool, input: String) throws -> (status: Int32, calls: [String]) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("reset-test-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls")
        let fake = bin.appendingPathComponent("tccutil")
        try "#!/bin/bash\necho \"$@\" >> '\(log.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let scriptPath = root.appendingPathComponent("scripts/reset-permissions.sh").path

        let p = Process()
        if tty {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "{ sleep 1; printf '\(input)'; sleep 1; } | /usr/bin/script -q /dev/null /bin/bash '\(scriptPath)'"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptPath]
            p.standardInput = FileHandle.nullDevice
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (p.terminationStatus, calls)
    }

    func testResetScriptRefusesWithoutTerminal() throws {
        let r = try runReset(tty: false, input: "")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(r.calls, [], "tccutil must not run without a terminal")
    }

    func testResetScriptRunsOnlyScopedResetsOnYes() throws {
        let r = try runReset(tty: true, input: "y\\n")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.calls, ["reset ScreenCapture com.kalahroudi.shadow", "reset Microphone com.kalahroudi.shadow"])
    }

    func testResetScriptDoesNothingOnNoOrEOF() throws {
        let no = try runReset(tty: true, input: "n\\n")
        XCTAssertEqual(no.status, 0)
        XCTAssertEqual(no.calls, [])
        let eof = try runReset(tty: true, input: "")
        XCTAssertNotEqual(eof.status, 0)
        XCTAssertEqual(eof.calls, [])
    }

    func testCIBuildsTestsBundlesAndSelfTests() throws {
        let ci = try repoFile(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("runs-on: macos-26"))
        XCTAssertTrue(ci.contains("permissions:\n  contents: read"), "CI token must be read-only")
        XCTAssertFalse(ci.contains("secrets."), "CI must not use secrets")
        for step in ["swift build", "swift test", "scripts/bundle.sh", "--self-test", "shadow-mcp --version"] {
            XCTAssertTrue(ci.contains(step), step)
        }
    }

    func testNoAgentsOrOldUpdateCodeRemains() throws {
        let fm = FileManager.default
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        for gone in ["Sources/ShadowKit/Update.swift", "Sources/ShadowKit/Agents.swift",
                     "Sources/Shadow/AgentsView.swift", "Sources/Shadow/ManagerView.swift"] {
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(gone).path), gone)
        }
    }

    func testAppPathsHasNoUpdateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try AppPaths(root: root).ensureDirectories()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["sessions"])
    }

    func testBuildInfoCommitHandling() {
        XCTAssertEqual(BuildInfo(commit: "abcdef1234-dirty").cleanCommit, "abcdef1234")
        XCTAssertTrue(BuildInfo(commit: "abcdef1234-dirty").isDirty)
        XCTAssertEqual(BuildInfo(commit: nil).shortCommit, "dev")
    }

    func testBuildInfoParsesStampedKeysAndSelfTestLine() {
        let info = BuildInfo(infoDictionary: ["ShadowCommit": "abc123-dirty", "ShadowRepo": "me/shadow", "ShadowBranch": "dev",
                                              "CFBundleShortVersionString": "1.2.3"])
        XCTAssertEqual(info, BuildInfo(commit: "abc123-dirty", repo: "me/shadow", branch: "dev", version: "1.2.3"))
        XCTAssertEqual(info.selfTestLine, "ok abc123-dirty")
        let dev = BuildInfo(infoDictionary: [:])
        XCTAssertNil(dev.commit)
        XCTAssertEqual(dev.selfTestLine, "ok dev")
        XCTAssertEqual(BuildInfo(commit: "unknown").selfTestLine, "ok dev")
    }

    func testCIChecksStampedPlistKeysAndSelfTestCommit() throws {
        let ci = try repoFile(".github/workflows/ci.yml")
        for needle in ["PlistBuddy", "ShadowCommit", "ShadowRepo", "CFBundleShortVersionString", "ok $COMMIT"] {
            XCTAssertTrue(ci.contains(needle), needle)
        }
    }

    func testReleaseWorkflow() throws {
        let rel = try repoFile(".github/workflows/release.yml")
        for needle in ["tags:", "v*.*.*", "gh release create", "SHA256SUMS", "APP_REPO=$GITHUB_REPOSITORY", "scripts/bundle.sh",
                       "contents: write", "swift test", "hdiutil create", "ad-hoc"] {
            XCTAssertTrue(rel.contains(needle), needle)
        }
        XCTAssertTrue(rel.contains("secrets.SIGN_IDENTITY") || rel.contains("secrets.DEVELOPER_ID"), "signing is secret-gated")
    }

    func testPagesWorkflowPublishesDocs() throws {
        let pages = try repoFile(".github/workflows/pages.yml")
        XCTAssertTrue(pages.contains("path: docs"))
        XCTAssertTrue(pages.contains("deploy-pages"))
    }

    func testReadmeDocumentsReleaseAndUpdates() throws {
        let readme = try repoFile("README.md")
        for needle in ["## Cutting a release", "## How updates work", "Local-only", "SHA256SUMS", "Shadow.previous.app", "right-click",
                       "Homebrew cask", "notarization"] {
            XCTAssertTrue(readme.contains(needle), needle)
        }
        XCTAssertFalse(readme.contains("no release build yet"))
    }
}
