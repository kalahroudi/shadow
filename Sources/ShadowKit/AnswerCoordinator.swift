// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// One answer as the overlay shows it (R17): the question, the text so far and where it came from.
public struct Answer: Equatable, Sendable {
    public var question: String
    public var text = ""
    public var isStreaming = true
    public var provider: String
    public var model: String
    public var isCloud: Bool
    public var latencyMs: Int?
    /// True when the answer hit the length cap and was cut off (R24).
    public var truncated = false
}

public enum AnswerState: Equatable, Sendable {
    case idle
    case answering(Answer)
    /// One friendly line; `partial` is whatever streamed before the failure.
    case failed(String, partial: Answer?)
    /// The persona doesn't suggest answers (R16). `switchTo` is the persona id the user can switch to.
    case declined(String, switchTo: String)
}

public enum AnswerTrigger: Equatable, Sendable {
    case started, noSession, nothingToAnswer, declined
}

/// Owns the one in-flight answer (R10) and decides when to start it: Answer now, auto-suggest and Retry all come through here.
/// It holds no task or timer while idle (R24). Prompts and answer text are never logged (R13).
@MainActor @Observable
public final class AnswerCoordinator {
    public static let maxAnswerCharacters = 8_000
    public static let defaultDebounce = Duration.milliseconds(1_200)

    public private(set) var state = AnswerState.idle

    private let settings: LLMSettings
    private let makeProvider: @MainActor (String) -> (any LLMProvider)?
    private let persona: @MainActor () -> Persona
    private let language: @MainActor () -> Language
    private let turns: @MainActor () -> [Segment]
    private let isSessionRunning: @MainActor () -> Bool
    private let autoSuggest: @MainActor () -> Bool
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let log: @MainActor (String) -> Void
    private let cap: Int

    private struct Pending { var request: LLMRequest; var question: String; var providerID: String; var isCloud: Bool }
    private struct TurnKey: Equatable { var start: TimeInterval; var text: String }

    private var task: Task<Void, Never>?
    private var generation = 0
    private var last: Pending?
    private var debounceTask: Task<Void, Never>?
    private var debounceKey: TurnKey?
    private var handledKey: TurnKey?

    public init(settings: LLMSettings,
                makeProvider: @escaping @MainActor (String) -> (any LLMProvider)?,
                persona: @escaping @MainActor () -> Persona,
                language: @escaping @MainActor () -> Language,
                turns: @escaping @MainActor () -> [Segment],
                isSessionRunning: @escaping @MainActor () -> Bool,
                autoSuggest: @escaping @MainActor () -> Bool,
                clock: any Clock<Duration> = ContinuousClock(),
                debounce: Duration = AnswerCoordinator.defaultDebounce,
                maxCharacters: Int = AnswerCoordinator.maxAnswerCharacters,
                log: @escaping @MainActor (String) -> Void = { AppLog.info($0) }) {
        self.settings = settings; self.makeProvider = makeProvider; self.persona = persona; self.language = language
        self.turns = turns; self.isSessionRunning = isSessionRunning; self.autoSuggest = autoSuggest
        self.clock = clock; self.debounce = debounce; self.cap = max(1, maxCharacters); self.log = log
    }

    public var isStreaming: Bool { if case .answering(let a) = state { a.isStreaming } else { false } }
    /// The "cloud" badge shows while a cloud provider is active (R6).
    public var showsCloudBadge: Bool { settings.showsCloudBadge }

    // MARK: Triggers

    /// Answer now and the overlay's Answer button (R7, R9): the most recent question, else the latest Them turn.
    @discardableResult
    public func answerNow() -> AnswerTrigger {
        guard isSessionRunning() else { return .noSession }
        let p = persona()
        guard p.suggestsAnswers else {
            cancelStream()
            state = .declined("\(p.name) doesn't suggest answers. Switch to another persona to get one.", switchTo: Persona.default.id)
            return .declined
        }
        guard let question = target() else {
            cancelStream()
            state = .failed("Nothing to answer yet. Try again once the other person has spoken.", partial: nil)
            return .nothingToAnswer
        }
        start(question: question)
        return .started
    }

    /// Re-issues the last request unchanged: Retry after a failure, Regenerate after an answer (R18).
    @discardableResult
    public func reissue() -> AnswerTrigger {
        guard isSessionRunning() else { return .noSession }
        guard let last else { return answerNow() }
        run(last)
        return .started
    }

    /// Stop keeps the partial answer (R18).
    public func stop() {
        cancelStream()
        if case .answering(var a) = state { a.isStreaming = false; state = .answering(a) }
    }

    /// The session ended: nothing may keep running (R10, R24).
    public func sessionStopped() {
        cancelStream(); cancelDebounce()
        state = .idle; last = nil; handledKey = nil
    }

    public func sessionStarted() {
        cancelStream(); cancelDebounce()
        state = .idle; last = nil; handledKey = nil
    }

