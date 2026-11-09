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
        statusItem.button?.image = StatusIcon.image(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Shadow")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if !Prefs.shared.onboardingCompleted { OnboardingWindowController.shared.show() }
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Quit Shadow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { togglePopover() }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
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

    // The app lives in the menu bar: closing the last window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
