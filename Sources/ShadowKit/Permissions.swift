// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The two permissions a session needs (R7).
public enum PermissionKind: String, CaseIterable, Sendable {
    case screen       // Screen & System Audio Recording: the Them stream
    case microphone   // the You stream
}

public enum PermissionState: Equatable, Sendable { case granted, notGranted, notYetAsked }

/// Reads and requests permissions. The real one lives in the app target; tests use a fake.
public protocol PermissionChecker: Sendable {
    func status(_ kind: PermissionKind) -> PermissionState
    /// Shows the system prompt where macOS allows it, then returns the new state.
    func request(_ kind: PermissionKind) async -> PermissionState
}

/// One row of the "fix your permissions" checklist.
public struct ChecklistItem: Equatable, Identifiable, Sendable {
    public var id: PermissionKind { kind }
    public let kind: PermissionKind
    public let state: PermissionState
    public let title: String
    public let explanation: String
    /// A System Settings deep link, shown as copyable text and as an Open button.
    public let settingsURL: String
    /// Extra advice, e.g. the relaunch note for screen recording.
    public let note: String?
    /// True while macOS can still show its own prompt, so a Request button makes sense.
    public var canRequest: Bool { state == .notYetAsked }
}

public enum Checklist {
    /// Items for every permission that is not granted, screen first. Empty means Start may proceed.
    public static func items(mic: PermissionState, screen: PermissionState) -> [ChecklistItem] {
        var out: [ChecklistItem] = []
        if screen != .granted {
            out.append(ChecklistItem(
                kind: .screen, state: screen, title: "Screen & System Audio Recording",
                explanation: "Lets Shadow hear the other side of the call. It never records video.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                note: "After you allow it, macOS may ask you to reopen Shadow."))
        }
        if mic != .granted {
            out.append(ChecklistItem(
                kind: .microphone, state: mic, title: "Microphone",
                explanation: "Lets Shadow hear you, so the transcript knows who said what.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                note: nil))
        }
        return out
    }

    public static func items(using checker: PermissionChecker) -> [ChecklistItem] {
        items(mic: checker.status(.microphone), screen: checker.status(.screen))
    }
}
