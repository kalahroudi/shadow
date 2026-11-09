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
    private let lock = NSLock()
    private var continuation: AsyncStream<TimedBuffer>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var clocks: [SessionClock] = []

    init(script: [(offset: TimeInterval, value: Float)], failOnStart: Bool = false) {
        self.script = script; self.failOnStart = failOnStart
    }

    func start(clock: SessionClock) async throws -> AsyncStream<TimedBuffer> {
        if failOnStart { throw Failure() }
        let (stream, c) = AsyncStream<TimedBuffer>.makeStream()
        lock.withLock { continuation = c; startCount += 1; clocks.append(clock) }
        for item in script {
            c.yield(TimedBuffer(buffer: makeBuffer(item.value), time: clock.time(at: clock.start.addingTimeInterval(item.offset))))
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

    /// `failures`: after yielding that many segments for the speaker, the stream throws the error (and stops reading its source).
    init(scripts: [Speaker: [Segment]], prepareError: Error? = nil, failures: [Speaker: (afterSegments: Int, error: Error)] = [:]) {
        self.scripts = scripts; self.prepareError = prepareError; self.failures = failures
    }

    func prepare(locale: Locale) async throws {
        lock.withLock { preparedLocales.append(locale) }
        if let prepareError { throw prepareError }
    }

    func transcribe(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> AsyncThrowingStream<Segment, Error> {
        let script = scripts[speaker] ?? []
        let failure = failures[speaker]
        return AsyncThrowingStream { continuation in
            let task = Task {
                var i = 0
                if let failure, failure.afterSegments == 0 { continuation.finish(throwing: failure.error); return }
                for await _ in source {
                    if i < script.count { continuation.yield(script[i]); i += 1 }
                    if let failure, i >= failure.afterSegments { continuation.finish(throwing: failure.error); return }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
