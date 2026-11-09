// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Parses the Claude CLI's `--output-format stream-json` lines into text deltas (R4). One JSON object per line.
/// With `--include-partial-messages` the text arrives as `stream_event` deltas; the later whole `assistant` message
/// repeats it and is only used when no delta was seen. Malformed or truncated lines are skipped, never fatal.
public struct StreamJSONParser: Sendable {
    public enum Event: Equatable, Sendable {
        case text(String)
        /// The CLI reported a failed run; `message` is technical and must be classified before showing.
        case error(String)
    }

    private var lines: LineBuffer
    public private(set) var sawResult = false
    public private(set) var emittedText = false
    private var sawDelta = false

    public init(maxLineBytes: Int = LineBuffer.defaultMaxLineBytes) { lines = LineBuffer(maxLineBytes: maxLineBytes) }

    public mutating func feed(_ data: Data) -> [Event] {
        var events: [Event] = []
        for line in lines.feed(data) { handle(line, into: &events) }
        return events
    }

    public mutating func finish() -> [Event] {
        var events: [Event] = []
        if let last = lines.finish() { handle(last, into: &events) }
        return events
    }

    private mutating func handle(_ line: String, into events: inout [Event]) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return }
            sawDelta = true; emittedText = true
            events.append(.text(text))
        case "assistant":
            guard !sawDelta, let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { emittedText = true; events.append(.text(text)) }
        case "result":
            sawResult = true
            let result = obj["result"] as? String ?? ""
            if obj["is_error"] as? Bool == true || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
                events.append(.error(result.isEmpty ? (obj["subtype"] as? String ?? "error") : result))
            } else if !emittedText, !result.isEmpty {
                emittedText = true; events.append(.text(result))
            }
        default: return
        }
    }
}
