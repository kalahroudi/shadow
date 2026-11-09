import XCTest
@testable import ShadowKit

final class FakeUpdateTransport: UpdateTransport, @unchecked Sendable {
    var body = Data(), status = 200
    var error: Error?
    private(set) var requested: [URL] = []
    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        requested.append(url)
        if let error { throw error }
        return (body, status)
    }
    func download(_ url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> Int { requested.append(url); return status }
}

final class UpdateVersionTests: XCTestCase {
    func testComparisonTable() {
        let newer: [(String, String)] = [("v1.2.3", "1.2.2"), ("1.10.0", "1.9.0"), ("2.0.0", "1.99.99"), ("1.0.0", "1.0.0-beta.2"),
                                         ("1.0.0-beta.2", "1.0.0-beta.1"), ("1.0.0-beta.10", "1.0.0-beta.9"), ("1.0.0-rc.1", "1.0.0-beta.2"), ("1.1", "1.0.9")]
        for (a, b) in newer {
            XCTAssertTrue(SemVer.isNewer(a, than: b), "\(a) > \(b)")
            XCTAssertFalse(SemVer.isNewer(b, than: a), "\(b) !> \(a)")
        }
        XCTAssertFalse(SemVer.isNewer("v1.2.3", than: "1.2.3"))
        XCTAssertFalse(SemVer.isNewer("1.0.0-beta.2", than: "1.0.0"))
        XCTAssertFalse(SemVer.isNewer("garbage", than: "1.0.0"))
        XCTAssertNil(SemVer("1.2.3.4")); XCTAssertNil(SemVer("1.-2.3")); XCTAssertNil(SemVer("1.0.0-"))
        XCTAssertEqual(SemVer("v1.2.3+build5")?.description, "1.2.3")
    }
}

final class UpdateCheckTests: XCTestCase {
    private func release(tag: String = "v1.1.0", draft: Bool = false, pre: Bool = false, assets: [String] = ["Shadow-1.1.0.dmg", "SHA256SUMS"], body: String = "- one") -> ReleaseInfo {
        let a = assets.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/kalahroudi/shadow/releases/download/\#(tag)/\#($0)","size":10}"# }.joined(separator: ",")
        let json = #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(pre),"body":"\#(body)","assets":[\#(a)]}"#
        return try! JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
    }

    func testNewerIsAvailableWithAssetAndChecksums() throws {
        guard case .available(let u) = try UpdateCheck.evaluate(release(), current: "1.0.0") else { return XCTFail() }
        XCTAssertEqual(u.version, "1.1.0")
        XCTAssertEqual(u.asset.name, "Shadow-1.1.0.dmg")
        XCTAssertEqual(u.checksums?.lastPathComponent, "SHA256SUMS")
    }

    func testSameOlderPrereleaseAndDraftOfferNothing() throws {
        XCTAssertEqual(try UpdateCheck.evaluate(release(), current: "1.1.0"), .upToDate)
        XCTAssertEqual(try UpdateCheck.evaluate(release(), current: "2.0.0"), .upToDate)
        XCTAssertEqual(try UpdateCheck.evaluate(release(pre: true), current: "1.0.0"), .upToDate)
        XCTAssertEqual(try UpdateCheck.evaluate(release(draft: true), current: "1.0.0"), .upToDate)
        XCTAssertEqual(try UpdateCheck.evaluate(release(tag: "v2.0.0-beta.1"), current: "1.0.0"), .upToDate)
    }

    func testNoDmgOrZipMeansNoDownloadableBuild() throws {
        XCTAssertEqual(try UpdateCheck.evaluate(release(assets: ["SHA256SUMS", "notes.txt"]), current: "1.0.0"), .noDownloadableBuild)
    }

    func testAssetPreference() throws {
        guard case .available(let a) = try UpdateCheck.evaluate(release(assets: ["x.zip", "other.dmg", "Shadow-1.1.0.dmg"]), current: "1.0.0"),
              case .available(let b) = try UpdateCheck.evaluate(release(assets: ["x.zip", "other.dmg"]), current: "1.0.0"),
              case .available(let c) = try UpdateCheck.evaluate(release(assets: ["x.zip"]), current: "1.0.0") else { return XCTFail() }
        XCTAssertEqual([a.asset.name, b.asset.name, c.asset.name], ["Shadow-1.1.0.dmg", "other.dmg", "x.zip"])
    }

    func testBadTagThrowsBadRelease() {
        XCTAssertThrowsError(try UpdateCheck.evaluate(release(tag: "nightly"), current: "1.0.0")) { XCTAssertEqual(($0 as? UpdateError)?.kind, .badRelease) }
    }

