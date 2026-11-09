// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SessionStatus: String, Codable, Sendable { case idle, running, busy, error, interrupted }

/// Small, always-in-memory description of a session (what the sidebar needs). The heavy content is a separate payload file.
public struct SessionMeta: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var status: SessionStatus
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String, status: SessionStatus = .idle, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SessionIndex: Codable, Equatable, Sendable {
    public var sessions: [SessionMeta] = []
    public var selected: UUID?
    public init() {}
}

/// Crash-safe persistence for sessions. Rules:
/// - every write is atomic (temp file + rename), so a crash mid-write leaves the old file intact;
/// - the index keeps a `.bak` of the previous good version; an unreadable file is quarantined (`.corrupt`), never deleted;
/// - a `running.lock` exists while the app runs; finding it at launch means the last run ended without a clean quit;
/// - sessions that were running/busy at that moment come back as `.interrupted`, never as "running" with nothing behind them;
/// - only the index is loaded at launch; a payload is read on demand and not kept when the session is not on screen.
public final class SessionStore: @unchecked Sendable {
    public struct Loaded: Sendable { public var index: SessionIndex; public var recoveredFromCrash: Bool; public var quarantined: [String] }

    private let dir: URL
    private let lock = NSLock()
    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private var lockURL: URL { dir.appendingPathComponent("running.lock") }
    private func payloadURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).payload") }

    public init(directory: URL) { dir = directory }

    /// Call once at launch, before any UI. Marks the app as running.
    public func load() -> Loaded {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crashed = FileManager.default.fileExists(atPath: lockURL.path)
        var quarantined: [String] = []
        var index = readIndex(indexURL, quarantined: &quarantined)
            ?? readIndex(indexURL.appendingPathExtension("bak"), quarantined: &quarantined)
            ?? SessionIndex()
        if crashed {
            for i in index.sessions.indices where [.running, .busy].contains(index.sessions[i].status) { index.sessions[i].status = .interrupted }
        }
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        return Loaded(index: index, recoveredFromCrash: crashed && !index.sessions.isEmpty, quarantined: quarantined)
    }

    private func readIndex(_ url: URL, quarantined: inout [String]) -> SessionIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let i = try? dec.decode(SessionIndex.self, from: data) { return i }
        let bad = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        quarantined.append(bad.lastPathComponent)
        return nil
    }

    public func saveIndex(_ index: SessionIndex) throws {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(index)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let bak = indexURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: indexURL, to: bak)
        }
        try data.write(to: indexURL, options: .atomic)
    }

    public func writePayload(_ id: UUID, _ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try data.write(to: payloadURL(id), options: .atomic)
    }

    public func readPayload(_ id: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: payloadURL(id))
    }

    public func deletePayload(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: payloadURL(id))
    }

    /// Call from `applicationWillTerminate` after the final flush.
    public func markCleanShutdown() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: lockURL)
    }
}
