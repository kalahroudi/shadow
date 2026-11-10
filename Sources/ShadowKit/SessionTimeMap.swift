// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Maps speech analyzer time back to session time. The analyzer is fed buffers with no explicit start time
/// (an explicit one fails with SFSpeechErrorDomain Code=17), so its time is the running length of the audio fed to it:
/// 0 at the first buffer, and a gap in the source (dropped buffers) does not advance it.
/// Each buffer's session time is compared with where the analyzer clock says it should be; a jump of more than
/// `gapThreshold` starts a new segment with its own offset, so a long gap does not skew everything after it.
public struct SessionTimeMap: Sendable {
    private var anchors: [(analyzer: TimeInterval, offset: TimeInterval)] = []
    private var fed: TimeInterval = 0
    public static let gapThreshold: TimeInterval = 1
    private static let anchorLimit = 1024

    public init() {}

    /// Records one buffer about to be fed: its session time (may be non-finite) and its duration in seconds.
    public mutating func append(sessionTime: TimeInterval, duration: TimeInterval) {
        let offset = sessionTime.isFinite ? sessionTime - fed : nil
        if let last = anchors.last {
            if let offset, abs(offset - last.offset) > Self.gapThreshold {
                anchors.append((fed, offset))
                if anchors.count > Self.anchorLimit { anchors.removeFirst(Self.anchorLimit / 2) }
            }
        } else {
            anchors.append((0, offset ?? 0))
        }
        if duration.isFinite, duration > 0 { fed += duration }
    }

    public func sessionTime(forAnalyzerTime t: TimeInterval) -> TimeInterval {
        let anchor = anchors.last { $0.analyzer <= t } ?? anchors.first
        return t + (anchor?.offset ?? 0)
    }
}
