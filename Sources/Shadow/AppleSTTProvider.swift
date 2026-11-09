// SPDX-License-Identifier: Apache-2.0

import Speech
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import ShadowKit

/// On-device speech-to-text with SpeechAnalyzer / SpeechTranscriber: no keys, one analyzer per stream (R10).
final class AppleSTTProvider: STTProvider, @unchecked Sendable {
    /// Called with 0...1 while model assets download, and with nil when done. Hop to the main actor in the handler.
    private let onProgress: @Sendable (Double?) -> Void

    init(onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) { self.onProgress = onProgress }

    fileprivate static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    func prepare(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw UserFacingError("On-device speech recognition isn't available on this Mac.")
        }
        try await SpeechModelPreparer.prepare(locale: locale, service: AppleSpeechAssetService(), onProgress: onProgress)
    }

    func transcribe(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> AsyncThrowingStream<Segment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(source, speaker: speaker, locale: locale, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    AppLog.speechError(error, context: "transcribe \(speaker.rawValue)", locale: locale)
                    continuation.finish(throwing: error is UserFacingError ? error : UserFacingError("The speech recognizer hit an error."))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ e: Error) { lock.withLock { if error == nil { error = e } } }
        var value: Error? { lock.withLock { error } }
    }

    /// The feed loop writes the clock and the results task reads it, so guard it with a lock.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var clock = AnalyzerClock()
        func start(sessionTime: TimeInterval, frames: Int, sampleRate: Double) -> TimeInterval {
            lock.withLock { clock.start(sessionTime: sessionTime, frames: frames, sampleRate: sampleRate) }
        }
        func sessionTime(forAnalyzerTime t: TimeInterval) -> TimeInterval { lock.withLock { clock.sessionTime(forAnalyzerTime: t) } }
    }

    private static func run(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale,
                            into out: AsyncThrowingStream<Segment, Error>.Continuation) async throws {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = makeTranscriber(resolved)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw UserFacingError("Speech recognition can't read this audio.")
        }
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let localeID = resolved.identifier(.bcp47)
        let failure = Failure()
        // One clock per run: each stream (and each restart) has independent, monotonic analyzer time (R1, R5).
        let clock = ClockBox()

        let results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let range = result.range
                    let start = range.start.seconds, end = range.end.seconds
                    let confidence = result.text.runs.compactMap { $0.transcriptionConfidence }
                    out.yield(Segment(speaker: speaker, text: text,
                                      start: start.isFinite ? clock.sessionTime(forAnalyzerTime: start) : 0,
                                      end: end.isFinite ? clock.sessionTime(forAnalyzerTime: end) : 0,
                                      locale: localeID,
                                      confidence: confidence.isEmpty ? 1 : confidence.reduce(0, +) / Double(confidence.count),
                                      isFinal: result.isFinal))
                }
            } catch {
                // Surface it now, not when the source ends: close the input so the feed loop below stops.
                failure.set(error)
                inputContinuation.finish()
            }
        }

        // Whatever way this ends (error or cancel), stop the results reader and close the analyzer's input.
        defer { inputContinuation.finish(); results.cancel() }
        try await analyzer.start(inputSequence: inputs)
        var converter: AVAudioConverter?
        for await item in source {
            if failure.value != nil { break }
            guard let buffer = convert(item.buffer, to: target, using: &converter) else { continue }
            let start = clock.start(sessionTime: item.time, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
            inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(seconds: start, preferredTimescale: 48_000)))
        }
        inputContinuation.finish()
        if failure.value == nil { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        await results.value
        if let error = failure.value { throw error }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let input = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if let next = input.take() { inputStatus.pointee = .haveData; return next }
            inputStatus.pointee = .noDataNow; return nil
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

/// Hands the converter its one buffer exactly once. The converter calls its input block synchronously on the calling thread.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}

/// The real asset service: SpeechTranscriber for locale decisions and AssetInventory for the download.
private struct AppleSpeechAssetService: SpeechAssetService {
    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func isInstalled(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    func download(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Both streams share one locale, so one download covers both analyzers.
        let transcriber = AppleSTTProvider.makeTranscriber(locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let fraction = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                progress(fraction.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }
}
