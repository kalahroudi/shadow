// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Speaker: String, Sendable, Codable, Equatable { case them, you }

public struct Segment: Sendable, Codable, Equatable {
    public var speaker: Speaker
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var locale: String
    public var confidence: Double
    public var isFinal: Bool

    public init(speaker: Speaker, text: String, start: TimeInterval, end: TimeInterval,
                locale: String = "en-US", confidence: Double = 1, isFinal: Bool) {
        self.speaker = speaker; self.text = text; self.start = start; self.end = end
        self.locale = locale; self.confidence = confidence; self.isFinal = isFinal
    }
}

/// What the UI observes: ordered finals plus at most one live partial per speaker.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var finals: [Segment] = []
    public var partials: [Speaker: Segment] = [:]
    public init() {}

    /// Finals followed by partials, ordered by start time.
    public var lines: [Segment] { (finals + partials.values).sorted { $0.start < $1.start } }
}

/// Merges partials into finals (R12). A new final replaces that speaker's partial; the oldest finals drop past the cap.
public actor Transcript {
    public static let defaultCap = 2_000

    private let cap: Int
    private var state = TranscriptSnapshot()
    private var observers: [UUID: AsyncStream<TranscriptSnapshot>.Continuation] = [:]

    public init(cap: Int = Transcript.defaultCap) { self.cap = max(1, cap) }

    public var snapshot: TranscriptSnapshot { state }

    public func add(_ segment: Segment) {
        if segment.isFinal {
            state.partials[segment.speaker] = nil
            let at = state.finals.firstIndex { $0.start > segment.start } ?? state.finals.endIndex
            state.finals.insert(segment, at: at)
            if state.finals.count > cap { state.finals.removeFirst(state.finals.count - cap) }
        } else {
            state.partials[segment.speaker] = segment
        }
        publish()
    }

    /// Turns pending partials into finals, used on Stop.
    public func flushPartials() {
        let pending = state.partials.values.sorted { $0.start < $1.start }
        guard !pending.isEmpty else { return }
        state.partials = [:]
        for var p in pending {
            p.isFinal = true
            let at = state.finals.firstIndex { $0.start > p.start } ?? state.finals.endIndex
            state.finals.insert(p, at: at)
        }
        if state.finals.count > cap { state.finals.removeFirst(state.finals.count - cap) }
        publish()
    }

    /// Turns one speaker's pending partial into a final, used when that speaker's recogniser restarts.
    public func flushPartial(for speaker: Speaker) {
        guard var p = state.partials.removeValue(forKey: speaker) else { return }
        p.isFinal = true
        let at = state.finals.firstIndex { $0.start > p.start } ?? state.finals.endIndex
        state.finals.insert(p, at: at)
        if state.finals.count > cap { state.finals.removeFirst(state.finals.count - cap) }
        publish()
    }

    /// Clears everything for a new session.
    public func reset() { state = TranscriptSnapshot(); publish() }

    /// Emits the current state immediately, then one value per change.
    public func updates() -> AsyncStream<TranscriptSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(state)
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() { for c in observers.values { c.yield(state) } }
}

/// Plain text for the copy-transcript action.
public enum TranscriptFormatter {
    public static func text(_ lines: [Segment]) -> String {
        lines.filter { !$0.text.isEmpty }
            .map { "\($0.speaker == .them ? "Them" : "You"): \($0.text)" }
            .joined(separator: "\n")
    }
}
