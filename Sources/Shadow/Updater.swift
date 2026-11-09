// SPDX-License-Identifier: Apache-2.0

import AppKit
import ShadowKit

/// Owns what the Updates pane shows and runs checks and installs. It does nothing on its own: no timer, no polling (R3).
/// A check or install starts only from a user action, and never when Local-only is on or in a development build (R5, R18).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private(set) var state: UpdateState
    /// "Updated to X" or the scrubbed rollback reason from the last hand-off, shown in the Updates pane (R13).
    var handoffText: String?
    private let defaults = UserDefaults.standard
    private let build = BuildInfo.current
    private let bundleURL = Bundle.main.bundleURL

    /// The check or install in flight, so Local-only can cancel it (R18).
    private var running: Task<Void, Never>?

    private init() { state = .idle; refreshGate() }

    var lastChecked: Date? { defaults.object(forKey: PrefsDefaults.lastUpdateCheck) as? Date }
    var versionLine: String { UpdatesCopy.versionLine(build) }

    private var gate: UpdateState? {
        UpdateState.gate(build: build, bundleURL: bundleURL, localOnly: defaults.bool(forKey: PrefsDefaults.localOnly))
    }

    /// Follows Local-only and the development-build rule. Turning Local-only off returns to idle; it never starts a check.
    func refreshGate() {
        if let gate {
            // Local-only (or a development build) means no contact with GitHub: stop whatever is running.
            if let running { running.cancel(); self.running = nil; try? FileManager.default.removeItem(at: AppPaths().updatesDir) }
            state = gate; return
        }
        if state == .developmentBuild || state == .pausedLocalOnly { state = .idle }
    }

    /// Snapshot mode only: shows a sample newer version so the popover row can be captured.
    func showSample(_ update: AvailableUpdate) { state = .available(update) }

    /// The one silent check at launch: only when due (R1). Same gate, no timer, no repeat.
    func launchCheckIfDue() async {
        refreshGate()
        guard state.canCheck else { return }
        let due = UpdateSchedule.launchCheckDue(
            autoChecks: defaults.bool(forKey: PrefsDefaults.autoUpdateChecks),
            lastSuccess: lastChecked,
            retryAfter: defaults.object(forKey: PrefsDefaults.lastUpdateRetryAfter) as? Date,
            now: Date())
        guard due else { return }
        await checkNow()
        // A silent check that fails says nothing at launch; the Updates pane shows the error only on a user action.
        if case .failed = state { state = .idle }
    }

    /// A user-requested check: ignores the once-a-day limit, not the gate or a rate-limit wait (R2, R6).
    func checkNow() async {
        refreshGate()
        guard state.canCheck else { return }
        let task = Task { await performCheck() }
        running = task
        await task.value
        if running == task { running = nil }
    }

    private func performCheck() async {
        if let wait = defaults.object(forKey: PrefsDefaults.lastUpdateRetryAfter) as? Date, Date() < wait {
            state = .failed(UpdateError(.rateLimited, detail: "waiting after HTTP 403/429")); return
        }
        state = .checking
        do {
            let outcome = try await UpdateChecker(transport: GitHubTransport(appVersion: build.version)).check(current: build.version)
            defaults.set(Date(), forKey: PrefsDefaults.lastUpdateCheck)
            defaults.removeObject(forKey: PrefsDefaults.lastUpdateRetryAfter)
            switch outcome {
            case .upToDate: state = .upToDate
            case .available(let u): state = .available(u)
            case .noDownloadableBuild: state = .noBuild
            }
        } catch {
            if UpdateCancellation.isCancellation(error) || Task.isCancelled { refreshGate(); return }   // paused: the gate set the state
            let e = error as? UpdateError ?? UpdateError(.badRelease, detail: String(describing: error))
            if e.kind == .rateLimited {
                defaults.set(Date().addingTimeInterval(UpdateChecker.rateLimitRetryAfter), forKey: PrefsDefaults.lastUpdateRetryAfter)
            }
            state = .failed(e)
        }
    }

    /// Downloads and verifies the update, then hands the swap to an external script and quits (R7-R11).
    func updateAndRelaunch() async {
        refreshGate()
        guard let update = state.availableUpdate else { return }
        let task = Task { await performInstall(update) }
        running = task
        await task.value
        if running == task { running = nil }
    }

    private func performInstall(_ update: AvailableUpdate) async {
        state = .installing(.downloading, 0)
        let paths = AppPaths()
        let installer = UpdateInstaller(transport: GitHubTransport(appVersion: build.version), paths: paths)
        do {
            let staged = try await installer.install(update, installedBundle: bundleURL) { step, fraction in
                Task { @MainActor in
                    if case .installing = Updater.shared.state { Updater.shared.state = .installing(step, fraction) }
                }
            }
            try Task.checkCancellation()   // Local-only may have been turned on during the last step
            state = .relaunching
            try UpdateSwap(installedApp: bundleURL, stagedApp: staged, paths: paths).launch(version: update.version)
            NSApp.terminate(nil)
        } catch {
            if UpdateCancellation.isCancellation(error) || Task.isCancelled {
                try? FileManager.default.removeItem(at: paths.updatesDir)
                refreshGate(); return
            }
            state = .failed(error as? UpdateError ?? UpdateError(.verificationFailed, detail: String(describing: error)))
        }
    }

    func copyDetails() {
        guard case .failed(let e) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.copyDetails(appVersion: build.version), forType: .string)
    }

    func reportOnGitHub() {
        guard case .failed(let e) = state, let url = e.issueURL(repo: build.repo, appVersion: build.version) else { return }
        NSWorkspace.shared.open(url)
    }
}
