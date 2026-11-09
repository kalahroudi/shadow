// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// Everything the overlay draws, as plain values, so snapshots can render it from sample data (R24).
struct OverlayContent {
    var state: OverlayState
    var compact: Bool
    var lines: [Segment]
    var levels: Levels
    var opacity: Double
    var clickThrough: Bool
    var persona: String
    var sessionStart: Date?
    var startHotkey: String
    var clickThroughHotkey: String
}

struct OverlayActions {
    var toggleSession: @MainActor @Sendable () -> Void = {}
    var toggleClickThrough: @MainActor @Sendable () -> Void = {}
    var toggleCompact: @MainActor @Sendable () -> Void = {}
    var hide: @MainActor @Sendable () -> Void = {}
    var copy: @MainActor @Sendable () -> Void = {}
    var setOpacity: @MainActor @Sendable (Double) -> Void = { _ in }
}

/// The overlay bound to the live app state. Created when the panel opens and dropped when it closes (R3).
struct LiveOverlayView: View {
    @State private var model = AppModel.shared
    @State private var prefs = Prefs.shared

    var body: some View {
        OverlayView(
            content: OverlayContent(
                state: .from(sessionRunning: model.isRunning), compact: prefs.overlayCompact, lines: model.transcript.lines,
                levels: model.levels, opacity: prefs.overlayOpacity, clickThrough: model.clickThrough,
                persona: prefs.persona.label, sessionStart: model.sessionStart,
                startHotkey: prefs.hotkeys[.toggleSession]?.display ?? "",
                clickThroughHotkey: prefs.hotkeys[.toggleClickThrough]?.display ?? ""),
            actions: OverlayActions(
                toggleSession: { model.toggleSession() },
                toggleClickThrough: { model.clickThrough.toggle() },
                toggleCompact: { prefs.overlayCompact.toggle() },
                hide: { prefs.overlayVisible = false },
                copy: {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(TranscriptFormatter.text(model.transcript.lines), forType: .string)
                },
                setOpacity: { prefs.overlayOpacity = $0 }))
    }
}

struct OverlayView: View {
    let content: OverlayContent
    let actions: OverlayActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            bodyContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
            Divider().opacity(0.5)
            footer
        }
        .font(.system(size: 13))
        .overlay {
            if content.clickThrough {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if content.clickThrough {
                Text("Click-through on · \(content.clickThroughHotkey) to turn off")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.accent, in: Capsule())
                    .padding(.bottom, 34).allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcon.image(size: 18)).resizable().frame(width: 18, height: 18)
            Text(content.state.label).font(.system(size: 13, weight: .semibold))
            Circle().fill(content.state == .idle ? Color.secondary : Theme.danger).frame(width: 7, height: 7)
            Text(content.persona).font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
            Spacer(minLength: 4)
            if content.state != .idle {
                meter("speaker.wave.2", content.levels.them, Theme.them)
                meter("mic", content.levels.you, Theme.you)
            }
            iconButton("pointer.arrow.click", "Click-through", action: actions.toggleClickThrough)
            iconButton("doc.on.doc", "Copy transcript", action: actions.copy)
            iconButton(content.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left", "Expand or compact", action: actions.toggleCompact)
            iconButton("xmark", "Hide overlay", action: actions.hide)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var bodyContent: some View {
        switch content.state {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Not listening. Start a session to transcribe the call.").foregroundStyle(.secondary)
                Button(action: actions.toggleSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill"); Text("Start session").fontWeight(.semibold)
                        Text(content.startHotkey).font(.system(size: 11)).opacity(0.8)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).foregroundStyle(.white)
                    .background(LinearGradient(colors: [Color(nsColor: AppIcon.violet), Color(nsColor: AppIcon.blue)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text("Using Apple SpeechAnalyzer · nothing leaves this Mac").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        case .listening, .answering:   // Answering is a stub: it renders like Listening and nothing enters it yet
            let shown = content.compact ? Array(content.lines.suffix(3)) : Array(content.lines.suffix(12))
            if shown.isEmpty {
                Text("Listening… the transcript appears here.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, seg in line(seg) }
                }
            }
        }
    }

    private func line(_ seg: Segment) -> some View {
        let them = seg.speaker == .them
        let who = Text(them ? "THEM" : "YOU").font(.system(size: 10, weight: .bold)).foregroundColor(them ? Theme.them : Theme.you)
        let words = Text(seg.text + (seg.isFinal ? "" : "…")).foregroundColor(seg.isFinal ? .primary : .secondary)
        return Text("\(who) \(words)")
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Built here rather than inline so the isolated setter never needs a generic reabstraction thunk.
    private var opacityBinding: Binding<Double> {
        let actions = actions, opacity = content.opacity
        return Binding<Double>(get: { opacity }, set: { newValue in MainActor.assumeIsolated { actions.setOpacity(newValue) } })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if let start = content.sessionStart, content.state == .listening {
                    // Only ticks while a session runs: the overlay holds no timers otherwise (R3).
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text("\(Self.elapsed(ctx.date.timeIntervalSince(start))) · \(content.persona) persona")
                    }
                } else {
                    Text(content.state == .idle ? "Ready · \(content.persona) persona" : "\(content.persona) persona")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: opacityBinding, in: OverlayLayout.opacityRange)
                .controlSize(.mini).frame(width: 90).accessibilityLabel("Opacity")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func meter(_ icon: String, _ value: Float, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(tint).frame(width: 30 * CGFloat(min(1, value)))
            }.frame(width: 30, height: 4)
        }
    }

    private func iconButton(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11)).frame(width: 22, height: 22)
                .foregroundStyle(content.clickThrough && name.hasPrefix("pointer") ? Theme.accent : .secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
