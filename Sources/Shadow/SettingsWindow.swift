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

    func show(pane: SettingsPane? = nil) {
        if let window {
            if let pane { window.contentView = NSHostingView(rootView: SettingsView(pane: pane)) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Shadow Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView(pane: pane ?? .speech))
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
                        case .languageModel: LanguageModelPane()
                        case .personas: PersonasPane()
                        case .hotkeys: HotkeysPane()
                        case .privacy: PrivacyPane()
                        case .general: GeneralPane()
                        case .updates: UpdatesPane()
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

struct Row<Content: View>: View {
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
                        // A stored mic that is unplugged stays selectable-looking; capture falls back to the default input.
                        if !prefs.micDeviceID.isEmpty, !devices.contains(where: { $0.uniqueID == prefs.micDeviceID }) {
                            Text("Unavailable (using system default)").tag(prefs.micDeviceID)
                        }
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

struct LanguageModelPane: View {
    @State private var model = LanguageModelSettingsModel(makeProvider: { AppModel.makeProvider($0) })
    @State private var baseURL = LLMSettings().localBaseURL
    @State private var keys: [CloudKind: String] = [:]
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 12) {
                ForEach(Array(ProviderCatalog.all.enumerated()), id: \.element.id) { i, info in
                    if i > 0 { Divider() }
                    providerRow(info)
                }
            }.card()
            if let m = model.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            if model.localOnly { Text(LocalOnlyPolicy.message).font(.system(size: 12)).foregroundStyle(Theme.warn) }
            VStack(alignment: .leading, spacing: 8) {
                Row(title: "Local server address", detail: "Must be on this Mac (localhost or 127.0.0.1).") {
                    TextField("", text: $baseURL).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { model.setLocalBaseURL(baseURL); Task { await refresh() } }
                }
                Row(title: "Local server model", detail: model.localModels.isEmpty ? "Start the server to list its models." : nil) {
                    Picker("Model", selection: Binding(get: { model.localModel }, set: { model.setLocalModel($0) })) {
                        Text("Choose…").tag("")
                        ForEach(model.localModels, id: \.self) { Text($0).tag($0) }
                        if !model.localModel.isEmpty, !model.localModels.contains(model.localModel) { Text(model.localModel).tag(model.localModel) }
                    }.labelsHidden().frame(width: 240).disabled(model.localModels.isEmpty)
                }
            }.card()
            Text(ProviderCatalog.cloudVersusLocal).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async { checking = true; await model.refresh(); checking = false }

    @ViewBuilder private func providerRow(_ info: ProviderInfo) -> some View {
        let status = model.statuses[info.id]
        let kind = CloudKind(rawValue: info.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { model.select(info.id) } label: {
                    Image(systemName: model.selectedID == info.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(model.selectedID == info.id ? Color.accentColor : .secondary)
                }.buttonStyle(.plain).disabled(!model.isSelectable(info.id)).accessibilityLabel("Use \(info.title)")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.title)
                        if info.isCloud { Text("cloud").font(.system(size: 10)).padding(.horizontal, 5).background(Theme.fill, in: Capsule()) }
                    }
                    Text(info.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let why = status?.explanation, status != .needsKey { Text(why).font(.system(size: 12)).foregroundStyle(Theme.warn) }
                }
                Spacer(minLength: 8)
                Text(status?.label ?? "Checking…").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status?.isReady == true ? Theme.ok : .secondary)
            }
            if let kind {
                HStack {
                    Picker("Model", selection: Binding(get: { model.model(for: kind) }, set: { model.setModel($0, for: kind) })) {
                        ForEach(kind.models, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    SecureField(model.hasKey[kind] == true ? "Key saved in Keychain" : "API key", text: Binding(get: { keys[kind] ?? "" }, set: { keys[kind] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { model.saveKey(keys[kind] ?? "", for: kind); keys[kind] = ""; Task { await refresh() } }
                        .disabled((keys[kind] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test") { Task { await model.testKey(keys[kind] ?? "", for: kind) } }
                        .disabled(model.keyTests[kind] == .testing || (model.hasKey[kind] != true && (keys[kind] ?? "").isEmpty))
                }.padding(.leading, 26)
                switch model.keyTests[kind] ?? .idle {
                case .passed: Text("Key works.").font(.system(size: 12)).foregroundStyle(Theme.ok).padding(.leading, 26)
                case .failed(let why): Text(why).font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.leading, 26)
                case .testing: Text("Testing…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 26)
                case .idle: EmptyView()
                }
            }
        }
    }
}

struct PersonasPane: View {
    @State private var store = Prefs.shared.personas
    @State private var editing = Prefs.shared.personas.activeID

    private var current: Persona? { store.persona(editing) ?? store.personas.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Persona", selection: $editing) {
                    ForEach(store.personas) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 200)
                Button("New") { editing = store.create(name: "New persona", systemPrompt: "You help in a live conversation. Answer the latest question clearly and briefly.").id }
                if let p = current {
                    Button("Duplicate") { if let c = store.duplicate(p.id) { editing = c.id } }
                    Button("Delete", role: .destructive) { if store.delete(p.id) { editing = store.activeID } }.disabled(p.isBuiltIn)
                }
                Spacer()
            }
            if let p = current {
                VStack(alignment: .leading, spacing: 10) {
                    if !p.isBuiltIn {
                        Row(title: "Name") {
                            TextField("", text: Binding(get: { p.name }, set: { store.update(p.id, name: $0) })).textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        Divider()
                    }
                    Row(title: "Answer length", detail: "Changes the instruction the model gets.") {
                        Picker("Length", selection: Binding(get: { p.length }, set: { store.update(p.id, length: $0) })) {
                            ForEach(AnswerLength.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
                    }
                    Divider()
                    Text("System prompt").font(.system(size: 13, weight: .medium))
                    TextEditor(text: Binding(get: { p.systemPrompt }, set: { store.update(p.id, systemPrompt: $0) }))
                        .font(.system(size: 12)).frame(height: 150).scrollContentBackground(.hidden)
                        .padding(4).background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
                    if !p.suggestsAnswers { Text("This persona doesn't suggest answers.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    HStack {
                        Button("Use this persona") { store.select(p.id) }.disabled(store.activeID == p.id)
                        if p.isBuiltIn { Button("Reset to default") { store.reset(p.id) } }
                        Spacer()
                        if store.activeID == p.id { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 12)) }
                    }
                }.card()
            }
        }
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
                Row(title: "Local-only mode", detail: "Shadow never contacts GitHub, so update checks and downloads are paused.") {
                    Toggle("", isOn: $prefs.localOnly).labelsHidden().toggleStyle(.switch)
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
                Row(title: "Auto-suggest on questions", detail: "Answer automatically when the other person finishes asking a question. Off by default; Answer now always works.") {
                    Toggle("", isOn: $prefs.autoSuggest).labelsHidden().toggleStyle(.switch)
                }
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
