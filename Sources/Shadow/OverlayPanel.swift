// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// A floating panel that never takes focus from the frontmost app and follows the user across Spaces (R13).
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay panel. The panel and its view hierarchy exist only while the overlay is shown (R3).
/// `refresh()` brings the panel in line with Prefs and click-through; no timers or observers run otherwise.
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    static let shared = OverlayController()
    private var panel: OverlayPanel?
    private var store = FrameStore()
    private var applyingFrame = false

    func refresh() {
        guard NSApp != nil else { return }
        let prefs = Prefs.shared
        guard prefs.overlayVisible else { close(); return }
        let compact = prefs.overlayCompact
        if panel == nil { open(compact: compact) }
        guard let panel else { return }
        panel.alphaValue = CGFloat(prefs.overlayOpacity)
        panel.ignoresMouseEvents = AppModel.shared.clickThrough
        panel.minSize = OverlayLayout.minSize(compact: compact)
        if lastCompact != compact {
            lastCompact = compact
            setFrame(OverlayLayout.resized(panel.frame, compact: compact))
        }
    }

    private var lastCompact: Bool?

    private func open(compact: Bool) {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // the header and any non-control area drag the panel
        panel.delegate = self

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        let host = NSHostingView(rootView: LiveOverlayView())
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        panel.contentView = glass

        let screen = NSScreen.main ?? NSScreen.screens[0]
        setFrame(store.restored(for: Self.displayKey(screen), compact: compact, visible: screen.visibleFrame), on: panel)
        lastCompact = compact
        self.panel = panel
        panel.orderFrontRegardless()   // visible without activating Shadow
    }

    private func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil   // release the SwiftUI hierarchy while hidden
        self.panel = nil
        lastCompact = nil
        // Hiding the overlay always clears click-through, so a shortcut another app owns can't leave it stuck on.
        AppModel.shared.clickThrough = false
    }

    private func setFrame(_ frame: CGRect, on target: OverlayPanel? = nil) {
        guard let p = target ?? panel else { return }
        applyingFrame = true
        p.setFrame(frame, display: true)
        applyingFrame = false
        save(p)
    }

    private func save(_ p: NSWindow) {
        guard let screen = p.screen else { return }
        store.save(p.frame, for: Self.displayKey(screen))
    }

    func windowDidMove(_ notification: Notification) { if !applyingFrame, let p = panel { save(p) } }
    func windowDidResize(_ notification: Notification) { if !applyingFrame, let p = panel { save(p) } }

    /// A stable identifier for a physical display, so each one remembers its own frame.
    static func displayKey(_ screen: NSScreen) -> String {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "main" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
