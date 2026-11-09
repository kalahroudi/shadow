// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Runs Start -> live transcript -> Stop for the menu bar app (R7, R20, R21) and holds what the popover and overlay show.
/// Everything it touches is injected, so tests drive it with fakes. It holds no timers or tasks while idle.
@MainActor @Observable
public final class SessionCoordinator {
    public enum Phase: Sendable, Equatable { case idle, starting, running, stopping }

    public private(set) var phase = Phase.idle
    public var isRunning: Bool { phase == .running }
    public private(set) var levels = Levels()
    /// Live finals and partials. After Stop it keeps the last snapshot until the next Start.
    public private(set) var transcript = TranscriptSnapshot()
    /// Friendly notices, one per line in the popover; identical ones are collapsed and each can be dismissed on its own.
    public private(set) var notices: [Notice] = []
    /// The notices joined one per line, or nil when there are none.
    public var message: String? { noticeCenter.joined }
    private var noticeCenter = NoticeCenter() { didSet { notices = noticeCenter.notices } }
    /// True while the "fix your permissions" checklist replaces the Start path (R7).
    public private(set) var showChecklist = false
    public private(set) var startedAt: Date?
    /// 0...1 while the speech model downloads before capture, nil otherwise.
    public var modelDownload: Double?

    public var onRunningChange: (@MainActor (Bool) -> Void)?
    public var onNeedPopover: (@MainActor () -> Void)?
    /// Called for every transcript change while a session runs (auto-suggest listens here).
    public var onTranscript: (@MainActor (TranscriptSnapshot) -> Void)?

    private let permissions: PermissionCenter
    private let makeController: @MainActor () -> SessionController?
    private let remindBeforeSession: @MainActor () -> Bool
    private let confirmReminder: @MainActor () -> Bool
    private let locale: @MainActor () -> Locale
    private let now: @Sendable () -> Date

    private var controller: SessionController?
    private var watchers: [Task<Void, Never>] = []

    public init(permissions: PermissionCenter,
                makeController: @escaping @MainActor () -> SessionController?,
                remindBeforeSession: @escaping @MainActor () -> Bool,
                confirmReminder: @escaping @MainActor () -> Bool,
                locale: @escaping @MainActor () -> Locale,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.permissions = permissions; self.makeController = makeController
        self.remindBeforeSession = remindBeforeSession; self.confirmReminder = confirmReminder
        self.locale = locale; self.now = now
    }

    /// Saves an answer into the running session's file (R20). Ignored when no session runs.
    public func recordAnswer(_ answer: AnswerRecord) {
        guard let controller, isRunning else { return }
        Task { await controller.addAnswer(answer) }
    }

    public func elapsed(at date: Date) -> TimeInterval { startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0 }

    /// Re-reads the permissions. The checklist closes once nothing is missing; it opens only from Start or the "Permissions needed" row.
    public func recheckPermissions() { if permissions.items().isEmpty { showChecklist = false } }
    public func openChecklist() { showChecklist = true }
    public func dismissNotice(_ id: Notice.ID) { noticeCenter.dismiss(id: id) }
    public func clearNotices() { noticeCenter.clear() }

    /// Start when idle, Stop when running; ignored while a start or stop is already in progress (so a hotkey can't double-fire).
    public func toggle() async {
        switch phase {
        case .idle: await start()
        case .running: await stop()
        case .starting, .stopping: break
        }
    }

    /// Stops a running session so its transcript is written; used when the app quits.
    public func shutdown() async { if phase == .running { await stop() } }

    private func start() async {
        phase = .starting   // held through the reminder, so a hotkey during the modal can't start a second session
        clearNotices()
        guard permissions.items().isEmpty else {
            await permissions.registerMissing()   // never a silent failure: each missing permission gets a real request first
            showChecklist = true; phase = .idle; onNeedPopover?(); return   // nothing starts without both permissions
        }
        showChecklist = false
        if remindBeforeSession(), !confirmReminder() { phase = .idle; return }
        guard let controller = makeController() else {
            noticeCenter.add(NoticeText.sentence("Capture isn't available in this build yet")); phase = .idle; onNeedPopover?(); return
        }
        // Subscribe before start: notices are not replayed, and the first levels and words must not be missed.
        let notices = await controller.notices()
        let levelUpdates = await controller.levelUpdates()
        let transcriptUpdates = await controller.transcript.updates()
        watchers = [
            Task { [weak self] in for await n in notices { if !Task.isCancelled { self?.showNotice(n) } } },
            Task { [weak self] in for await v in levelUpdates { if !Task.isCancelled { self?.levels = v } } },
            Task { [weak self] in for await t in transcriptUpdates { if !Task.isCancelled { self?.transcript = t; self?.onTranscript?(t) } } },
        ]
        do {
            try await controller.start(locale: locale())
        } catch {
            AppLog.error(error, context: "start session")
            cancelWatchers()
            modelDownload = nil
            noticeCenter.add(NoticeText.sentence(UserError.message(for: error, action: "Start the session")))
            phase = .idle; onNeedPopover?(); return
        }
        self.controller = controller
        modelDownload = nil
        startedAt = now()
        phase = .running
        onRunningChange?(true)
    }

    private func stop() async {
        guard let controller else { phase = .idle; return }
        phase = .stopping
        do { try await controller.stop() } catch {
            AppLog.error(error, context: "stop session")
            noticeCenter.add(NoticeText.sentence(UserError.message(for: error, action: "Save the transcript")))
        }
        transcript = await controller.transcript.snapshot   // the flushed final state, whatever the watcher last saw
        cancelWatchers()
        self.controller = nil
        levels = Levels()
        startedAt = nil
        phase = .idle
        onRunningChange?(false)
    }

    private func cancelWatchers() { watchers.forEach { $0.cancel() }; watchers = [] }

    /// Adds a friendly line (duplicates are collapsed) and asks for the popover so the user sees it.
    public func showNotice(_ text: String) {
        guard noticeCenter.add(NoticeText.sentence(text)) else { return }
        onNeedPopover?()
    }
}

public enum ElapsedFormat {
    /// "0:07", "12:34" or "1:02:03".
    public static func string(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        let (h, m, sec) = (s / 3600, s % 3600 / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
