// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Splits a byte stream into lines without trapping on partial UTF-8, huge lines or garbage (R24).
/// A line longer than `maxLineBytes` is dropped whole, so memory stays bounded.
public struct LineBuffer: Sendable {
    public static let defaultMaxLineBytes = 1 << 20
    private var buffer = Data()
    private var skipping = false
    public private(set) var droppedLines = 0
    let maxLineBytes: Int

    public init(maxLineBytes: Int = defaultMaxLineBytes) { self.maxLineBytes = max(1, maxLineBytes) }

    public mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if skipping { skipping = false; buffer.removeAll(keepingCapacity: true); continue }
                lines.append(Self.decode(buffer)); buffer.removeAll(keepingCapacity: true)
            } else if !skipping {
                buffer.append(byte)
                if buffer.count > maxLineBytes { skipping = true; droppedLines += 1; buffer.removeAll(keepingCapacity: false) }
            }
        }
        return lines
    }

    /// The unterminated last line, if any.
    public mutating func finish() -> String? {
        defer { buffer.removeAll(); skipping = false }
        return buffer.isEmpty || skipping ? nil : Self.decode(buffer)
    }

    private static func decode(_ data: Data) -> String {
        var d = data
        if d.last == 0x0D { d.removeLast() }
        return String(decoding: d, as: UTF8.self)
    }
}

/// An incremental Server-Sent Events parser (R3, R5). Feed it chunks as they arrive; it returns complete events.
public struct SSEParser: Sendable {
    public enum Event: Equatable, Sendable {
        case data(String)
        /// The OpenAI-style `data: [DONE]` terminator.
        case done
    }

    private var lines: LineBuffer
    private var pending: [String] = []

    public init(maxLineBytes: Int = LineBuffer.defaultMaxLineBytes) { lines = LineBuffer(maxLineBytes: maxLineBytes) }

    public mutating func feed(_ data: Data) -> [Event] {
        var events: [Event] = []
        for line in lines.feed(data) { handle(line, into: &events) }
        return events
    }

    public mutating func feed(_ text: String) -> [Event] { feed(Data(text.utf8)) }

    /// Call at end of input: a truncated last event is still delivered (its JSON may then fail to decode, which callers skip).
    public mutating func finish() -> [Event] {
        var events: [Event] = []
        if let last = lines.finish() { handle(last, into: &events) }
        flush(into: &events)
        return events
    }

    private mutating func handle(_ line: String, into events: inout [Event]) {
        if line.isEmpty { flush(into: &events); return }
        if line.hasPrefix(":") { return }   // comment / keep-alive
        guard line.hasPrefix("data:") else { return }   // event:, id:, retry: are not needed
        var value = line.dropFirst(5)
        if value.first == " " { value = value.dropFirst() }
        pending.append(String(value))
    }

    private mutating func flush(into events: inout [Event]) {
        guard !pending.isEmpty else { return }
        let payload = pending.joined(separator: "\n"); pending.removeAll()
        events.append(payload.trimmingCharacters(in: .whitespaces) == "[DONE]" ? .done : .data(payload))
    }
}

/// Pulls the text out of one SSE `data:` JSON payload. Unknown or malformed JSON yields nil.
public enum SSEDelta {
    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// OpenAI, Ollama, mlx_lm.server: `choices[0].delta.content`.
    public static func openAICompatible(_ json: String) -> String? {
        let text = ((((object(json)?["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any])?["content"]) as? String
        return text?.isEmpty == false ? text : nil
    }

    /// An error object carried inside the stream: `{"error": {"message": …}}` or `{"error": "…"}`.
    public static func errorMessage(_ json: String) -> String? {
        guard let e = object(json)?["error"] else { return nil }
        if let s = e as? String { return s }
        if let d = e as? [String: Any] { return (d["message"] as? String) ?? (d["type"] as? String) ?? "error" }
        return "error"
    }
}
