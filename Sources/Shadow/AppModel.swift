// SPDX-License-Identifier: Apache-2.0

import AppKit
import ShadowKit

/// App-level state the menu bar item, popover and hotkeys share. It lives for the whole run but holds only a few values;
/// views are created and destroyed around it. Nothing here runs unless a session is running.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let checker: PermissionChecker = SystemPermissionChecker()
    /// Start, Stop, live transcript, meters and elapsed time. The popover and, later, the overlay read it.
    let session: SessionCoordinator
    /// Click-through state; the overlay (a later task) reads it. Hotkey-toggled so it can never be stuck on (R15).
    var clickThrough = false { didSet { OverlayController.shared.refresh() } }
    /// Live transcript and start time for the overlay; empty when no session runs.
    var transcript: TranscriptSnapshot { session.transcript }
    var sessionStart: Date? { session.startedAt }
    var onOpenSettings: (@MainActor () -> Void)?

    var isRunning: Bool { session.isRunning }
    var levels: Levels { session.levels }
    var message: String? { session.message }
    var showChecklist: Bool { session.showChecklist }
    var onRunningChange: (@MainActor (Bool) -> Void)? { get { session.onRunningChange } set { session.onRunningChange = newValue } }
    var onNeedPopover: (@MainActor () -> Void)? { get { session.onNeedPopover } set { session.onNeedPopover = newValue } }

    private init() {
        let checker = self.checker
        session = SessionCoordinator(
            checker: checker,
            makeController: { AppModel.makeRealController() },
            remindBeforeSession: { Prefs.shared.remindBeforeSession },
            confirmReminder: { AppModel.confirmReminder() },
            locale: { Prefs.shared.language.resolve(supported: Language.allCases.compactMap(\.fixedLocale)) })
    }

    /// The real pipeline: system audio (Them), microphone (You) and on-device speech, writing to the sessions folder.
    private static func makeRealController() -> SessionController? {
        let paths = AppPaths()
        do { try paths.ensureDirectories() } catch {
            AppLog.error(error, context: "create sessions folder")
            return nil
        }
        let stt = AppleSTTProvider { progress in Task { @MainActor in AppModel.shared.session.modelDownload = progress } }
        return SessionController(them: SCKAudioSource(), you: MicAudioSource(deviceUID: { Prefs.micDeviceUIDForStart() }),
                                 stt: stt, store: SessionStore(directory: paths.sessionsDir))
    }

    func handle(_ action: HotkeyAction) {
        let prefs = Prefs.shared
        switch action {
        case .toggleSession: toggleSession()
        case .toggleOverlay: prefs.overlayVisible.toggle()
        case .toggleClickThrough: clickThrough.toggle()
        case .toggleCompact: prefs.overlayCompact.toggle()
        }
    }

    func toggleSession() { Task { await session.toggle() } }
    /// Stops a running session so its transcript is written; awaited when the app quits.
    func shutdown() async { await session.shutdown() }
    func recheckPermissions() { session.recheckPermissions() }
    func dismissMessage() { session.dismissMessage() }
    /// Tells the user when a shortcut could not be registered, so a dead hotkey is never silent.
    func reportHotkeyConflicts(_ failed: some Collection<HotkeyAction>) {
        guard let text = HotkeyAction.conflictMessage(for: failed) else { return }
        session.showNotice(text)
    }

    /// The reminder before each session (R20). Capture begins only after the user confirms.
    private static func confirmReminder() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start listening?"
        alert.informativeText = "Shadow will transcribe system audio and your microphone on this Mac and show a live transcript in a window that is visible to screen sharing. Make sure everyone on the call is fine with that."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
