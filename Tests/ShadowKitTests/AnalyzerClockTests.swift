import XCTest
@testable import ShadowKit

final class AnalyzerClockTests: XCTestCase {
    private let rates: [Double] = [16_000, 44_100, 48_000]

    func testOverlapBackwardsAndDuplicateNeverOverlap() {
        for rate in rates {
            var clock = AnalyzerClock()
            let frames = Int(rate * 0.1)
            let duration = Double(frames) / rate
            var prev: TimeInterval?
            for t in [0.0, 0.05, 0.02, 0.02, 0.5, 0.45, 0.45, 0.46, 0.3] {
                let s = clock.start(sessionTime: t, frames: frames, sampleRate: rate)
                if let prev { XCTAssertGreaterThanOrEqual(s, prev + duration - 1e-9, "rate \(rate) t \(t)") }
                prev = s
            }
        }
    }

    func testLargeForwardGapUsesSessionTime() {
        for rate in rates {
            var clock = AnalyzerClock()
            _ = clock.start(sessionTime: 1, frames: Int(rate), sampleRate: rate)
            XCTAssertEqual(clock.start(sessionTime: 31, frames: 100, sampleRate: rate), 31)
        }
    }

    func testFirstBufferUsesSessionTime() {
        var clock = AnalyzerClock()
        XCTAssertEqual(clock.start(sessionTime: 12.5, frames: 480, sampleRate: 48_000), 12.5)
    }

    func testZeroLengthBufferDoesNotAdvanceOrGoBackwards() {
        for rate in rates {
            var clock = AnalyzerClock()
            let a = clock.start(sessionTime: 2, frames: Int(rate), sampleRate: rate)   // ends at 3
            let z = clock.start(sessionTime: 2.5, frames: 0, sampleRate: rate)
            XCTAssertGreaterThanOrEqual(z, a)
            let b = clock.start(sessionTime: 2.5, frames: 10, sampleRate: rate)
            XCTAssertEqual(b, 3, accuracy: 1e-9)
        }
    }

    func testNonFiniteTimeFallsBackToPreviousEnd() {
        var clock = AnalyzerClock()
        _ = clock.start(sessionTime: 1, frames: 48_000, sampleRate: 48_000)
        XCTAssertEqual(clock.start(sessionTime: .nan, frames: 10, sampleRate: 48_000), 2, accuracy: 1e-9)
    }

    func testResultsMapBackToSessionTimeWithin100ms() {
        for rate in rates {
            var clock = AnalyzerClock()
            let frames = Int(rate * 0.1)
            var rng = SystemRandomNumberGenerator()
            var audio = 0.0          // true session time of each buffer's first sample
            var checks: [(analyzer: TimeInterval, truth: TimeInterval)] = []
            for _ in 0..<300 {
                let jitter = Double.random(in: -0.04...0.04, using: &rng)
                let s = clock.start(sessionTime: audio + jitter, frames: frames, sampleRate: rate)
                checks.append((s + 0.05, audio + 0.05))
                audio += 0.1
            }
            for c in checks {
                XCTAssertEqual(clock.sessionTime(forAnalyzerTime: c.analyzer), c.truth, accuracy: 0.1)
            }
        }
    }

    func testClocksAreIndependent() {
        var a = AnalyzerClock(), b = AnalyzerClock()
        _ = a.start(sessionTime: 10, frames: 48_000, sampleRate: 48_000)   // a ends at 11
        XCTAssertEqual(b.start(sessionTime: 0, frames: 48_000, sampleRate: 48_000), 0)
        XCTAssertEqual(a.start(sessionTime: 5, frames: 10, sampleRate: 48_000), 11, accuracy: 1e-9)
        XCTAssertEqual(b.start(sessionTime: 0.5, frames: 10, sampleRate: 48_000), 1, accuracy: 1e-9)
    }

    /// CMTime rounds to 1/48000; at 44.1 kHz buffer ends fall between ticks and must not round back into the previous buffer.
    func testStartsSurviveCMTimeRoundingWithoutOverlap() {
        var clock = AnalyzerClock()
        let rate = 44_100.0, frames = 1000
        var prevEnd = -Double.infinity
        for i in 0..<2000 {
            let s = clock.start(sessionTime: Double(i) * 0.02, frames: frames, sampleRate: rate)
            let ticks = (s * AnalyzerClock.timescale).rounded()
            XCTAssertGreaterThanOrEqual(ticks / AnalyzerClock.timescale, prevEnd - 1e-12, "buffer \(i)")
            prevEnd = ticks / AnalyzerClock.timescale + Double(frames) / rate
        }
    }
}
