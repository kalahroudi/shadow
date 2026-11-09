// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// `Shadow --snapshot <dir>` renders the app's screens to PNG files for the docs, then exits.
/// It uses made-up sample data, never the user's real data. Add a Shot per screen/theme you want in the README.
enum SnapshotMode {
    nonisolated(unsafe) static var dir: String?

    @MainActor static func run() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            for shot in shots { await render(shot, to: dir) }
            NSApp.terminate(nil)
        }
    }

    struct Shot { let name: String; let dark: Bool; let size: CGSize; let make: @MainActor () -> AnyView }

    /// Made-up permission states, so snapshots never read the real system.
    struct SampleChecker: PermissionChecker {
        func status(_ kind: PermissionKind) -> PermissionState { kind == .microphone ? .granted : .notGranted }
        func request(_ kind: PermissionKind) async -> PermissionState { status(kind) }
    }

    /// Sample transcript, never real data.
    static let sampleLines: [Segment] = [
        Segment(speaker: .them, text: "Thanks for joining. Let's start with your background in distributed systems.", start: 1, end: 6, isFinal: true),
        Segment(speaker: .you, text: "Sure, I've spent the last six years on payments infrastructure.", start: 7, end: 11, isFinal: true),
        Segment(speaker: .them, text: "Great. Tell me about a time you had to scale a system under load", start: 12, end: 16, isFinal: true),
        Segment(speaker: .them, text: "and what you'd do differently", start: 17, end: 19, isFinal: false),
    ]

    @MainActor static func overlay(_ state: OverlayState, compact: Bool, dark: Bool) -> Shot {
        let size = OverlayLayout.size(compact: compact)
        let content = OverlayContent(state: state, compact: compact, lines: state == .idle ? [] : sampleLines,
                                     levels: state == .idle ? Levels() : Levels(them: 0.6, you: 0.25), opacity: 1, clickThrough: false,
                                     persona: Persona.default.label, sessionStart: state == .idle ? nil : Date(timeIntervalSinceNow: -192),
                                     startHotkey: HotkeyMap.defaults[.toggleSession]?.display ?? "",
                                     clickThroughHotkey: HotkeyMap.defaults[.toggleClickThrough]?.display ?? "")
        let name = "overlay-\(state.label.lowercased())-\(compact ? "compact" : "expanded")" + (dark ? "-dark" : "")
        return Shot(name: name, dark: dark, size: CGSize(width: size.width + 40, height: size.height + 40)) {
            AnyView(OverlayView(content: content, actions: OverlayActions())
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(width: size.width, height: size.height)
                .padding(20)
                .background(LinearGradient(colors: [Color(nsColor: AppIcon.violet).opacity(0.5), Color(nsColor: AppIcon.blue).opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
    }

    @MainActor static var shots: [Shot] {
        var all: [Shot] = []
        for dark in [false, true] {
            let sfx = dark ? "-dark" : ""
            all.append(overlay(.idle, compact: true, dark: dark))
            all.append(overlay(.listening, compact: true, dark: dark))
            all.append(overlay(.listening, compact: false, dark: dark))
            all.append(Shot(name: "popover" + sfx, dark: dark, size: CGSize(width: 360, height: 480)) { AnyView(PopoverView()) })
            for pane in SettingsPane.allCases {
                all.append(Shot(name: "settings-\(pane.rawValue)" + sfx, dark: dark, size: CGSize(width: 640, height: 480)) { AnyView(SettingsView(pane: pane)) })
            }
            for (i, step) in OnboardingModel.Step.allCases.enumerated() {
                all.append(Shot(name: "onboarding-\(i + 1)-\(step)" + sfx, dark: dark, size: CGSize(width: 560, height: 520)) {
                    AnyView(OnboardingView(checker: SampleChecker(), step: step) {})
                })
            }
        }
        // The compact view of the idle state doubles as the Expanded idle face.
        all.append(overlay(.idle, compact: false, dark: false))
        all.append(overlay(.idle, compact: false, dark: true))
        return all
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        let host = NSHostingView(rootView: shot.make().frame(width: shot.size.width, height: shot.size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))   // off screen, but still laid out and drawn
        win.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.name + ".png")) }
        win.orderOut(nil)
    }
}
