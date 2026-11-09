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
    // Answering (R9, R16–R20). The defaults keep Idle and Listening as they were.
    var answer: AnswerState = .idle
    var showsCloudBadge = false
    var canFollowUp = false
    var canRegenerate = false
    var canGoBack = false
    var canGoForward = false
    var historyPosition: String?
    var answerHotkey = ""
    var copyHotkey = ""
    var switchPersonaName = ""
}

struct OverlayActions {
    var toggleSession: @MainActor @Sendable () -> Void = {}
    var toggleClickThrough: @MainActor @Sendable () -> Void = {}
    var toggleCompact: @MainActor @Sendable () -> Void = {}
    var hide: @MainActor @Sendable () -> Void = {}
    var copy: @MainActor @Sendable () -> Void = {}
    var setOpacity: @MainActor @Sendable (Double) -> Void = { _ in }
    var answer: @MainActor @Sendable () -> Void = {}
    var copyAnswer: @MainActor @Sendable () -> Void = {}
    var regenerate: @MainActor @Sendable () -> Void = {}
    var stop: @MainActor @Sendable () -> Void = {}
    var retry: @MainActor @Sendable () -> Void = {}
    var chip: @MainActor @Sendable (FollowUpChip) -> Void = { _ in }
    var back: @MainActor @Sendable () -> Void = {}
    var forward: @MainActor @Sendable () -> Void = {}
    var switchPersona: @MainActor @Sendable () -> Void = {}
}

/// The overlay bound to the live app state. Created when the panel opens and dropped when it closes (R3).
struct LiveOverlayView: View {
    @State private var model = AppModel.shared
    @State private var prefs = Prefs.shared

    var body: some View {
        let answers = model.answers
        let switchTo = (answers.state.switchTarget).flatMap { prefs.personas.persona($0)?.name } ?? ""
        OverlayView(
            content: OverlayContent(
                state: .from(sessionRunning: model.isRunning, answer: answers.state), compact: prefs.overlayCompact, lines: model.transcript.lines,
                levels: model.levels, opacity: prefs.overlayOpacity, clickThrough: model.clickThrough,
                persona: prefs.personas.active.name, sessionStart: model.sessionStart,
                startHotkey: prefs.hotkeys[.toggleSession]?.display ?? "",
                clickThroughHotkey: prefs.hotkeys[.toggleClickThrough]?.display ?? "",
                answer: answers.state, showsCloudBadge: answers.showsCloudBadge, canFollowUp: answers.canFollowUp, canRegenerate: answers.canRegenerate,
                canGoBack: answers.canGoBack, canGoForward: answers.canGoForward, historyPosition: answers.history.position,
                answerHotkey: prefs.hotkeys[.answerNow]?.display ?? "", copyHotkey: prefs.hotkeys[.copyAnswer]?.display ?? "",
                switchPersonaName: switchTo),
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
                setOpacity: { prefs.overlayOpacity = $0 },
                answer: { answers.answerNow() }, copyAnswer: { model.copyAnswer() }, regenerate: { answers.reissue() },
                stop: { answers.stop() }, retry: { answers.reissue() }, chip: { answers.chip($0) },
                back: { answers.goBack() }, forward: { answers.goForward() },
                switchPersona: { if let id = answers.state.switchTarget { prefs.personas.select(id) } }))
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
            if content.showsCloudBadge || content.answer.isCloud {
                Label("cloud", systemImage: "cloud").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.fill, in: Capsule()).foregroundStyle(.secondary)
                    .help("A cloud provider is active: questions and recent turns are sent to it.")
            }
            Spacer(minLength: 4)
            if content.state != .idle, !(content.compact && (content.state == .answering || content.state == .error)) {
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
        case .answering, .error:
            AnswerBody(content: content, actions: actions)
        case .listening:
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
                } else if let info = content.answerFooter {
                    Text(info)
                } else {
                    Text(content.state == .idle ? "Ready · \(content.persona) persona" : "\(content.persona) persona")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if content.state == .listening {
                Button(action: actions.answer) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles"); Text("Answer").fontWeight(.semibold)
                        Text(content.answerHotkey).opacity(0.7)
                    }
                    .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent).contentShape(Capsule())
                }
                .buttonStyle(.plain).help("Answer the latest question").accessibilityLabel("Answer")
            }
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

