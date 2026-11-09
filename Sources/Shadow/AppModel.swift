// SPDX-License-Identifier: Apache-2.0

import AppKit
import ShadowKit

/// App-level state the menu bar item, popover and hotkeys share. It lives for the whole run but holds only a few values;
/// views are created and destroyed around it. Nothing here runs unless a session is running.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var isRunning = false
    private(set) var levels = Levels()
    /// One short friendly sentence, or nil.
    private(set) var message: String?
    /// True while the "fix your permissions" checklist replaces the Start path (R7).
    private(set) var showChecklist = false
    /// Click-through state; the overlay (a later task) reads it. Hotkey-toggled so it can never be stuck on (R15).
    private(set) var clickThrough = false

    /// Builds the controller for one session. The real audio and speech adapters plug in here; until they are wired
    /// Start reports a friendly message and starts nothing.
    var makeController: @MainActor () -> SessionController? = { nil }
    let checker: PermissionChecker = SystemPermissionChecker()
    var onRunningChange: (@MainActor (Bool) -> Void)?
    var onNeedPopover: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?

    private var controller: SessionController?
    private var levelTask: Task<Void, Never>?
    private var busy = false

    func handle(_ action: HotkeyAction) {
        let prefs = Prefs.shared
        switch action {
        case .toggleSession: toggleSession()
        case .toggleOverlay: prefs.overlayVisible.toggle()
        case .toggleClickThrough: clickThrough.toggle()
        case .toggleCompact: prefs.overlayCompact.toggle()
        }
    }

    func toggleSession() {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; if isRunning { await stop() } else { await start() } }
    }

    func recheckPermissions() { showChecklist = !Checklist.items(using: checker).isEmpty }
    func dismissMessage() { message = nil }

    private func start() async {
        message = nil
        if !Checklist.items(using: checker).isEmpty {
            showChecklist = true; onNeedPopover?(); return   // nothing starts without both permissions
        }
        showChecklist = false
        if Prefs.shared.remindBeforeSession, !confirmReminder() { return }
        guard let controller = makeController() else {
            message = "Capture isn't available in this build yet."; onNeedPopover?(); return
        }
        do {
            let locale = Prefs.shared.language.resolve(supported: Language.allCases.compactMap(\.fixedLocale))
            try await controller.start(locale: locale)
        } catch {
            AppLog.error(error, context: "start session")
            message = UserError.message(for: error, action: "Start the session"); onNeedPopover?(); return
        }
        self.controller = controller
        isRunning = true
        onRunningChange?(true)
        let updates = await controller.levelUpdates()
        levelTask = Task { for await value in updates { levels = value } }
    }

    private func stop() async {
        guard let controller else { return }
        do { try await controller.stop() } catch {
            AppLog.error(error, context: "stop session")
            message = UserError.message(for: error, action: "Save the transcript")
        }
        levelTask?.cancel(); levelTask = nil
        self.controller = nil
        levels = Levels()
        isRunning = false
        onRunningChange?(false)
    }

    /// The reminder before each session (R20). Capture begins only after the user confirms.
    private func confirmReminder() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start listening?"
        alert.informativeText = "Shadow will transcribe system audio and your microphone on this Mac and show a live transcript in a window that is visible to screen sharing. Make sure everyone on the call is fine with that."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
