// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import ShadowKit

enum AudioConversion {
    /// Copies a ScreenCaptureKit audio sample buffer into an `AVAudioPCMBuffer`. Nil when the buffer isn't readable PCM.
    static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sample.isValid, let desc = sample.formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return nil }
        var streamDesc = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Seconds on the host clock (the clock both SCStream and AVAudioEngine stamp with) right now.
    static func hostNow() -> TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