extension OverlayContent {
    /// "provider · model · 1.2 s" once an answer is on screen (R17).
    var answerFooter: String? {
        guard case .answering(let a) = answer else { return nil }
        var parts = [a.provider]
        if !a.model.isEmpty { parts.append(a.model) }
        if let ms = a.latencyMs { parts.append(String(format: "%.1f s", Double(ms) / 1000)) }
        return parts.joined(separator: " · ")
    }
}

/// The Answering face: question, streamed markdown in a scrolling area, then the action and chip rows (R17–R20).
struct AnswerBody: View {
    let content: OverlayContent
    let actions: OverlayActions

    var body: some View {
        switch content.answer {
        case .idle:
            EmptyView()
        case .declined(let message, _):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                pill("Switch to \(content.switchPersonaName)", "arrow.triangle.swap", actions.switchPersona)
            }
        case .failed(let message, let partial):
            VStack(alignment: .leading, spacing: 8) {
                if let partial { scroller(partial) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.system(size: 11))
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                pill("Retry", "arrow.clockwise", actions.retry)
                if partial == nil { Spacer(minLength: 0) }
            }
        case .answering(let a):
            VStack(alignment: .leading, spacing: 8) {
                scroller(a)
                controls(a)
                if content.canFollowUp { chips }
            }
        }
    }

    private func scroller(_ a: Answer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text("THEM").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.them)) \(Text(a.question).foregroundColor(.secondary))")
                    .fixedSize(horizontal: false, vertical: true)
                MarkdownView(text: a.text, caret: a.isStreaming)
                if a.truncated { Text("Cut off at the length limit.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func controls(_ a: Answer) -> some View {
        HStack(spacing: 6) {
            arrow("chevron.left", "Previous answer", content.canGoBack, actions.back)
            if let pos = content.historyPosition { Text(pos).font(.system(size: 10)).foregroundStyle(.secondary) }
            arrow("chevron.right", "Next answer", content.canGoForward, actions.forward)
            Spacer(minLength: 4)
            if a.isStreaming {
                pill("Stop", "stop.fill", actions.stop)
            } else if content.canRegenerate {
                pill("Regenerate", "arrow.clockwise", actions.regenerate)
            }
            pill("Copy", "doc.on.doc", actions.copyAnswer, hint: content.copyHotkey).disabled(a.text.isEmpty)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([FollowUpChip.shorter, .addMetric, .likelyFollowUp], id: \.self) { c in
                    Button(c.title) { actions.chip(c) }.buttonStyle(ChipStyle())
                }
                Menu("Say it in…") {
                    ForEach(FollowUpChip.languageChips, id: \.self) { c in Button(c.title) { actions.chip(c) } }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            }
        }
    }

    private func arrow(_ name: String, _ help: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).help(help).accessibilityLabel(help)
    }

    private func pill(_ title: String, _ icon: String, _ action: @escaping () -> Void, hint: String = "") -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon); Text(title)
                if !hint.isEmpty { Text(hint).opacity(0.6) }
            }
            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.fill, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(title)
    }
}

private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Renders `MarkdownParser` output: bullets, bold, inline code and fenced code, with a caret while streaming.
struct MarkdownView: View {
    let text: String
    let caret: Bool

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                let last = caret && i == blocks.count - 1
                switch block {
                case .paragraph(let parts): runs(parts, caret: last).fixedSize(horizontal: false, vertical: true)
                case .bullet(let parts):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•"); runs(parts, caret: last).fixedSize(horizontal: false, vertical: true)
                    }
                case .code(_, let code, _):
                    Text(code + (last ? "▌" : "")).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if caret && (blocks.isEmpty) { Text("▌").foregroundStyle(Theme.accent) }
        }
    }

    private func runs(_ parts: [MarkdownInline], caret: Bool) -> Text {
        var out = AttributedString()
        for p in parts {
            switch p {
            case .text(let t): out += AttributedString(t)
            case .bold(let t): var x = AttributedString(t); x.inlinePresentationIntent = .stronglyEmphasized; out += x
            case .code(let t): var x = AttributedString(t); x.inlinePresentationIntent = .code; out += x
            }
        }
        if caret { var c = AttributedString("▌"); c.foregroundColor = Theme.accent; out += c }
        return Text(out)
    }
}
