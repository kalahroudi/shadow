// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// Plain AppKit startup. There is deliberately no SwiftUI `App`/`Settings` scene: that adds an empty
/// "Settings" window behind Cmd-, .
@main
enum ShadowMain {
    static let delegate = MainActor.assumeIsolated { AppDelegate() }

    static func main() {
        let args = CommandLine.arguments
        // Command line helpers used by the build scripts and CI. They must run before any app state exists.
        if args.contains("--self-test") { print(BuildInfo.current.selfTestLine); exit(0) }
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            do { try AppIcon.writeIconset(to: args[i + 1]); exit(0) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { SnapshotMode.dir = args[i + 1] }

        // Only one copy may run: two would fight over the menu bar item.
        // Leave before any app state exists, and activate the running copy.
        if SnapshotMode.dir == nil, let other = Self.otherRunningInstance() {
            if let url = other.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) } else { other.activate() }
            Thread.sleep(forTimeInterval: 0.3)
            exit(0)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.delegate = delegate
            app.mainMenu = makeMainMenu()
            app.run()
        }
    }

    /// App, Edit and Window menus, so copy/paste/Cmd-W work in text fields and windows.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = target
            return i
        }
        add("Shadow", [
            item("About Shadow", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Shadow", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Shadow", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    /// Another live copy of this app. Waits a moment, in case the other copy is just exiting.
    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }   // a bare `swift run` binary has no identity
        for attempt in 0..<10 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            guard let first = others.first else { return nil }
            if attempt == 9 { return first }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }
}