    func testNotesSummaryIsFirstEightLinesWithoutBullets() {
        let notes = (1...12).map { "- item \($0)" }.joined(separator: "\n")
        let lines = UpdateCheck.summary("## What's new\n\n" + notes).split(separator: "\n")
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines.first, "What's new")
        XCTAssertEqual(lines.last, "item 7")
    }

    // MARK: checker over a fake transport
    func testMalformedJsonIsFriendlyErrorAndNoUpdate() async {
        let t = FakeUpdateTransport(); t.body = Data("{not json".utf8)
        await assertFails(t, .badRelease)
        t.body = Data(#"{"draft":false}"#.utf8)
        await assertFails(t, .badRelease)
    }

    func testRateLimitStatuses() async {
        for code in [403, 429] {
            let t = FakeUpdateTransport(); t.status = code
            await assertFails(t, .rateLimited)
        }
        XCTAssertGreaterThanOrEqual(UpdateChecker.rateLimitRetryAfter, 3600)
    }

    func testOfflineAndServerError() async {
        let t = FakeUpdateTransport(); t.error = URLError(.notConnectedToInternet)
        await assertFails(t, .offline)
        let s = FakeUpdateTransport(); s.status = 500
        await assertFails(s, .badRelease)
    }

    func testCheckerUsesAllowlistedLatestURL() async throws {
        let t = FakeUpdateTransport()
        t.body = Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8)
        let out = try await UpdateChecker(transport: t).check(current: "1.0.0")
        XCTAssertEqual(out, .upToDate)
        XCTAssertEqual(t.requested, [UpdateChecker.latestURL])
        XCTAssertTrue(UpdateHosts.allowsRequest(UpdateChecker.latestURL))
    }

    private func assertFails(_ t: FakeUpdateTransport, _ kind: UpdateError.Kind, line: UInt = #line) async {
        do { _ = try await UpdateChecker(transport: t).check(current: "1.0.0"); XCTFail("expected \(kind)", line: line) }
        catch { XCTAssertEqual((error as? UpdateError)?.kind, kind, line: line) }
    }
}

final class UpdateTransportTests: XCTestCase {
    func testRequestHasOnlyUserAgentAndNoCookiesOrAuth() throws {
        let r = try UpdateRequest.make(UpdateChecker.latestURL, appVersion: "1.2.3")
        XCTAssertEqual(r.allHTTPHeaderFields, ["User-Agent": "Shadow/1.2.3"])
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
    }

    func testRequestsToOtherHostsOrPlainHttpAreRefused() {
        for s in ["https://example.com/x", "http://api.github.com/x", "https://github.com.evil.com/x", "https://objects.githubusercontent.com/x"] {
            XCTAssertThrowsError(try UpdateRequest.make(URL(string: s)!, appVersion: "1"), s)
        }
        XCTAssertNoThrow(try UpdateRequest.make(URL(string: "https://github.com/kalahroudi/shadow/releases/download/v1/a.dmg")!, appVersion: "1"))
    }

    func testRedirectGuardFollowsAssetHostsAndRefusesForeign() {
        let g = RedirectGuard()
        XCTAssertNotNil(g.decide(URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/a")!)))
        XCTAssertNotNil(g.decide(URLRequest(url: URL(string: "https://objects.githubusercontent.com/a")!)))
        XCTAssertFalse(g.refused)
        XCTAssertNil(g.decide(URLRequest(url: URL(string: "https://evil.example.com/a")!)))
        XCTAssertTrue(g.refused)
        XCTAssertNil(RedirectGuard().decide(URLRequest(url: URL(string: "http://github.com/a")!)))
    }
}

final class UpdateErrorTests: XCTestCase {
    private let all: [UpdateError.Kind] = [.offline, .rateLimited, .checksumMismatch, .verificationFailed, .badRelease, .notWritable, .noBuild, .identityRefused]

    func testEachKindIsOneFriendlySentenceThroughUserError() {
        for k in all {
            let m = UserError.message(for: UpdateError(k, detail: "/Users/x/file exit status 1 UpdateError"), action: "Update")
            XCTAssertFalse(m.contains("/"), m); XCTAssertFalse(m.lowercased().contains("exit"), m)
            XCTAssertFalse(m.contains("UpdateError"), m); XCTAssertFalse(m.contains("Settings → About"), m)
            XCTAssertTrue(m.hasSuffix("."), m)
        }
        XCTAssertTrue(UpdateError(.notWritable).message.contains("Move Shadow to a folder you own"))
    }

    func testCopyDetailsAndIssueURLAreScrubbed() throws {
        let home = "/Users/alice", user = "alice"
        let e = UpdateError(.verificationFailed, detail: "codesign failed at /Users/alice/Library/x token=ghp_abcdefghijklmnop1234 user alice")
        let copy = e.copyDetails(appVersion: "1.0.0", home: home, user: user)
        let url = try XCTUnwrap(e.issueURL(appVersion: "1.0.0", home: home, user: user))
        let body = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        for text in [copy, body, url.absoluteString] {
            XCTAssertFalse(text.contains("/Users/alice"), text); XCTAssertFalse(text.contains("alice"), text)
            XCTAssertFalse(text.contains("ghp_abcdefghijklmnop1234"), text)
        }
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(copy.contains("verificationFailed"))
    }
}