    /// Call after Local-only changes. Turning it on reselects a local provider and cancels an in-flight cloud answer (R6).
    public func localOnlyChanged(to on: Bool) {
        let outcome = settings.localOnlyChanged(to: on)
        guard outcome.shouldCancelCloud, task != nil, last?.isCloud == true else { return }
        var partial: Answer?
        if case .answering(var a) = state { a.isStreaming = false; partial = a }
        cancelStream()
        state = .failed(LocalOnlyPolicy.message, partial: partial)
    }

    // MARK: Auto-suggest (R8)

    /// Feed every transcript change. With auto-suggest on, a Them turn that ends in a question is answered once the Them
    /// stream has been quiet for the debounce. More Them speech restarts the wait; a statement never triggers.
    public func transcriptChanged(_ snapshot: TranscriptSnapshot) {
        guard isSessionRunning(), autoSuggest(), persona().suggestsAnswers else { cancelDebounce(); return }
        if let partial = snapshot.partials[.them], !blank(partial.text) { cancelDebounce(); return }   // the turn continues
        guard let latest = snapshot.finals.last(where: { $0.speaker == .them && !blank($0.text) }),
              case .question = QuestionClassifier.classify(latest.text) else { cancelDebounce(); return }
        let key = TurnKey(start: latest.start, text: latest.text)
        guard key != handledKey, key != debounceKey else { return }   // already answered or already waiting
        cancelDebounce()
        debounceKey = key
        let (clock, wait) = (clock, debounce)
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(for: wait) } catch { return }
            self?.debounceElapsed(key)
        }
    }

    private func debounceElapsed(_ key: TurnKey) {
        guard debounceKey == key else { return }
        debounceTask = nil; debounceKey = nil
        guard isSessionRunning(), autoSuggest(), persona().suggestsAnswers else { return }
        handledKey = key
        start(question: key.text)
    }

    private func cancelDebounce() { debounceTask?.cancel(); debounceTask = nil; debounceKey = nil }

    // MARK: Running

    private func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func target() -> String? {
        let them = turns().filter { $0.speaker == .them && $0.isFinal && !blank($0.text) }
        for t in them.reversed() { if case .question(let q) = QuestionClassifier.classify(t.text) { return q } }
        return them.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start(question: String) {
        cancelStream()
        cancelDebounce()   // a manual answer must not be replaced by a pending auto-suggest for the same question
        let id = settings.selectedProviderID
        guard let provider = makeProvider(id) else {
            state = .failed(LLMError(.unavailable).message, partial: nil); return
        }
        let p = persona(), lang = language()
        let model = CloudKind(rawValue: id).map { settings.model(for: $0) } ?? ""
        let context = ContextBuilder.build(persona: p, language: lang, turns: turns(), question: question)
        let pending = Pending(request: LLMRequest(context: context, persona: p, language: lang, model: model),
                              question: question, providerID: id, isCloud: provider.isCloud)
        last = pending
        run(pending, provider: provider)
    }

    private func run(_ pending: Pending, provider: (any LLMProvider)? = nil) {
        cancelStream()
        guard let provider = provider ?? makeProvider(pending.providerID) else {
            state = .failed(LLMError(.unavailable).message, partial: nil); return
        }
        if provider.isCloud && settings.localOnly { state = .failed(LocalOnlyPolicy.message, partial: nil); return }
        let model = pending.request.model
        generation += 1
        let gen = generation
        state = .answering(Answer(question: pending.question, provider: pending.providerID, model: model, isCloud: provider.isCloud))
        let stream = provider.stream(pending.request)
        let started = ContinuousClock.now
        task = Task { [weak self] in
            do {
                for try await delta in stream {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    if self.append(delta) { break }   // leaving the loop drops the stream, which cancels the provider
                }
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.finish(started: started)
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    /// Appends a delta, bounded by the cap. Returns true when the cap was reached.
    private func append(_ delta: String) -> Bool {
        guard case .answering(var a) = state else { return true }
        let room = cap - a.text.count
        if delta.count > room {
            a.text += delta.prefix(max(0, room)); a.truncated = true
            state = .answering(a)
            return true
        }
        a.text += delta
        state = .answering(a)
        return false
    }

    private func finish(started: ContinuousClock.Instant) {
        guard case .answering(var a) = state else { return }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        a.isStreaming = false; a.latencyMs = ms
        state = .answering(a)
        task = nil
        // Only provider, model, latency and a size estimate: never the prompt or the answer (R13).
        log("answer provider=\(a.provider) model=\(a.model.isEmpty ? "default" : a.model) latencyMs=\(ms) tokens~\(ContextBuilder.estimateTokens(a.text))")
    }

    private func fail(_ error: Error) {
        var partial: Answer?
        if case .answering(var a) = state { a.isStreaming = false; partial = a.text.isEmpty ? nil : a }
        task = nil
        let kind = (error as? LLMError)?.kind.rawValue ?? "other"
        log("answer failed provider=\(last?.providerID ?? "?") class=\(kind)")
        state = .failed(UserError.message(for: error, action: "Get an answer"), partial: partial)
    }

    private func cancelStream() {
        generation += 1   // late deltas from the cancelled stream are ignored
        task?.cancel(); task = nil
    }
}
