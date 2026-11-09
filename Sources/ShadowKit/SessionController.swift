// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Meter values for the two streams, 0...1.
public struct Levels: Sendable, Equatable {
    public var them: Float = 0
    public var you: Float = 0
    public init(them: Float = 0, you: Float = 0) { self.them = them; self.you = you }
}

/// Drives one session: sources, STT, transcript and store (R21). Everything it touches is a protocol, so tests use fakes (R23).
public actor SessionController {
    public let transcript: Transcript
    private let them: any AudioSource
    private let you: any AudioSource
    private let stt: any STTProvider
    private let store: SessionStore
    private let now: @Sendable () -> Date

    private var session: SessionRecord?
    private var stopping = false
    private var tasks: [Task<Void, Never>] = []
    private var levels = Levels()
    private var sinks: [Speaker: AsyncStream<TimedBuffer>.Continuation] = [:]
    private var sourceDone: Set<Speaker> = []
    private var observers: [UUID: AsyncStream<Levels>.Continuation] = [:]
    private var noticeObservers: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(them: any AudioSource, you: any AudioSource, stt: any STTProvider, store: SessionStore,
                transcript: Transcript = Transcript(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.them = them; self.you = you; self.stt = stt; self.store = store; self.transcript = transcript; self.now = now
    }

    public var isRunning: Bool { session != nil }
    public var currentSessionID: UUID? { session?.id }

    /// Emits the current levels immediately, then one value per buffer. Returns to zero on stop.
    public func levelUpdates() -> AsyncStream<Levels> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Levels>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(levels)
        return stream
    }

    /// Friendly one-line notices raised while a session runs (for example one stream's speech recognition failing).
    /// Subscribe before `start`; notices are not replayed.
    public func notices() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        noticeObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeNoticeObserver(id) } }
        return stream
    }

    /// Prepares STT first (so a failure starts nothing), then starts both streams on one clock.
    @discardableResult
    public func start(locale: Locale) async throws -> UUID {
        guard session == nil else { throw UserFacingError("A session is already running.") }
        try await stt.prepare(locale: locale)

        let clock = SessionClock(start: now())
        let record = SessionRecord(id: UUID(), startedAt: clock.start)
        try store.begin(record.id)

        let themBuffers: AsyncStream<TimedBuffer>
        do { themBuffers = try await them.start(clock: clock) } catch { store.end(); throw error }
        let youBuffers: AsyncStream<TimedBuffer>
        do { youBuffers = try await you.start(clock: clock) } catch { await them.stop(); store.end(); throw error }

        session = record
        stopping = false
        levels = Levels()
        await transcript.reset()
        tasks = [run(themBuffers, speaker: .them, locale: locale), run(youBuffers, speaker: .you, locale: locale)].flatMap { $0 }
        return record.id
    }

    /// Stops capture, lets pending words finish, flushes partials as finals and writes the file.
    /// An empty transcript writes nothing. The lock is removed even when the write fails.
    @discardableResult
    public func stop() async throws -> SessionRecord? {
        guard var record = session else { return nil }
        stopping = true   // from here a source ending is expected, not a failure
        await them.stop()
        await you.stop()
        for task in tasks { await task.value }
        tasks = []
        session = nil
        await transcript.flushPartials()
        record.segments = await transcript.snapshot.finals
        record.endedAt = now()
        levels = Levels(); publish()

        defer { store.end() }
        guard !record.segments.isEmpty else { return nil }
        try store.write(record)
        return record
    }

    // MARK: pipeline

    /// Most restarts of one speaker's analyzer in a row before the user is told it stopped (R6, R7).
    static let maxRestarts = 3

    /// Splits one source into a level meter and a supervised STT consumer; returns the two tasks that run until the source ends.
    /// The pump feeds whichever sink is current for the speaker, so a restarted analyzer keeps receiving audio.
    private func run(_ buffers: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> [Task<Void, Never>] {
        sourceDone.remove(speaker)
        let pump = Task {
            for await item in buffers {
                self.setLevel(LevelMeter.level(of: item.buffer), for: speaker)
                // A dead recogniser's sink is replaced by the supervisor; yielding to a terminated one is harmless.
                _ = self.sinks[speaker]?.yield(item)
            }
            self.sourceDone.insert(speaker)
            self.sinks[speaker]?.finish()
            self.sourceEnded(speaker)
        }
        let consume = Task {
            var restarts = 0
            while true {
                let (forSTT, sink) = AsyncStream<TimedBuffer>.makeStream()
                self.sinks[speaker] = sink
                if self.sourceDone.contains(speaker) { sink.finish() }
                do {
                    for try await segment in self.stt.transcribe(forSTT, speaker: speaker, locale: locale) {
                        restarts = 0   // a working stream gets a fresh budget (R8)
                        await self.transcript.add(segment)
                        if segment.isFinal { await self.checkpoint() }
                    }
                    return
                } catch {
                    guard STTFailure.isRecoverable(error), restarts < Self.maxRestarts, self.session != nil else {
                        self.speechFailed(speaker, error, locale: locale)
                        return
                    }
                    restarts += 1
                    AppLog.speechError(error, context: "restart \(restarts)/\(Self.maxRestarts) transcribe \(speaker.rawValue)", locale: locale)
                }
            }
        }
        return [pump, consume]
    }

    /// Saves the finals so far, so an unclean exit can offer them back (R22).
    private func checkpoint() async {
        guard var record = session else { return }
        record.segments = await transcript.snapshot.finals
        do { try store.write(record) } catch { AppLog.error(error, context: "checkpoint session") }
    }

    /// One stream's recogniser died: tell the user, keep the other stream and everything transcribed so far.
    private func speechFailed(_ speaker: Speaker, _ error: Error, locale: Locale) {
        AppLog.speechError(error, context: "transcribe \(speaker.rawValue)", locale: locale)
        guard session != nil else { return }
        let who = speaker == .them ? "Them" : "You"
        let other = speaker == .them ? "You" : "Them"
        let detail = (error as? UserFacingError)?.message ?? "The speech recognizer hit an error."
        let message = "Speech recognition stopped for \(who): \(detail). Shadow is still capturing \(other); \(who) won't be transcribed until you start a new session."
        for c in noticeObservers.values { c.yield(message) }
    }

    /// A capture stream ended while the session is still running (the device vanished or the system stopped it).
    private func sourceEnded(_ speaker: Speaker) {
        guard session != nil, !stopping else { return }
        AppLog.info("audio source ended mid-session: \(speaker.rawValue)")
        let who = speaker == .them ? "system audio (Them)" : "the microphone (You)"
        let message = "Shadow lost \(who). Stop and start a new session to capture it again; what was captured so far is kept."
        for c in noticeObservers.values { c.yield(message) }
    }

    private func setLevel(_ value: Float, for speaker: Speaker) {
        guard session != nil else { return }
        if speaker == .them { levels.them = value } else { levels.you = value }
        publish()
    }

    private func publish() { for c in observers.values { c.yield(levels) } }
    private func removeNoticeObserver(_ id: UUID) { noticeObservers[id] = nil }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
