// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// The two permissions a session needs (R7).
public enum PermissionKind: String, CaseIterable, Sendable {
    case screen       // Screen & System Audio Recording: the Them stream
    case microphone   // the You stream
}

public enum PermissionState: Equatable, Sendable { case granted, notGranted, notYetAsked }

/// Makes Shadow appear in a System Settings privacy list (R2, R9). Every call goes through the real request path, whatever happened before.
/// The real one lives in the app target; tests use a fake that never touches TCC.
public protocol PermissionRegistrar: Sendable {
    func register(_ kind: PermissionKind) async
}

/// Reads and requests permissions. The real one lives in the app target; tests use a fake.
public protocol PermissionChecker: Sendable {
    func status(_ kind: PermissionKind) -> PermissionState
    /// Shows the system prompt where macOS allows it, then returns the new state.
    func request(_ kind: PermissionKind) async -> PermissionState
}

/// What to show once Allow was pressed and the permission is still missing (R3).
public struct NextSteps: Equatable, Sendable {
    public let settingsURL: String
    public let revealTitle: String
    public let hint: String
    public let checkAgainTitle: String
    /// The relaunch note, for screen recording only.
    public let relaunchNote: String?
}

/// One row of the "fix your permissions" checklist.
public struct ChecklistItem: Equatable, Identifiable, Sendable {
    public static let staleText = "macOS no longer lists Shadow as allowed (this happens when the app is rebuilt or its signature changed)"

    public var id: PermissionKind { kind }
    public let kind: PermissionKind
    public let state: PermissionState
    public let title: String
    public let explanation: String
    /// A System Settings deep link, shown as copyable text and as an Open button.
    public let settingsURL: String
    /// Extra advice, e.g. the relaunch note for screen recording.
    public let note: String?
    /// True when it was granted before and macOS no longer lists it.
    public let isStale: Bool
    /// Allow is offered for every permission that is not granted, whatever the history (R1).
    public var canRequest: Bool { true }
    /// Wording only; it never decides whether an action is offered (R7).
    public var statusLabel: String { state == .notYetAsked ? "Not asked yet" : "Not granted" }
    public var staleText: String? { isStale ? Self.staleText : nil }
    public var nextSteps: NextSteps {
        NextSteps(settingsURL: settingsURL, revealTitle: "Reveal Shadow.app in Finder",
                  hint: "If Shadow is not in the list, click + and add it, or drag Shadow.app into the list",
                  checkAgainTitle: "I did it - check again", relaunchNote: note)
    }
}

public enum Checklist {
    /// The microphone state straight from the system authorization: `.notDetermined` is the only "not yet asked" (R7).
    public static func state(fromAuthorization status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notYetAsked
        default: return .notGranted
        }
    }

    /// Items for every permission that is not granted, screen first. Empty means Start may proceed.
    /// `grantedBefore` holds the permissions Shadow once recorded as granted; one of those that is missing now is stale (R8).
    public static func items(mic: PermissionState, screen: PermissionState, grantedBefore: Set<PermissionKind> = []) -> [ChecklistItem] {
        var out: [ChecklistItem] = []
        if screen != .granted {
            out.append(ChecklistItem(
                kind: .screen, state: screen, title: "Screen & System Audio Recording",
                explanation: "Lets Shadow hear the other side of the call. It never records video.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                note: "After you allow it, macOS may ask you to reopen Shadow.", isStale: grantedBefore.contains(.screen)))
        }
        if mic != .granted {
            out.append(ChecklistItem(
                kind: .microphone, state: mic, title: "Microphone",
                explanation: "Lets Shadow hear you, so the transcript knows who said what.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                note: nil, isStale: grantedBefore.contains(.microphone)))
        }
        return out
    }

    public static func items(using checker: PermissionChecker, grantedBefore: Set<PermissionKind> = []) -> [ChecklistItem] {
        items(mic: checker.status(.microphone), screen: checker.status(.screen), grantedBefore: grantedBefore)
    }
}
