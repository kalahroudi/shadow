// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// The four-step first-run window (R8). Its view hierarchy is released on close (R3).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Shadow"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: OnboardingView(checker: SystemPermissionChecker()) { [weak self] in self?.window?.close() })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil   // release the SwiftUI hierarchy while hidden
        window?.delegate = nil
        window = nil
    }
}

struct OnboardingView: View {
    let center: PermissionCenter
    let onFinish: () -> Void
    @State private var model: OnboardingModel
    @State private var prefs = Prefs.shared
    @State private var keyText = ""
    @State private var keyNote: String?
    @State private var checking = false

    init(checker: PermissionChecker, step: OnboardingModel.Step = .welcome, onFinish: @escaping () -> Void) {
        center = PermissionCenter(checker: checker, registrar: SystemPermissionRegistrar())
        self.onFinish = onFinish
        _model = State(initialValue: OnboardingModel(startingAt: step))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .permissions: permissions
                case .provider: provider
                case .consent: consent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.top, 28)

            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                    Circle().fill(s == model.step ? Color.accentColor : Theme.fill).frame(width: 7, height: 7)
                }
            }.padding(.bottom, 12)

            HStack {
                Button("Back") { model.back() }.opacity(model.canGoBack ? 1 : 0).disabled(!model.canGoBack)
                Spacer()
                Button(model.isLastStep ? "Start using Shadow" : "Continue") {
                    if model.advance() { prefs.onboardingCompleted = true; onFinish() }
                }
                .buttonStyle(.borderedProminent).disabled(!model.canAdvance)
                .keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.bottom, 20)
        }
        .frame(width: 560, height: 520)
        .background(Theme.pane)
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 22, weight: .semibold))
            Text(sub).foregroundStyle(.secondary)
        }.padding(.bottom, 14)
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: AppIcon.image(size: 112)).resizable().frame(width: 112, height: 112)
            Text("Welcome to Shadow").font(.system(size: 28, weight: .semibold))
            Text("A free, open-source live assistant for meetings and interviews. Runs on your Mac. No account, no backend.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            VStack(alignment: .leading, spacing: 8) {
                Label("Live transcript of Them and You", systemImage: "checkmark")
                Label("Everything stays on your Mac", systemImage: "checkmark")
            }.foregroundStyle(.secondary).padding(.top, 10)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var permissions: some View {
        VStack(alignment: .leading) {
            title("Two permissions", "macOS will ask. Shadow only listens while a session is running.")
            PermissionChecklistView(center: center)
        }
    }

    private var provider: some View {
        VStack(alignment: .leading) {
            title("Choose your brain", "You can change this any time in Settings.")
            VStack(spacing: 8) {
                ForEach(ProviderOption.allCases, id: \.self) { o in
                    let reason = model.unavailableReason(o)
                    Button { choose(o) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.provider == o ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.provider == o ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(o.title).font(.system(size: 13, weight: .semibold))
                                    if o.isRecommended { Text("Recommended").font(.system(size: 11)).foregroundStyle(Theme.ok) }
                                    if let s = model.statuses[o] { Text(s.label).font(.system(size: 11)).foregroundStyle(s.isReady ? Theme.ok : .secondary) }
                                }
                                Text(reason ?? o.detail).font(.system(size: 12)).foregroundStyle(reason == nil ? Color.secondary : Theme.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle()).card()
                    }
                    .buttonStyle(.plain).disabled(reason != nil).opacity(reason == nil ? 1 : 0.6)
                }
            }
            if model.provider == .ownKey { ownKeyEntry }
            HStack {
                Button(checking ? "Checking…" : "Check again") { Task { await checkAll() } }.disabled(checking)
                if model.providerIsReady { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                else if !checking { Text("Continue unlocks once the choice is checked and ready.").foregroundStyle(.secondary) }
            }.font(.system(size: 12)).padding(.top, 6)
        }
        .task { await checkAll() }
    }

    private var ownKeyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Provider", selection: Binding(get: { model.ownKeyKind }, set: { model.ownKeyKind = $0; keyNote = nil; configure(); Task { await checkAll() } })) {
                    ForEach(CloudKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().fixedSize()
                SecureField("API key", text: $keyText).textFieldStyle(.roundedBorder)
                Button("Test & save") { Task { await saveKey() } }.disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyNote { Text(keyNote).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(.top, 6)
    }

    private func choose(_ o: ProviderOption) {
        model.select(o)
        configure()
    }

    /// Choosing a provider configures it right away (R23).
    private func configure() {
        if case .failure(let e) = model.configure(LLMSettings()) { keyNote = e.message }
    }

    private func checkAll() async {
        checking = true
        for o in ProviderOption.allCases {
            let status = await AppModel.makeProvider(o.providerID(ownKeyKind: model.ownKeyKind))?.availability() ?? .unavailable("Not available in this build.")
            model.record(status, for: o)
            // A ready local server must also have a model chosen, or the first answer would fail.
            if o == .localServer, status.isReady, let list = try? await OpenAICompatProvider(baseURL: LLMSettings().localBaseURL).models() {
                LLMSettings().adoptLocalModel(from: list)
            }
        }
        checking = false
    }

    /// A real minimal request first; the key is stored (Keychain only) only if it works.
    private func saveKey() async {
        let kind = model.ownKeyKind
        let secrets = KeychainStore()
        do {
            try await CloudProvider(kind: kind, secrets: secrets, localOnly: { LLMSettings().localOnly }).testKey(keyText)
            try secrets.saveKey(keyText, for: kind)
            keyText = ""
            keyNote = "Key works and is saved in your Keychain."
            configure()
            await checkAll()
        } catch let e as LLMError { keyNote = e.message
        } catch { keyNote = (error as? UserFacingError)?.message ?? "Couldn't save the key." }
    }

    private var consent: some View {
        VStack(alignment: .leading) {
            title("One more thing", "Before your first session.")
            Text("**Consent & rules.** " + PrivacyCopy.consentNote)
                .lineSpacing(3).card()
            VStack(spacing: 0) {
                Toggle("Remind me before each session", isOn: $prefs.remindBeforeSession).padding(.vertical, 6)
                Divider()
                Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })).padding(.vertical, 6)
            }.toggleStyle(.switch).card().padding(.top, 8)
            if let e = prefs.launchAtLoginError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            Toggle("I understand and will follow the rules that apply to me", isOn: $model.consentAcknowledged)
                .padding(.top, 10)
        }
    }
}
