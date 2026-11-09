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
    private var tasks: [Task<Void, Never>] = []
    private var levels = Levels()
    private var observers: [UUID: AsyncStream<Levels>.Continuation] = [:]

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

    /// Splits one source into a level meter and an STT consumer; returns the two tasks that run until the source ends.
    private func run(_ buffers: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> [Task<Void, Never>] {
        let (forSTT, out) = AsyncStream<TimedBuffer>.makeStream()
        let pump = Task {
            for await item in buffers {
                self.setLevel(LevelMeter.level(of: item.buffer), for: speaker)
                out.yield(item)
            }
            out.finish()
        }
        let segments = stt.transcribe(forSTT, speaker: speaker, locale: locale)
        let consume = Task {
            for await segment in segments {
                await self.transcript.add(segment)
                if segment.isFinal { await self.checkpoint() }
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

    private func setLevel(_ value: Float, for speaker: Speaker) {
        guard session != nil else { return }
        if speaker == .them { levels.them = value } else { levels.you = value }
        publish()
    }

    private func publish() { for c in observers.values { c.yield(levels) } }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
