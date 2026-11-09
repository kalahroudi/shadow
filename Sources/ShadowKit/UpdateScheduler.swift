// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a scheduler call did (R1, R2, R5, R6, R18).
public enum UpdateRunResult: Equatable, Sendable {
    /// Not a release build: never checks, offers or installs (R5).
    case developmentBuild
    /// Local-only mode is on: GitHub is never contacted (R18).
    case pausedLocalOnly
    /// A launch check that was not due (automatic checks off, checked recently, or waiting after a rate limit). No network.
    case notDue
    case upToDate
    case available(AvailableUpdate)
    case noBuild
    case failed(UpdateError)
}

/// Decides when a check may run. There is no timer and no polling: a check happens only when the app calls
/// `launchCheckIfDue()` at launch or `checkNow()` on user action (R3).
public actor UpdateScheduler {
    public static let checkInterval: TimeInterval = 24 * 3600

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let build: BuildInfo
    private let bundleURL: URL

    public init(transport: any UpdateTransport, defaults: UserDefaults = .standard, build: BuildInfo = .current,
                bundleURL: URL = Bundle.main.bundleURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.checker = UpdateChecker(transport: transport)
        self.defaults = defaults; self.build = build; self.bundleURL = bundleURL; self.now = now
    }

    /// Not running from a `.app`, or no usable commit stamped (R5).
    public static func isDevelopmentBuild(_ build: BuildInfo, bundleURL: URL) -> Bool {
        bundleURL.pathExtension != "app" || build.cleanCommit == nil
    }

    public var lastSuccessfulCheck: Date? { defaults.object(forKey: PrefsDefaults.lastUpdateCheck) as? Date }
    public var retryAfter: Date? { defaults.object(forKey: PrefsDefaults.lastUpdateRetryAfter) as? Date }

    /// The silent check at launch: only when automatic checks are on, the last success is over 24 h old (or absent)
    /// and no rate-limit wait is running (R1, R6).
    public func launchCheckIfDue() async -> UpdateRunResult {
        if let gate = gate() { return gate }
        guard defaults.object(forKey: PrefsDefaults.autoUpdateChecks) as? Bool ?? true else { return .notDue }
        if let last = lastSuccessfulCheck, now().timeIntervalSince(last) <= Self.checkInterval { return .notDue }
        return await run()
    }

    /// A user-requested check: ignores the once-a-day limit, not Local-only, the development-build rule or a rate-limit wait (R2).
    public func checkNow() async -> UpdateRunResult {
        if let gate = gate() { return gate }
        return await run()
    }

    private func gate() -> UpdateRunResult? {
        if Self.isDevelopmentBuild(build, bundleURL: bundleURL) { return .developmentBuild }
        if defaults.bool(forKey: PrefsDefaults.localOnly) { return .pausedLocalOnly }
        return nil
    }

    private func run() async -> UpdateRunResult {
        if let wait = retryAfter, now() < wait { return .failed(UpdateError(.rateLimited, detail: "waiting after HTTP 403/429")) }
        do {
            let outcome = try await checker.check(current: build.version)
            defaults.set(now(), forKey: PrefsDefaults.lastUpdateCheck)
            defaults.removeObject(forKey: PrefsDefaults.lastUpdateRetryAfter)
            switch outcome {
            case .upToDate: return .upToDate
            case .available(let u): return .available(u)
            case .noDownloadableBuild: return .noBuild
            }
        } catch let e as UpdateError {
            if e.kind == .rateLimited {
                defaults.set(now().addingTimeInterval(UpdateChecker.rateLimitRetryAfter), forKey: PrefsDefaults.lastUpdateRetryAfter)
            }
            return .failed(e)
        } catch {
            return .failed(UpdateError(.badRelease, detail: String(describing: error)))
        }
    }
}
