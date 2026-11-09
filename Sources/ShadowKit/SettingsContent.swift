// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Settings panes (R19). Every case has real content; there is no Updates pane in this milestone.
public enum SettingsPane: String, CaseIterable, Sendable, Identifiable {
    case speech, hotkeys, privacy, general

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speech: "Speech"
        case .hotkeys: "Hotkeys"
        case .privacy: "Privacy"
        case .general: "General"
        }
    }
    public var symbol: String {
        switch self {
        case .speech: "waveform"
        case .hotkeys: "command"
        case .privacy: "lock.shield"
        case .general: "gearshape"
        }
    }

    public static let footer = "Settings save automatically."
}

/// Fixed wording about consent and storage, shared by onboarding and Privacy settings (R20).
public enum PrivacyCopy {
    public static let consentNote = "Recording or transcribing other people may require their consent, and some employers or interview platforms ban assistive tools. Shadow is visible by default (menu bar indicator and on-screen overlay). You decide when it is appropriate."
    public static let visibleMode = "Visible mode is always on. The overlay is part of normal screen sharing and cannot be hidden from it."
    public static let noAudioOnDisk = "Audio is never written to disk. Only the text transcript is saved, on this Mac."
}

/// What the Them stream captures. Milestone 1 offers whole-system audio only.
public enum ThemSource: Sendable {
    case systemAudio
    public var title: String { "System audio (all apps)" }
    public var detail: String { "Captured with ScreenCaptureKit, excluding Shadow's own sounds." }
}
