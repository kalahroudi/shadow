import AVFoundation
@testable import ShadowKit

func makeBuffer(_ value: Float, frames: Int = 160) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = value }
    return buffer
}

/// Emits scripted buffers, each stamped from the session clock at `start + offset`.
final class FakeAudioSource: AudioSource, @unchecked Sendable {
    struct Failure: Error {}
    private let script: [(offset: TimeInterval, value: Float)]
    private let failOnStart: Bool
    private let pace: TimeInterval
    private let lock = NSLock()
    private var continuation: AsyncStream<TimedBuffer>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var clocks: [SessionClock] = []

    /// `pace` > 0 delivers the buffers one per interval after `start` returns, like live capture, instead of all at once.
    init(script: [(offset: TimeInterval, value: Float)], failOnStart: Bool = false, pace: TimeInterval = 0) {
        self.script = script; self.failOnStart = failOnStart; self.pace = pace
    }

    func start(clock: SessionClock) async throws -> AsyncStream<TimedBuffer> {
        if failOnStart { throw Failure() }
        let (stream, c) = AsyncStream<TimedBuffer>.makeStream()
        lock.withLock { continuation = c; startCount += 1; clocks.append(clock) }
        let items = script.map { TimedBuffer(buffer: makeBuffer($0.value), time: clock.time(at: clock.start.addingTimeInterval($0.offset))) }
        if pace > 0 {
            let pace = pace
            Task { for item in items { try? await Task.sleep(nanoseconds: UInt64(pace * 1e9)); c.yield(item) } }
        } else {
            for item in items { c.yield(item) }
        }
        return stream
    }

    func stop() async {
        let c: AsyncStream<TimedBuffer>.Continuation? = lock.withLock { stopCount += 1; defer { continuation = nil }; return continuation }
        c?.finish()
    }
}

/// For each buffer received, emits the next scripted segment; finishes when the source finishes.
final class FakeSTTProvider: STTProvider, @unchecked Sendable {
    private let scripts: [Speaker: [Segment]]
    private let prepareError: Error?
    private let failures: [Speaker: (afterSegments: Int, error: Error)]
    private let lock = NSLock()
    private(set) var preparedLocales: [Locale] = []
    private var callFailures: [Speaker: [(afterSegments: Int, error: Error)?]]
    private var cursors: [Speaker: Int] = [:]
    private var calls: [Speaker: Int] = [:]
    private var received: [Speaker: Int] = [:]

    func transcribeCalls(_ speaker: Speaker) -> Int { lock.withLock { calls[speaker] ?? 0 } }
    /// Buffers delivered to any stream of this speaker.
    func buffersReceived(_ speaker: Speaker) -> Int { lock.withLock { received[speaker] ?? 0 } }

    /// `failures`: after yielding that many segments for the speaker, the stream throws the error (and stops reading its source).
    /// `callFailures`: one entry per `transcribe` call for the speaker (nil = that call works); calls past the end work.
    /// Segments come from one cursor per speaker, so a restarted stream continues the script instead of repeating it.
    init(scripts: [Speaker: [Segment]], prepareError: Error? = nil, failures: [Speaker: (afterSegments: Int, error: Error)] = [:],
         callFailures: [Speaker: [(afterSegments: Int, error: Error)?]] = [:]) {
        self.scripts = scripts; self.prepareError = prepareError; self.failures = failures; self.callFailures = callFailures
    }

    func prepare(locale: Locale) async throws {
        lock.withLock { preparedLocales.append(locale) }
        if let prepareError { throw prepareError }
    }

    func transcribe(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> AsyncThrowingStream<Segment, Error> {
        let script = scripts[speaker] ?? []
        let call: Int = lock.withLock { defer { calls[speaker, default: 0] += 1 }; return calls[speaker] ?? 0 }
        let scripted = callFailures[speaker].flatMap { call < $0.count ? $0[call] : nil }
        let failure = scripted ?? failures[speaker]
        return AsyncThrowingStream { continuation in
            let task = Task {
                var yielded = 0
                if let failure, failure.afterSegments == 0 { continuation.finish(throwing: failure.error); return }
                for await _ in source {
                    lock.withLock { received[speaker, default: 0] += 1 }
                    let next: Segment? = lock.withLock {
                        let i = cursors[speaker] ?? 0
                        guard i < script.count else { return nil }
                        cursors[speaker] = i + 1
                        return script[i]
                    }
                    if let next { continuation.yield(next); yielded += 1 }
                    if let failure, yielded >= failure.afterSegments { continuation.finish(throwing: failure.error); return }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class FakeRegistrar: PermissionRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [PermissionKind] = []
    var registered: [PermissionKind] { lock.withLock { calls } }
    func register(_ kind: PermissionKind) async { lock.withLock { calls.append(kind) } }
}

final class MutableChecker: PermissionChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PermissionKind: PermissionState]
    init(mic: PermissionState, screen: PermissionState) { states = [.microphone: mic, .screen: screen] }
    func set(_ kind: PermissionKind, _ s: PermissionState) { lock.withLock { states[kind] = s } }
    func status(_ kind: PermissionKind) -> PermissionState { lock.withLock { states[kind]! } }
    func request(_ kind: PermissionKind) async -> PermissionState { status(kind) }
}

