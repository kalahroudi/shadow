import XCTest
@testable import ShadowKit

/// Guards the scaffold decisions of milestone 1 (R1, R25): they live in files, so the tests read the files.
final class PackageTests: XCTestCase {
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/ShadowKitTests/<file> -> repo root
        return url
    }

    private func repoFile(_ path: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
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
        for key in ["NSAppleEventsUsageDescription", "NSAccessibilityUsageDescription", "NSInputMonitoringUsageDescription"] {
            XCTAssertFalse(script.contains(key), "\(key) is not needed")
        }
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

    func testPermissionsDocRecordsAudioCaptureDecision() throws {
        let doc = try repoFile("docs/permissions.md")
        for needle in ["kTCCServiceAudioCapture", "Decision: is kTCCServiceAudioCapture needed?", "ad-hoc", "Self-signed",
                       "CGRequestScreenCaptureAccess", "SCShareableContent", "SCStream", "AVCaptureDevice.requestAccess",
                       "process tap", "scripts/reset-permissions.sh", "CGPreflightScreenCaptureAccess", "AVAudioEngine"] {
            XCTAssertTrue(doc.localizedCaseInsensitiveContains(needle), "docs/permissions.md is missing \(needle)")
        }
        XCTAssertTrue(doc.contains("**Undecided."), "the decision must stay undecided until measured")
        XCTAssertFalse(doc.contains("Provisional answer: no"), "no unmeasured yes/no answer")
        let rows = doc.split(separator: "\n").filter { $0.hasPrefix("| `") && $0.contains("TBD") }
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertFalse(row.contains("granted") || row.contains("listed"), "untested row holds a result: \(row)") }
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

    func testBundleScriptSignsWithStableIdentityAndChecksDR() throws {
        let bundle = try repoFile("scripts/bundle.sh")
        XCTAssertEqual(bundle.components(separatedBy: "com.kalahroudi.shadow").count - 1, 1, "bundle ID is defined once in bundle.sh")
        XCTAssertTrue(bundle.contains("BUNDLE_ID=\"com.kalahroudi.shadow\""))
        XCTAssertTrue(bundle.contains("scripts/sign-app.sh \"$APP\""))
        let script = try repoFile("scripts/sign-app.sh")
        for needle in ["SIGNING_IDENTITY", "Developer ID Application", "Shadow Signing", "certificate leaf = H",
                       "certificate leaf[subject.OU]", "anchor apple generic and identifier", "--options runtime",
                       "--entitlements scripts/Shadow.entitlements", "--verify --deep --strict", "codesign -d -r-",
                       "cdhash (not the identity)", "RESET", "security find-certificate", "x509 -noout -subject"] {
            XCTAssertTrue(script.contains(needle), needle)
        }
        let stubs = try repoFile("scripts/test-signing-stubs.sh")
        XCTAssertTrue(stubs.contains("R6=") && stubs.contains("R5=") && stubs.contains("R8="), "exact DR strings are asserted")
    }

    func testNoOldSigningVariableRemains() throws {
        for path in ["scripts/bundle.sh", "scripts/sign-app.sh", "scripts/make-signing-identity.sh", "scripts/test-signing.sh", "scripts/Shadow.entitlements", "README.md"] {
            XCTAssertFalse(try repoFile(path).contains("SIGN_IDENTITY"), path)
        }
    }

    func testSigningScriptsExistAndAreSafe() throws {
        let make = try repoFile("scripts/make-signing-identity.sh")
        for needle in ["already exists", "--export-p12", "chmod 600", "-days 7300", "codeSigning", "-T /usr/bin/codesign"] {
            XCTAssertTrue(make.contains(needle), needle)
        }
        XCTAssertFalse(make.contains(" -A "), "the key must not be open to every app")
        let test = try repoFile("scripts/test-signing.sh")
        for needle in ["trap cleanup EXIT", "delete-keychain", "SIGNING_KEYCHAIN", "list-keychains"] {
            XCTAssertTrue(test.contains(needle), needle)
        }
        let fm = FileManager.default
        for name in ["bundle.sh", "make-signing-identity.sh", "test-signing.sh"] {
            XCTAssertTrue(fm.isExecutableFile(atPath: repoRoot().appendingPathComponent("scripts/\(name)").path), name)
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
                       "contents: write", "swift test", "hdiutil create", "ad-hoc", "SIGNING_P12_BASE64", "SIGNING_P12_PASSWORD",
                       "set-key-partition-list", "::add-mask::", "if: always()", "security delete-keychain",
                       "will reset on every update", "Open once"] {
            XCTAssertTrue(rel.contains(needle), needle)
        }
        XCTAssertTrue(rel.contains("SIGNING_IDENTITY: ${{ steps.sign.outputs.identity }}"), "bundle.sh reads SIGNING_IDENTITY, not the old name")
        XCTAssertFalse(rel.contains("SIGN_IDENTITY="))
        XCTAssertFalse(rel.contains("SIGN_IDENTITY:"))
        XCTAssertTrue(rel.contains("secrets.SIGN_IDENTITY") || rel.contains("secrets.DEVELOPER_ID"), "signing is secret-gated")
        XCTAssertFalse(rel.contains("set -x"))
    }

    /// R15: secrets reach only the import and notarize steps, never Build, Test, Bundle or Publish.
    func testReleaseSecretsAreOnlyInImportAndNotarizeSteps() throws {
        let rel = try repoFile(".github/workflows/release.yml")
        let steps = rel.components(separatedBy: "\n      - ")
        var seen = 0
        for step in steps where step.contains("secrets.") {
            seen += 1
            let name = step.prefix { $0 != "\n" }
            XCTAssertTrue(name.contains("Import signing certificate") || name.contains("Notarize"), "secrets in step: \(name)")
        }
        XCTAssertEqual(seen, 2)
        XCTAssertFalse(try repoFile(".github/workflows/ci.yml").contains("secrets."))
    }

    func testCIRunsDRCheckAndSigningShellTest() throws {
        let ci = try repoFile(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("check-signing.sh --adhoc-fallback"))
        XCTAssertTrue(ci.contains("scripts/test-signing.sh"))
    }

    func testCheckSigningScript() throws {
        let check = try repoFile("scripts/check-signing.sh")
        for needle in ["grants will persist", "grants will reset", "--adhoc-fallback", "codesign -d -r-"] {
            XCTAssertTrue(check.contains(needle), needle)
        }
    }

    func testOnlyOneBundleIDInScriptsAndWorkflows() throws {
        for path in ["scripts/bundle.sh", "scripts/check-signing.sh", "scripts/test-signing.sh",
                     ".github/workflows/ci.yml", ".github/workflows/release.yml"] {
            let text = try repoFile(path)
            for token in text.components(separatedBy: CharacterSet(charactersIn: "\"' \n$")) where token.hasPrefix("com.") {
                XCTAssertEqual(token, "com.kalahroudi.shadow", "\(path): \(token)")
            }
        }
    }

    func testPagesWorkflowPublishesDocs() throws {
        let pages = try repoFile(".github/workflows/pages.yml")
        XCTAssertTrue(pages.contains("path: docs"))
        XCTAssertTrue(pages.contains("deploy-pages"))
    }

    func testReadmeDocumentsReleaseAndUpdates() throws {
        let readme = try repoFile("README.md")
        for needle in ["## Cutting a release", "## How updates work", "Local-only", "SHA256SUMS", "Shadow.previous.app", "right-click",
                       "Homebrew cask", "notarization", "## Why signing matters / permissions", "make-signing-identity.sh",
                       "not notarized", "right-click", "untested", "Developer ID", "SIGNING_IDENTITY", "check-signing.sh",
                       "SIGNING_P12_BASE64", "if: always()"] {
            XCTAssertTrue(readme.contains(needle), needle)
        }
        XCTAssertFalse(readme.contains("no release build yet"))
    }
}
