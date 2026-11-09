// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Monotonic buffer start times for one speech analyzer stream (R1-R5).
/// Pure: takes frame counts and sample rates as numbers, so it has no Speech or AVFoundation dependency.
public struct AnalyzerClock: Sendable {
    private var previousEnd: TimeInterval = -.infinity
    /// (analyzer start, start - session time) for each buffer, oldest first, used to map results back to session time.
    private var history: [(start: TimeInterval, offset: TimeInterval)] = []
    private static let historyLimit = 4096

    public init() {}

    /// Start time to give the analyzer for a buffer whose session time is `sessionTime`.
    /// A strictly later session time wins (gaps are kept); otherwise the previous buffer's end is used.
    public mutating func start(sessionTime: TimeInterval, frames: Int, sampleRate: Double) -> TimeInterval {
        let time = sessionTime.isFinite ? sessionTime : -.infinity
        var result = time > previousEnd ? time : previousEnd
        if !result.isFinite { result = 0 }
        if frames > 0, sampleRate > 0, sampleRate.isFinite {
            previousEnd = result + Double(frames) / sampleRate
            history.append((result, result - (sessionTime.isFinite ? sessionTime : result)))
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit / 2) }
        }
        return result
    }

    /// Latest output start minus its input session time.
    public var offset: TimeInterval { history.last?.offset ?? 0 }

    /// Translates an analyzer-time position back to session time, using the offset of the buffer it falls in.
    public func sessionTime(forAnalyzerTime t: TimeInterval) -> TimeInterval {
        let i = history.lastIndex { $0.start <= t }
        return t - (i.map { history[$0].offset } ?? history.first?.offset ?? 0)
    }
}
