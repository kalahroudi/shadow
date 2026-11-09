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

    func testCIBuildsTestsBundlesAndSelfTests() throws {
        let ci = try repoFile(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("runs-on: macos-26"))
        XCTAssertTrue(ci.contains("permissions:\n  contents: read"), "CI token must be read-only")
        XCTAssertFalse(ci.contains("secrets."), "CI must not use secrets")
        for step in ["swift build", "swift test", "scripts/bundle.sh", "--self-test", "shadow-mcp --version"] {
            XCTAssertTrue(ci.contains(step), step)
        }
    }

    func testNoUpdaterOrAgentsCodeRemains() throws {
        let fm = FileManager.default
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        for gone in ["Sources/ShadowKit/Update.swift", "Sources/ShadowKit/Agents.swift", "Sources/Shadow/Updater.swift",
                     "Sources/Shadow/UpdatesView.swift", "Sources/Shadow/AgentsView.swift", "Sources/Shadow/ManagerView.swift"] {
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
}
