// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import AVFoundation
import ShadowKit

/// The Settings window (R19). Its view hierarchy is released on close (R3).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Shadow Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil   // release the SwiftUI hierarchy (and any hotkey recorder monitor) while hidden
        window?.delegate = nil
        window = nil
    }
}

struct SettingsView: View {
    @State var pane: SettingsPane = .speech

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPane.allCases) { p in
                        Button { pane = p } label: {
                            Label(p.title, systemImage: p.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .background(pane == p ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(10).frame(width: 170).background(Theme.sidebar)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pane.title).font(.system(size: 20, weight: .semibold))
                        switch pane {
                        case .speech: SpeechPane()
                        case .hotkeys: HotkeysPane()
                        case .privacy: PrivacyPane()
                        case .general: GeneralPane()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }.background(Theme.pane)
            }
            Divider()
            Text(SettingsPane.footer).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 640, height: 480)
    }
}

private struct Row<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            content
        }
        .contentShape(Rectangle())
    }
}

struct SpeechPane: View {
    @State private var prefs = Prefs.shared
    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 12) {
                Row(title: "Language", detail: "Auto follows your system's preferred languages.") {
                    Picker("Language", selection: $prefs.language) { ForEach(Language.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 150)
                }
                Divider()
                Row(title: "You (microphone)", detail: "The device used for your own voice.") {
                    Picker("Microphone", selection: $prefs.micDeviceID) {
                        Text("System default").tag("")
                        ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }.labelsHidden().frame(width: 220)
                }
                Divider()
                Row(title: "Them (system audio)", detail: ThemSource.systemAudio.detail) {
                    Text(ThemSource.systemAudio.title).foregroundStyle(.secondary)
                }
            }.card()
            Text("Speech runs on this Mac with Apple SpeechAnalyzer. No keys, no account.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .onAppear { devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices }
        .onDisappear { devices = [] }
    }
}

struct HotkeysPane: View {
    @State private var recording: HotkeyAction?
    @State private var errors: [HotkeyAction: String] = [:]
    @State private var map = Prefs.shared.hotkeys
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 10) {
                ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { i, action in
                    if i > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Row(title: action.label) {
                            HStack {
                                Button(recording == action ? "Press keys…" : (map[action]?.display ?? "Not set")) { toggleRecording(action) }
                                    .frame(minWidth: 110)
                                Button("Reset") { apply(action, HotkeyMap.defaults[action]?.string ?? "") }
                                    .disabled(map[action] == HotkeyMap.defaults[action])
                            }
                        }
                        if let e = errors[action] { Text(e).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                    }
                }
            }.card()
            Text("Click a shortcut, then press the new keys. Include ⌘, ⌃ or ⌥. Escape cancels. A new shortcut applies immediately.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording(_ action: HotkeyAction) {
        let wasRecording = recording == action
        stopRecording()
        guard !wasRecording else { return }
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }   // Escape
            var mods: Hotkey.Modifiers = []
            let f = event.modifierFlags
            if f.contains(.command) { mods.insert(.command) }
            if f.contains(.shift) { mods.insert(.shift) }
            if f.contains(.option) { mods.insert(.option) }
            if f.contains(.control) { mods.insert(.control) }
            let key = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
            stopRecording()
            apply(action, key.string)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func apply(_ action: HotkeyAction, _ string: String) {
        errors[action] = nil
        switch map.binding(action, to: string) {
        case .failure(let e): errors[action] = e.message
        case .success(let new):
            let failed = Prefs.shared.setHotkeys(new)
            if let e = failed[action] {
                // macOS refused it: restore the previous binding so the action is never left unbound.
                errors[action] = e.message
                Prefs.shared.setHotkeys(map)
            } else { map = new }
        }
    }
}

struct PrivacyPane: View {
    @State private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 12) {
                Row(title: "Visible mode", detail: PrivacyCopy.visibleMode) {
                    Image(systemName: "eye").foregroundStyle(Theme.ok)
                }
                Divider()
                Row(title: "Ask before each session", detail: "Show a reminder you confirm before capture begins.") {
                    Toggle("", isOn: $prefs.remindBeforeSession).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                Row(title: "Audio", detail: PrivacyCopy.noAudioOnDisk) {
                    Image(systemName: "waveform.slash").foregroundStyle(Theme.ok)
                }
            }.card()
            Text("**Consent & rules.** " + PrivacyCopy.consentNote).lineSpacing(3).card()
        }
    }
}

struct GeneralPane: View {
    @State private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Row(title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if let e = prefs.launchAtLoginError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                Divider()
                Row(title: "Show Dock icon", detail: "Off keeps Shadow in the menu bar only.") {
                    Toggle("", isOn: $prefs.showDockIcon).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                Row(title: "Appearance", detail: "Applies to Settings and the popover.") {
                    Picker("Appearance", selection: $prefs.theme) { ForEach(ThemeChoice.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 210)
                }
                Divider()
                Row(title: "Welcome tour") {
                    Button("Run setup again…") { OnboardingWindowController.shared.show() }
                }
            }.card()
        }
    }
}
