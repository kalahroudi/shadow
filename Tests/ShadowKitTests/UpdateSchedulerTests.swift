import XCTest
@testable import ShadowKit

final class UpdateSchedulerTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private let suite = "shadow-sched-\(UUID().uuidString)"
    private var d: UserDefaults!
    private var clock: Clock!
    private var transport: FakeUpdateTransport!

    private static let json = #"{"tag_name":"v1.1.0","draft":false,"prerelease":false,"body":"- x","assets":[{"name":"Shadow-1.1.0.dmg","browser_download_url":"https://github.com/kalahroudi/shadow/releases/download/v1.1.0/Shadow-1.1.0.dmg"}]}"#

    override func setUp() {
        d = UserDefaults(suiteName: suite)!
        PrefsDefaults.register(in: d)
        clock = Clock()
        transport = FakeUpdateTransport()
        transport.body = Data(Self.json.utf8)
    }
    override func tearDown() { d.removePersistentDomain(forName: suite) }

    private func scheduler(commit: String? = "abc1234", path: String = "/Applications/Shadow.app") -> UpdateScheduler {
        let c = clock!, t = transport!
        return UpdateScheduler(transport: t, defaults: UserDefaults(suiteName: suite)!, build: BuildInfo(commit: commit, version: "1.0.0"),
                               bundleURL: URL(fileURLWithPath: path), now: { c.date })
    }

    func testLaunchCheckRunsWhenNeverCheckedOrOlderThan24h() async {
        let s = scheduler()
        var r = await s.launchCheckIfDue()
        guard case .available = r else { return XCTFail("\(r)") }
        XCTAssertEqual(transport.requested.count, 1)
        clock.date += 24 * 3600 + 1
        r = await s.launchCheckIfDue()
        XCTAssertEqual(transport.requested.count, 2)
    }

    func testLaunchCheckSkippedUnder24hAndWhenAutoOff() async {
        let s = scheduler()
        _ = await s.launchCheckIfDue()
        clock.date += 24 * 3600 - 60
        let r = await s.launchCheckIfDue()
        XCTAssertEqual(r, .notDue)
        XCTAssertEqual(transport.requested.count, 1)

        d.set(false, forKey: PrefsDefaults.autoUpdateChecks)
        clock.date += 7 * 24 * 3600
        let off = await s.launchCheckIfDue()
        XCTAssertEqual(off, .notDue)
        XCTAssertEqual(transport.requested.count, 1)
    }

    func testFailedCheckLeavesLastSuccessUnchanged() async {
        let s = scheduler()
        _ = await s.launchCheckIfDue()
        let last = await s.lastSuccessfulCheck
        XCTAssertNotNil(last)
        clock.date += 25 * 3600
        transport.error = URLError(.notConnectedToInternet)
        let r = await s.launchCheckIfDue()
        XCTAssertEqual(r, .failed(UpdateError(.offline)))
        let after = await s.lastSuccessfulCheck
        XCTAssertEqual(after, last)
        // Still due, so the next launch tries again.
        transport.error = nil
        _ = await s.launchCheckIfDue()
        XCTAssertEqual(transport.requested.count, 3)
    }

    func testManualCheckIgnoresDailyLimit() async {
        let s = scheduler()
        _ = await s.launchCheckIfDue()
        let blocked = await s.launchCheckIfDue()
        XCTAssertEqual(blocked, .notDue)
        let r = await s.checkNow()
        guard case .available = r else { return XCTFail("\(r)") }
        XCTAssertEqual(transport.requested.count, 2)
    }

    func testManualCheckRunsEvenWithAutoChecksOff() async {
        d.set(false, forKey: PrefsDefaults.autoUpdateChecks)
        let r = await scheduler().checkNow()
        guard case .available = r else { return XCTFail("\(r)") }
    }

    func testDevelopmentBuildsNeverTouchTheNetwork() async {
        for s in [scheduler(commit: nil), scheduler(commit: "unknown"), scheduler(commit: ""), scheduler(path: "/tmp/.build/debug/Shadow")] {
            let a = await s.launchCheckIfDue(), b = await s.checkNow()
            XCTAssertEqual(a, .developmentBuild); XCTAssertEqual(b, .developmentBuild)
        }
        XCTAssertTrue(transport.requested.isEmpty)
    }

    func testLocalOnlyNeverTouchesTheNetworkAndTurningOffAllowsManualButNotLimitBypass() async {
        d.set(true, forKey: PrefsDefaults.localOnly)
        let s = scheduler()
        let a = await s.launchCheckIfDue(), b = await s.checkNow()
        XCTAssertEqual(a, .pausedLocalOnly); XCTAssertEqual(b, .pausedLocalOnly)
        XCTAssertTrue(transport.requested.isEmpty)

        d.set(false, forKey: PrefsDefaults.localOnly)
        let m = await s.checkNow()
        guard case .available = m else { return XCTFail("\(m)") }
        // Turning it off did not reset the limit: the launch check is still not due.
        let l = await s.launchCheckIfDue()
        XCTAssertEqual(l, .notDue)
        XCTAssertEqual(transport.requested.count, 1)
    }

    func testRateLimitSetsRetryAfterOfAtLeastAnHour() async {
        transport.status = 429
        let s = scheduler()
        let r = await s.launchCheckIfDue()
        XCTAssertEqual(r, .failed(UpdateError(.rateLimited, detail: "HTTP 429")))
        let wait = await s.retryAfter
        XCTAssertGreaterThanOrEqual(wait!.timeIntervalSince(clock.date), 3600)
        let lastSuccess = await s.lastSuccessfulCheck
        XCTAssertNil(lastSuccess)

        clock.date += 1800
        let again = await s.launchCheckIfDue(), manual = await s.checkNow()
        XCTAssertEqual(transport.requested.count, 1, "no retry within the hour: \(again) \(manual)")

        clock.date += 1801
        transport.status = 200
        let ok = await s.checkNow()
        guard case .available = ok else { return XCTFail("\(ok)") }
        let cleared = await s.retryAfter
        XCTAssertNil(cleared)
    }

    func testMalformedJSONIsAFriendlyErrorAndRecordsNoSuccess() async {
        transport.body = Data("{not json".utf8)
        let s = scheduler()
        let r = await s.checkNow()
        guard case .failed(let e) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.kind, .badRelease)
        let last = await s.lastSuccessfulCheck
        XCTAssertNil(last)
    }
}
