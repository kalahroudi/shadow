// SPDX-License-Identifier: Apache-2.0

@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import ShadowKit

/// Them: system audio through an audio-only SCStream that excludes Shadow's own sound (R5).
final class SCKAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct State {
        var stream: SCStream?
        var continuation: AsyncStream<TimedBuffer>.Continuation?
        var clock: SessionClock?
    }
    private let state = NSLock()
    private var current = State()
    private let queue = DispatchQueue(label: "shadow.sck.audio")

    func start(clock: SessionClock) async throws -> AsyncStream<TimedBuffer> {
        await stop()
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch {
            AppLog.error(error, context: "list shareable content")
            throw UserFacingError("Shadow can't capture system audio. Check Screen & System Audio Recording in System Settings.")
        }
        guard let display = content.displays.first else {
            throw UserFacingError("Shadow couldn't find a display to capture audio from.")
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Audio-only: the smallest, slowest video SCStream accepts, and we never attach a screen output.
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let (buffers, continuation) = AsyncStream<TimedBuffer>.makeStream(bufferingPolicy: .bufferingNewest(256))
        state.withLock { current = State(stream: stream, continuation: continuation, clock: clock) }
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            AppLog.error(error, context: "start system audio capture")
            await stop()
            throw UserFacingError("Shadow couldn't start capturing system audio. Check Screen & System Audio Recording in System Settings.")
        }
        return buffers
    }

    func stop() async {
        let old = state.withLock { () -> State in defer { current = State() }; return current }
        if let stream = old.stream {
            try? stream.removeStreamOutput(self, type: .audio)
            do { try await stream.stopCapture() } catch { AppLog.error(error, context: "stop system audio capture") }
        }
        old.continuation?.finish()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = AudioConversion.pcmBuffer(from: sampleBuffer) else { return }
        let (continuation, clock) = state.withLock { (current.continuation, current.clock) }
        guard let continuation, let clock else { return }
        let time = clock.time(hostSeconds: sampleBuffer.presentationTimeStamp.seconds, hostNow: AudioConversion.hostNow())
        continuation.yield(TimedBuffer(buffer: pcm, time: max(0, time)))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.error(error, context: "system audio stream stopped")
        let c = state.withLock { () -> AsyncStream<TimedBuffer>.Continuation? in defer { current = State() }; return current.continuation }
        c?.finish()
    }
}
