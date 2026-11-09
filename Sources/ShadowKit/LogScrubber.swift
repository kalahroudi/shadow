// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Removes anything personal or secret from a log line before it is written (R4).
public enum LogScrubber {
    public static func scrub(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var out = text
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        if user.count > 2 { out = out.replacingOccurrences(of: user, with: "<user>") }
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// Wraps prompt or answer text so `scrub` removes it wherever it ends up. Prefer never logging it at all (R13).
    public static func mark(prompt text: String) -> String { "\u{27E6}prompt\u{27E7}\(text)\u{27E6}/prompt\u{27E7}" }
    public static func mark(answer text: String) -> String { "\u{27E6}answer\u{27E7}\(text)\u{27E6}/answer\u{27E7}" }

    private static let rules: [(String, String)] = [
        // prompt and answer text (R13): marked spans, and `prompt:` / `answer:` style fields up to the end of the line
        ("(?s)\\x{27E6}(prompt|answer)\\x{27E7}.*?\\x{27E6}/\\1\\x{27E7}", "<$1 removed>"),
        ("(?i)\\b(system[_ ]?prompt|prompt|answer|question)(\"?\\s*[=:]\\s*).*", "$1$2<removed>"),
        // credentials inside URLs: scheme://user:pass@host
        ("(?i)([a-z][a-z0-9+.-]*://)[^/\\s:@]+:[^/\\s@]+@", "$1<redacted>@"),
        ("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
        // key=value / key: value for secret-looking keys
        ("(?i)\\b(api[_-]?key|token|secret|password|passwd|authorization)(\"?\\s*[=:]\\s*\"?)[^\\s\"&,;]+", "$1$2<redacted>"),
        // well-known token shapes
        ("\\b(sk|pk|ghp|gho|ghs|xox[a-z])[-_][A-Za-z0-9_-]{10,}", "<redacted>"),
        // Gemini keys: AIza + 35 url-safe characters
        ("\\bAIza[A-Za-z0-9_-]{20,}", "<redacted>"),
        ("\\bAKIA[0-9A-Z]{16}\\b", "<redacted>"),
        ("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*", "<redacted>"),
        ("(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", "<email>"),
    ].map { ($0.0, $0.1) }
}
