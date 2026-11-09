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
    /// The one in-flight answer, Answer now and auto-suggest (R7, R8, R10). Idle unless a session runs.
    let answers: AnswerCoordinator
    /// Click-through state; the overlay (a later task) reads it. Hotkey-toggled so it can never be stuck on (R15).
    var clickThrough = false { didSet { OverlayController.shared.refresh() } }
    /// Live transcript and start time for the overlay; empty when no session runs.
    var transcript: TranscriptSnapshot { session.transcript }
    var sessionStart: Date? { session.startedAt }
    var onOpenSettings: (@MainActor () -> Void)?
    var onOpenUpdates: (@MainActor () -> Void)?

    var isRunning: Bool { session.isRunning }
    var levels: Levels { session.levels }
    var notices: [Notice] { session.notices }
    var showChecklist: Bool { session.showChecklist }
    @ObservationIgnored var onRunningChange: (@MainActor (Bool) -> Void)?
    var onNeedPopover: (@MainActor () -> Void)? { get { session.onNeedPopover } set { session.onNeedPopover = newValue } }

    private init() {
        let checker = self.checker
        session = SessionCoordinator(
            checker: checker,
            makeController: { AppModel.makeRealController() },
            remindBeforeSession: { Prefs.shared.remindBeforeSession },
            confirmReminder: { AppModel.confirmReminder() },
            locale: { Prefs.shared.language.resolve(supported: Language.allCases.compactMap(\.fixedLocale)) })
        answers = AnswerCoordinator(
            settings: LLMSettings(), makeProvider: { AppModel.makeProvider($0) },
            persona: { Prefs.shared.personas.active }, language: { Prefs.shared.language },
            turns: { AppModel.shared.session.transcript.finals }, isSessionRunning: { AppModel.shared.session.isRunning },
            autoSuggest: { Prefs.shared.autoSuggest })
        let answers = self.answers
        session.onTranscript = { answers.transcriptChanged($0) }
        let session = self.session
        answers.onRecord = { session.recordAnswer($0) }
        answers.onCopyableChange = { HotkeyCenter.shared.setCopyAnswerEnabled($0) }
        session.onRunningChange = { [weak self] running in
            if running { answers.sessionStarted() } else { answers.sessionStopped() }   // stopping cancels any in-flight answer (R10)
            self?.onRunningChange?(running)
        }
    }

    private static func makeProvider(_ id: String) -> (any LLMProvider)? {
        switch id {
        case OnDeviceProvider.providerID: return OnDeviceProvider(model: FoundationModelsModel())
        case OpenAICompatProvider.providerID: return OpenAICompatProvider(baseURL: LLMSettings().localBaseURL)
        case ClaudeCLIProvider.providerID: return ClaudeCLIProvider()
        default: return CloudKind(rawValue: id).map { CloudProvider(kind: $0, secrets: KeychainStore(), localOnly: { LLMSettings().localOnly }) }
        }
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
        case .answerNow: answers.answerNow()
        case .copyAnswer: copyAnswer()
        }
    }

    /// Puts the full answer text on the pasteboard (R18).
    func copyAnswer() {
        answers.copy { text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    func toggleSession() { Task { await session.toggle() } }
    /// Stops a running session so its transcript is written; awaited when the app quits.
    func shutdown() async { await session.shutdown() }
    func recheckPermissions() { session.recheckPermissions() }
    func dismissNotice(_ id: Notice.ID) { session.dismissNotice(id) }
    /// Tells the user when a shortcut could not be registered, so a dead hotkey is never silent.
    func reportHotkeyConflicts(_ failed: some Collection<HotkeyAction>) {
        guard let text = HotkeyAction.conflictMessage(for: failed) else { return }
        session.showNotice(text)
    }

    /// Tells the user once per new shortcut when Answer now moved off its default because a saved shortcut owns it.
    func reportAnswerNowMove() {
        let d = UserDefaults.standard, key = "answerNowMoveNoticed"
        guard let move = HotkeyMap.storedResolvingAnswerNow({ d.string(forKey: "hotkey.\($0.rawValue)") }).move,
              d.string(forKey: key) != move.moved.string else { return }
        d.set(move.moved.string, forKey: key)
        session.showNotice(move.message)
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
