// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One answer shown during a session (R20). Text only: the question, the answer and which provider made it; never a key.
public struct AnswerRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var question: String
    public var text: String
    public var persona: String
    public var provider: String
    public var model: String
    /// How it was made: "answer", "shorter", "metric", "followUp" or "language".
    public var kind: String
    public var latencyMs: Int?

    public init(id: UUID = UUID(), createdAt: Date = Date(), question: String, text: String, persona: String,
                provider: String, model: String, kind: String = "answer", latencyMs: Int? = nil) {
        self.id = id; self.createdAt = createdAt; self.question = question; self.text = text; self.persona = persona
        self.provider = provider; self.model = model; self.kind = kind; self.latencyMs = latencyMs
    }
}

/// One saved session: the full transcript plus when it ran (R21). `version` lets later milestones migrate the format (2 adds answer history).
public struct SessionRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version: Int
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var segments: [Segment]
    /// Added in version 2. Absent in v1 files, which still load.
    public var answers: [AnswerRecord]?

    public init(id: UUID, startedAt: Date, endedAt: Date? = nil, segments: [Segment] = [], answers: [AnswerRecord]? = nil,
                version: Int = SessionRecord.currentVersion) {
        self.version = version; self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.segments = segments
        self.answers = answers
    }
}

/// Crash-safe persistence for sessions. Rules:
/// - one JSON file per session under the sessions folder, written atomically (temp file + rename);
/// - `running.lock` holds the id of the running session and is removed on clean stop;
/// - finding the lock at launch means the last exit was unclean: the checkpointed transcript is offered back;
/// - an unreadable session file is renamed `.corrupt`, never deleted;
/// - only text is stored. Audio never touches the disk.
public final class SessionStore: @unchecked Sendable {
    /// What launch found. `interrupted` is the transcript of a session that did not stop cleanly, if it is readable.
    public struct LaunchCheck: Sendable, Equatable {
        public var interrupted: SessionRecord?
        public var quarantined: [String]
    }

    private let dir: URL
    private let lock = NSLock()
    private var lockURL: URL { dir.appendingPathComponent("running.lock") }

    public init(directory: URL) { dir = directory }

    public func fileURL(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    public var hasRunningLock: Bool { FileManager.default.fileExists(atPath: lockURL.path) }

    /// Call once at launch. A leftover lock is cleared once its session has been read or quarantined; the file itself stays.
    public func launchCheck() -> LaunchCheck {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let raw = try? Data(contentsOf: lockURL) else { return LaunchCheck(interrupted: nil, quarantined: []) }
        defer { try? FileManager.default.removeItem(at: lockURL) }
        guard let id = UUID(uuidString: String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return LaunchCheck(interrupted: nil, quarantined: [])
        }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return LaunchCheck(interrupted: nil, quarantined: []) }
        if let record = try? Self.decoder.decode(SessionRecord.self, from: data) {
            return LaunchCheck(interrupted: record, quarantined: [])
        }
        let bad = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        return LaunchCheck(interrupted: nil, quarantined: [bad.lastPathComponent])
    }

    /// Marks a session as running.
    public func begin(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: lockURL, options: .atomic)
    }

    /// Atomic write of the record. A failure leaves any earlier file intact and no partial file behind.
    public func write(_ record: SessionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    public func read(_ id: UUID) -> SessionRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(SessionRecord.self, from: data)
    }

    /// Call after a clean stop.
    public func end() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: lockURL)
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e }
    private static var decoder: JSONDecoder { JSONDecoder() }
}
