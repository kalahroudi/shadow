// SPDX-License-Identifier: Apache-2.0

import AVFoundation

/// Audio level for the Them/You meters (R6): RMS of all samples across channels, 0...1.
public enum LevelMeter {
    public static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, (sum / Float(samples.count)).squareRoot())
    }

    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum = Float(0)
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<frames { sum += data[c][i] * data[c][i] }
        }
        return min(1, (sum / Float(frames * Int(buffer.format.channelCount))).squareRoot())
    }
}
