// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ShadowKit

/// The menu bar popover for milestone 1 (R17). Light on purpose: AppDelegate drops its views on close.
/// Every row is a full-width hit target, and every control writes straight to Prefs.
struct PopoverView: View {
    @State private var model = AppModel.shared
    @State private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.showChecklist { PermissionChecklistView(checker: model.checker) { model.recheckPermissions() } } else { startButton }
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            meters
            captions
            VStack(spacing: 0) {
                row(icon: "person.circle", title: "Persona") {
                    Picker("Persona", selection: $prefs.persona) { ForEach(Persona.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                row(icon: "globe", title: "Language") {
                    Picker("Language", selection: $prefs.language) { ForEach(Language.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                Toggle(isOn: $prefs.overlayVisible) {
                    HStack(spacing: 8) { icon("eye"); Text("Show overlay"); Spacer() }
                }
                .toggleStyle(.switch).padding(.vertical, 5).contentShape(Rectangle())
            }
            HStack {
                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                Text("Speech").font(.system(size: 13))
                Spacer()
                Text("Apple SpeechAnalyzer").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .card(padding: 10)
            Divider()
            VStack(spacing: 0) {
                if Updater.shared.state.showsPopoverRow {
                    button(icon: "arrow.down.circle", title: "Update available", trailing: Updater.shared.state.availableUpdate?.version) { model.onOpenUpdates?() }
                }
                button(icon: "questionmark.circle", title: "Run setup again…", trailing: nil) { OnboardingWindowController.shared.show() }
                button(icon: "gearshape", title: "Settings…", trailing: "⌘,") { model.onOpenSettings?() }
                button(icon: "power", title: "Quit Shadow", trailing: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.recheckPermissions() }
        .background(Theme.pane)   // an opaque themed background: the popover must follow the app theme
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 30)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Shadow").font(.system(size: 14, weight: .semibold))
                headerSubtitle
            }
            Spacer()
            Text(model.isRunning ? "Listening" : "Idle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(model.isRunning ? Theme.ok.opacity(0.18) : Theme.fill, in: Capsule())
                .foregroundStyle(model.isRunning ? Theme.ok : .secondary)
        }
    }

    @ViewBuilder private var headerSubtitle: some View {
        if model.isRunning, let start = model.session.startedAt {
            // The ticking clock exists only while the popover is open and a session runs.
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text("Session in progress · \(ElapsedFormat.string(model.session.elapsed(at: ctx.date)))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if let p = model.session.modelDownload {
            Text("Downloading speech model \(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Text(model.session.phase == .idle ? "Ready" : "Working…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// The last few lines of the live transcript, so Start visibly does something even with the overlay hidden.
    @ViewBuilder private var captions: some View {
        let lines = model.session.transcript.lines.suffix(3)
        if model.isRunning, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, seg in
                    Text("\(seg.speaker == .them ? "Them" : "You"): \(seg.text)")
                        .font(.system(size: 12)).foregroundStyle(seg.isFinal ? .primary : .secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card(padding: 8)
        }
    }

    private var startButton: some View {
        Button { model.toggleSession() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                Text(model.isRunning ? "Stop session" : "Start session").fontWeight(.semibold)
                Text(startHotkeyLabel).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
            .foregroundStyle(.white)
            .background(model.isRunning ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(LinearGradient(colors: [Color(nsColor: AppIcon.violet), Color(nsColor: AppIcon.blue)], startPoint: .leading, endPoint: .trailing)),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(model.session.phase == .starting || model.session.phase == .stopping)
    }

    private var startHotkeyLabel: String { prefs.hotkeys[.toggleSession]?.display ?? "" }

    private var meters: some View {
        VStack(spacing: 0) {
            meter(icon: "speaker.wave.2", title: "Them", value: model.levels.them, tint: Theme.them)
            meter(icon: "mic", title: "You", value: model.levels.you, tint: Theme.you)
        }
        .card(padding: 8)
    }

    private func meter(icon name: String, title: String, value: Float, tint: Color) -> some View {
        HStack(spacing: 8) {
            icon(name)
            Text(title).font(.system(size: 13)).frame(width: 40, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(tint).frame(width: max(0, g.size.width * CGFloat(min(1, value))))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title) level").accessibilityValue("\(Int(value * 100)) percent")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
    }

    private func row<C: View>(icon name: String, title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) { icon(name); Text(title); Spacer(); control() }
            .padding(.vertical, 5).contentShape(Rectangle())
    }

    private func button(icon name: String, title: String, trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon(name); Text(title); Spacer()
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
