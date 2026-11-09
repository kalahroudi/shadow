// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// Owns the menu bar item and its popover. The popover's views are created on demand and destroyed on close,
/// so a closed UI holds no view memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotMode.dir != nil { SnapshotMode.run(); return }
        Prefs.shared.applyTheme()
        Prefs.shared.applyDockIcon()
        NSApp.applicationIconImage = AppIcon.image(size: 512, padded: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(.from(sessionRunning: false))
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Shadow")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let model = AppModel.shared
        model.onRunningChange = { [weak self] running in self?.statusItem.button?.image = StatusIcon.image(.from(sessionRunning: running)) }
        model.onOpenSettings = { [weak self] in self?.popover.performClose(nil); SettingsWindowController.shared.show() }
        model.onOpenUpdates = { [weak self] in self?.openUpdates(check: false) }
        model.onNeedPopover = { [weak self] in self?.showPopover() }
        HotkeyCenter.shared.onAction = { model.handle($0) }
        model.reportHotkeyConflicts(HotkeyCenter.shared.register(Prefs.shared.hotkeys).keys)
        model.reportAnswerNowMove()

        OverlayController.shared.refresh()
        if !Prefs.shared.onboardingCompleted { OnboardingWindowController.shared.show() }
        Task { await model.permissions.registerOnLaunch(onboardingCompleted: Prefs.shared.onboardingCompleted) }   // once per launch (R5)
        finishUpdateHandoff(model)
    }

    /// Clears leftovers of a self-update, shows the outcome once, and tells the swap script this build started (R12, R13).
    private func finishUpdateHandoff(_ model: AppModel) {
        let paths = AppPaths()
        if let notice = UpdateHandoff.cleanup(paths: paths, currentVersion: BuildInfo.current.version) {
            Updater.shared.handoffText = notice.text
            model.session.showNotice(notice.text)
        }
        if PermissionLossCheck.checkOnce(checker: model.checker, paths: paths) {   // once per update (R25)
            model.openChecklist()   // recheckPermissions only closes the checklist, so open it explicitly
            model.session.showNotice(PermissionLossCheck.message)
            model.session.onNeedPopover?()
        }
        Task { await Updater.shared.launchCheckIfDue() }   // once, only when due; no timer (R1, R3)
        Task { await UpdateHandoff.confirmLaunch(paths: paths, isAlive: { true }) }   // one-shot; a quit ends the task before it writes
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            let settings = m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            let updates = m.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            m.addItem(withTitle: "Quit Shadow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { togglePopover() }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func checkForUpdates() { openUpdates(check: true) }

    private func openUpdates(check: Bool) {
        popover.performClose(nil)
        SettingsWindowController.shared.show(pane: .updates)
        if check { Task { await Updater.shared.checkNow() } }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        applyAppearance()
        let host = NSHostingController(rootView: PopoverView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // release the popover's views while hidden
    }

    /// Quitting during a session stops it first, so the transcript is written rather than left for crash recovery.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isRunning else { return .terminateNow }
        Task { await AppModel.shared.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { HotkeyCenter.shared.unregisterAll() }

    // The app lives in the menu bar: closing the last window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
