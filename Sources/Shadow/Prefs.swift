// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ServiceManagement
import AppKit

enum ThemeChoice: String, CaseIterable { case system, light, dark
    var label: String { rawValue.capitalized }
}

/// User preferences, stored in UserDefaults. Add a property here, a `register(defaults:)` entry, and a row in Settings:
/// a preference that has no row in Settings does not exist.
@MainActor @Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme"); applyTheme() } }
    var showDockIcon: Bool { didSet { d.set(showDockIcon, forKey: "showDockIcon"); applyDockIcon() } }

    /// Launch at login is on by default; the user can turn it off. Backed by SMAppService (Login Items).
    private(set) var launchAtLogin: Bool = false
    private(set) var launchAtLoginError: String?

    private init() {
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = d.bool(forKey: "showDockIcon")
        // First run: opt in to launch at login. After that the user's choice always wins.
        if !d.bool(forKey: "launchAtLoginDefaulted") {
            d.set(true, forKey: "launchAtLoginDefaulted")
            setLaunchAtLogin(true)
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change Login Items: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    /// Applies to every window AND the popover (which needs the explicit nudge in AppDelegate.applyAppearance).
    func applyTheme() {
        NSApp?.appearance = switch theme { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
        (NSApp?.delegate as? AppDelegate)?.applyAppearance()
    }

    /// Dock icon on = regular app (Dock, Cmd-Tab). Off = menu bar only.
    func applyDockIcon() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
