// SPDX-License-Identifier: Apache-2.0

import AppKit
import ShadowKit

/// Owns what the Updates pane shows and runs checks and installs. It does nothing on its own: no timer, no polling (R3).
/// A check or install starts only from a user action, and never when Local-only is on or in a development build (R5, R18).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private(set) var state: UpdateState
    private let defaults = UserDefaults.standard
    private let build = BuildInfo.current
    private let bundleURL = Bundle.main.bundleURL

    private init() { state = .idle; refreshGate() }

    var lastChecked: Date? { defaults.object(forKey: PrefsDefaults.lastUpdateCheck) as? Date }
    var versionLine: String { UpdatesCopy.versionLine(build) }

    private var gate: UpdateState? {
        UpdateState.gate(build: build, bundleURL: bundleURL, localOnly: defaults.bool(forKey: PrefsDefaults.localOnly))
    }

    /// Follows Local-only and the development-build rule. Turning Local-only off returns to idle; it never starts a check.
    func refreshGate() {
        if let gate { state = gate; return }
        if state == .developmentBuild || state == .pausedLocalOnly { state = .idle }
    }

    /// A user-requested check: ignores the once-a-day limit, not the gate or a rate-limit wait (R2, R6).
    func checkNow() async {
        refreshGate()
        guard state.canCheck else { return }
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
        state = .installing(.downloading, 0)
        let paths = AppPaths()
        let installer = UpdateInstaller(transport: GitHubTransport(appVersion: build.version), paths: paths)
        do {
            let staged = try await installer.install(update, installedBundle: bundleURL) { step, fraction in
                Task { @MainActor in
                    if case .installing = Updater.shared.state { Updater.shared.state = .installing(step, fraction) }
                }
            }
            state = .relaunching
            try UpdateSwap(installedApp: bundleURL, stagedApp: staged, paths: paths).launch(version: update.version)
            NSApp.terminate(nil)
        } catch {
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
