// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ServiceManagement
import AppKit
import ShadowKit

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
    /// Show a reminder before capture starts (R20). On by default.
    var remindBeforeSession: Bool { didSet { d.set(remindBeforeSession, forKey: PrefsDefaults.remindBeforeSession) } }
    /// First-run flag: onboarding shows until this is set.
    var onboardingCompleted: Bool { didSet { d.set(onboardingCompleted, forKey: PrefsDefaults.onboardingCompleted) } }

    /// Popover choices (R17). They take effect immediately. Persona is UI only in milestone 1.
    var persona: Persona { didSet { d.set(persona.rawValue, forKey: "persona") } }
    var language: Language { didSet { d.set(language.rawValue, forKey: "language") } }
    var overlayVisible: Bool { didSet { d.set(overlayVisible, forKey: "overlayVisible"); OverlayController.shared.refresh() } }
    var overlayCompact: Bool { didSet { d.set(overlayCompact, forKey: "overlayCompact"); OverlayController.shared.refresh() } }
    /// Overlay opacity; the slider applies it to the panel immediately (R13).
    var overlayOpacity: Double { didSet { d.set(overlayOpacity, forKey: "overlayOpacity"); OverlayController.shared.refresh() } }

    /// Global shortcuts, one string per action; invalid or conflicting values fall back to the defaults (R18).
    var hotkeys: HotkeyMap { HotkeyMap.stored { self.d.string(forKey: "hotkey.\($0.rawValue)") } }
    /// Rebinds without a relaunch. If macOS refuses any shortcut nothing is saved, the previous shortcuts stay live
    /// and the refused actions are returned.
    @discardableResult
    func setHotkeys(_ map: HotkeyMap) -> [HotkeyAction: UserFacingError] {
        let previous = hotkeys
        let failed = HotkeyCenter.shared.register(map)
        guard failed.isEmpty else { HotkeyCenter.shared.register(previous); return failed }
        for (action, key) in map { d.set(key.string, forKey: "hotkey.\(action.rawValue)") }
        return [:]
    }

    /// The microphone for the You stream: the Core Audio device UID stored under "micDeviceID" (the key #8's Settings picker writes),
    /// or nil for the system default (an empty or missing value). Read when a session starts.
    nonisolated static func micDeviceUIDForStart() -> String? {
        let uid = UserDefaults.standard.string(forKey: "micDeviceID")
        return uid?.isEmpty == false ? uid : nil
    }

    private(set) var launchAtLogin: Bool = false
    private(set) var launchAtLoginError: String?

    private init() {
        PrefsDefaults.register(in: d)
        remindBeforeSession = d.bool(forKey: PrefsDefaults.remindBeforeSession)
        onboardingCompleted = d.bool(forKey: PrefsDefaults.onboardingCompleted)
        persona = Persona(rawValue: d.string(forKey: "persona") ?? "") ?? .default
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .auto
        overlayVisible = d.object(forKey: "overlayVisible") as? Bool ?? true
        overlayCompact = d.object(forKey: "overlayCompact") as? Bool ?? true
        overlayOpacity = min(OverlayLayout.opacityRange.upperBound, max(OverlayLayout.opacityRange.lowerBound,
                             d.object(forKey: "overlayOpacity") as? Double ?? OverlayLayout.defaultOpacity))
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
            AppLog.error(error, context: "launch at login")
            launchAtLoginError = "Could not change Login Items. This is expected for an unsigned build."
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
