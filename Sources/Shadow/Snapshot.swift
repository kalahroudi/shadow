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

    @MainActor static var shots: [Shot] {
        [Shot(name: "popover", dark: false, size: CGSize(width: 360, height: 480)) { AnyView(PopoverView()) },
         Shot(name: "popover-dark", dark: true, size: CGSize(width: 360, height: 480)) { AnyView(PopoverView()) }]
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
