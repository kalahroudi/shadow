import XCTest
@testable import ShadowKit

final class UpdateStateTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Shadow.app")
    private let release = BuildInfo(commit: "abcdef1234567", version: "1.0.0")
    private var update: AvailableUpdate {
        AvailableUpdate(version: "1.1.0", notes: "", asset: .init(name: "Shadow-1.1.0.dmg", url: URL(string: "https://github.com/x.dmg")!, size: nil), checksums: nil)
    }

    func testGateReportsDevelopmentBuildsAndLocalOnly() {
        XCTAssertEqual(UpdateState.gate(build: BuildInfo(commit: nil), bundleURL: app, localOnly: false), .developmentBuild)
        XCTAssertEqual(UpdateState.gate(build: BuildInfo(commit: "unknown"), bundleURL: app, localOnly: false), .developmentBuild)
        XCTAssertEqual(UpdateState.gate(build: release, bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/Shadow"), localOnly: false), .developmentBuild)
        XCTAssertEqual(UpdateState.gate(build: release, bundleURL: app, localOnly: true), .pausedLocalOnly)
        XCTAssertNil(UpdateState.gate(build: release, bundleURL: app, localOnly: false), "turning Local-only off allows checks again")
    }

    func testButtonsFollowState() {
        for s in [UpdateState.pausedLocalOnly, .developmentBuild, .checking, .installing(.downloading, 0.5), .relaunching] {
            XCTAssertFalse(s.canCheck, "\(s)")
        }
        for s in [UpdateState.idle, .upToDate, .noBuild, .failed(UpdateError(.offline)), .available(update)] { XCTAssertTrue(s.canCheck, "\(s)") }
        XCTAssertTrue(UpdateState.available(update).canInstall)
        for s in [UpdateState.idle, .upToDate, .pausedLocalOnly, .checking, .noBuild, .failed(UpdateError(.offline))] { XCTAssertFalse(s.canInstall, "\(s)") }
    }

    func testVersionLine() {
        XCTAssertEqual(UpdatesCopy.versionLine(release), "Version 1.0.0 (abcdef1)")
        XCTAssertEqual(UpdatesCopy.versionLine(BuildInfo(commit: "abcdef1234567-dirty", version: "1.0.0")), "Version 1.0.0 (abcdef1) (modified)")
        XCTAssertEqual(UpdatesCopy.versionLine(BuildInfo(commit: nil, version: "1.0.0")), "Version 1.0.0 (development build)")
    }

    func testStatusSentences() {
        XCTAssertTrue(UpdatesCopy.status(.pausedLocalOnly)!.contains("Local-only"))
        XCTAssertEqual(UpdatesCopy.status(.failed(UpdateError(.rateLimited, detail: "HTTP 429"))), UpdateError(.rateLimited).message)
        XCTAssertNil(UpdatesCopy.status(.idle))
        XCTAssertEqual(UpdatesCopy.status(.installing(.verifying, 0)), UpdatesCopy.stepLabel(.verifying))
        XCTAssertEqual(UpdatesCopy.lastChecked(nil), "Never")
    }

    func testUpdateDefaultsAreAutoOnLocalOff() {
        let d = UserDefaults(suiteName: "updstate-\(UUID().uuidString)")!
        PrefsDefaults.register(in: d)
        XCTAssertTrue(d.bool(forKey: PrefsDefaults.autoUpdateChecks))
        XCTAssertFalse(d.bool(forKey: PrefsDefaults.localOnly))
    }
}
