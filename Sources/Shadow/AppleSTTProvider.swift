// SPDX-License-Identifier: Apache-2.0

import Speech
@preconcurrency import AVFoundation
import ShadowKit

/// On-device speech-to-text with SpeechAnalyzer / SpeechTranscriber: no keys, one analyzer per stream (R10).
final class AppleSTTProvider: STTProvider, @unchecked Sendable {
    /// Called with 0...1 while model assets download, and with nil when done. Hop to the main actor in the handler.
    private let onProgress: @Sendable (Double?) -> Void

    init(onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) { self.onProgress = onProgress }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    func prepare(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw UserFacingError("On-device speech recognition isn't available on this Mac.")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            AppLog.info("unsupported speech locale \(locale.identifier)")
            throw UserFacingError("Speech recognition doesn't support this language yet. Pick another language.")
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) { return }

        // Both streams share one locale, so one download covers both analyzers.
        let transcriber = Self.makeTranscriber(supported)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            onProgress(0)
            let progress = request.progress
            let watcher = Task {
                while !Task.isCancelled {
                    onProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel(); onProgress(nil) }
            try await request.downloadAndInstall()
        } catch {
            AppLog.error(error, context: "download speech assets for \(supported.identifier)")
            throw UserFacingError("Couldn't download the speech model. Check your internet connection and try again.")
        }
    }

    func transcribe(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> AsyncStream<Segment> {
        AsyncStream { continuation in
            let task = Task {
                do { try await Self.run(source, speaker: speaker, locale: locale, into: continuation) }
                catch { AppLog.error(error, context: "transcribe \(speaker.rawValue)") }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale,
                            into out: AsyncStream<Segment>.Continuation) async throws {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = makeTranscriber(resolved)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw UserFacingError("Speech recognition can't read this audio.")
        }
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let localeID = resolved.identifier(.bcp47)

        let results = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                let confidence = result.text.runs.compactMap { $0.transcriptionConfidence }
                out.yield(Segment(speaker: speaker, text: text,
                                  start: range.start.seconds.isFinite ? range.start.seconds : 0,
                                  end: range.end.seconds.isFinite ? range.end.seconds : 0,
                                  locale: localeID,
                                  confidence: confidence.isEmpty ? 1 : confidence.reduce(0, +) / Double(confidence.count),
                                  isFinal: result.isFinal))
            }
        }

        try await analyzer.start(inputSequence: inputs)
        var converter: AVAudioConverter?
        for await item in source {
            guard let buffer = convert(item.buffer, to: target, using: &converter) else { continue }
            inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(seconds: item.time, preferredTimescale: 48_000)))
        }
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}
