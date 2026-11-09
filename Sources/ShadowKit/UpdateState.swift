// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the Updates pane shows (R14, R18).
public enum UpdateState: Equatable, Sendable {
    case developmentBuild
    case pausedLocalOnly
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
    case noBuild
    case installing(InstallStep, Double)
    case relaunching
    case failed(UpdateError)

    /// "Check for updates" is enabled only when GitHub may be contacted and nothing is running.
    public var canCheck: Bool {
        switch self {
        case .developmentBuild, .pausedLocalOnly, .checking, .installing, .relaunching: false
        default: true
        }
    }
    /// "Update and relaunch" is enabled only for a known newer version.
    public var canInstall: Bool { if case .available = self { true } else { false } }
    public var availableUpdate: AvailableUpdate? { if case .available(let u) = self { u } else { nil } }

    /// The popover's "Update available" row shows only while a newer version is known (R15). Gated states are never `.available`.
    public var showsPopoverRow: Bool { canInstall }

    /// Development builds and Local-only mode stop all network use; they win over any other state (R5, R18).
    public static func gate(build: BuildInfo, bundleURL: URL, localOnly: Bool) -> UpdateState? {
        if bundleURL.pathExtension != "app" || build.cleanCommit == nil { return .developmentBuild }
        if localOnly { return .pausedLocalOnly }
        return nil
    }
}

/// The launch check's rules (R1). There is no timer: this is asked once at launch.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600

    /// True when automatic checks are on, no rate-limit wait is active, and the last success is absent or more than 24 h old.
    /// A failed check never writes `lastSuccess`, so it does not postpone the next one.
    public static func launchCheckDue(autoChecks: Bool, lastSuccess: Date?, retryAfter: Date?, now: Date) -> Bool {
        guard autoChecks else { return false }
        if let retryAfter, now < retryAfter { return false }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > interval
    }
}

/// Fixed wording for the Updates pane.
public enum UpdatesCopy {
    /// "Version 1.2.3 (abc1234)", with "(modified)" for a dirty tree and "development build" without a commit.
    public static func versionLine(_ build: BuildInfo) -> String {
        guard build.cleanCommit != nil else { return "Version \(build.version) (development build)" }
        return "Version \(build.version) (\(build.shortCommit))" + (build.isDirty ? " (modified)" : "")
    }

    public static func stepLabel(_ step: InstallStep) -> String {
        switch step {
        case .downloading: "Downloading the update…"
        case .checking: "Checking the download…"
        case .unpacking: "Unpacking the update…"
        case .verifying: "Verifying the new version…"
        }
    }

    public static let pausedNotice = "Update checks are paused because Local-only mode is on. Shadow does not contact GitHub."
    public static let developmentNotice = "This is a development build. Updates are only offered to installed release builds."

    /// One status sentence, or nil when there is nothing to say yet.
    public static func status(_ state: UpdateState) -> String? {
        switch state {
        case .developmentBuild: developmentNotice
        case .pausedLocalOnly: pausedNotice
        case .idle: nil
        case .checking: "Checking for updates…"
        case .upToDate: "Shadow is up to date."
        case .available(let u): "Shadow \(u.version) is available."
        case .noBuild: UpdateError(.noBuild).message
        case .installing(let step, _): stepLabel(step)
        case .relaunching: "Relaunching Shadow…"
        case .failed(let e): e.message
        }
    }

    /// The permissions line for the Updates pane (R16, R24).
    public static func permissionsNote(_ note: UpdateDecision.Note) -> String {
        switch note {
        case .permissionsCarryOver: "Permissions will carry over"
        case .permissionsWillReset: "This build is not signed with a stable identity, so Screen Recording and Microphone access will need to be granted again after each update."
        }
    }

    public static func lastChecked(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
