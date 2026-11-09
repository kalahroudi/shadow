// SPDX-License-Identifier: Apache-2.0

import AVFoundation

/// The one start time of a session. Every buffer time is derived from it, so Them and You share a clock (R5).
public struct SessionClock: Sendable, Equatable {
    public let start: Date
    public init(start: Date = Date()) { self.start = start }

    /// Seconds since the session started.
    public func time(at date: Date = Date()) -> TimeInterval { date.timeIntervalSince(start) }
}

/// An audio buffer stamped in seconds since the session start.
public struct TimedBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let time: TimeInterval
    public init(buffer: AVAudioPCMBuffer, time: TimeInterval) { self.buffer = buffer; self.time = time }
}

/// A live audio stream (Them: system audio, You: microphone). Real implementations live in the app target.
public protocol AudioSource: Sendable {
    /// Starts capture and returns the buffers on their own async sequence, which finishes after `stop()`.
    func start(clock: SessionClock) async throws -> AsyncStream<TimedBuffer>
    /// Stops capture and releases the device. Safe to call when not started.
    func stop() async
}
