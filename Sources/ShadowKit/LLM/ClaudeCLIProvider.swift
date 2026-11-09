// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ProcessExit: Sendable, Equatable {
    public var status: Int32
    /// The tail of stderr, capped. Technical: never shown as-is.
    public var stderr: String
    public init(status: Int32, stderr: String = "") { self.status = status; self.stderr = stderr }
}

/// A running child process, as far as a provider needs to see it.
public protocol ProcessHandle: Sendable {
    /// Standard output chunks; finishes when the process closes its output.
    var output: AsyncStream<Data> { get }
    /// Stops the process (SIGTERM, then SIGKILL if it lingers). Safe to call more than once.
    func terminate()
    func wait() async -> ProcessExit
}

/// The process seam for providers: a fake in tests, `SystemProcessRunner` in the app.
public protocol ProcessRunning: Sendable {
    func launch(executable: String, arguments: [String], workingDirectory: URL, environment: [String: String], stdin: Data) throws -> any ProcessHandle
}

/// Answers through the user's own `claude` CLI and its login (R4): print mode, no tools, no MCP, a throwaway working directory.
public struct ClaudeCLIProvider: LLMProvider {
    public static let providerID = "claudeCLI"
    public static let installGuidance = "The Claude CLI wasn't found. Install it from claude.com/claude-code, then run `claude` once in Terminal to sign in."

    /// Everything the CLI could use to act on the machine is switched off: tools, MCP servers, slash commands, settings, session files.
    public static func arguments(system: String, model: String) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
                    "--no-session-persistence", "--system-prompt", system]
        if !model.isEmpty { args += ["--model", model] }
        return args
    }

    private let runner: any ProcessRunning
    private let find: @Sendable (String) -> String?
    private let timeout: Duration
    private let tempRoot: URL

    public init(runner: any ProcessRunning = SystemProcessRunner(), find: @escaping @Sendable (String) -> String? = { Shell.find($0) },
                timeout: Duration = .seconds(120), tempRoot: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner; self.find = find; self.timeout = timeout; self.tempRoot = tempRoot
    }

    public var id: String { Self.providerID }
    public var isCloud: Bool { false }

    public func availability() async -> ProviderStatus { find("claude") == nil ? .unavailable(Self.installGuidance) : .ready }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        let (runner, find, timeout, tempRoot) = (runner, find, timeout, tempRoot)
        return LLMStream.make { out in
            guard let path = find("claude") else { throw UserFacingError(Self.installGuidance) }
            let dir = tempRoot.appendingPathComponent("shadow-claude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let handle = try runner.launch(executable: path, arguments: Self.arguments(system: request.system, model: request.model),
                                           workingDirectory: dir, environment: Shell.environment, stdin: Data(request.user.utf8))
            let timedOut = Flag()
            let watchdog = Task { try await Task.sleep(for: timeout); timedOut.set(); handle.terminate() }
            defer { watchdog.cancel() }

            var parser = StreamJSONParser()
            var failure: String?
            func deliver(_ events: [StreamJSONParser.Event]) {
                for event in events {
                    switch event {
                    case .text(let t): out.yield(t)
                    case .error(let m): failure = failure ?? m
                    }
                }
            }
            await withTaskCancellationHandler {
                for await chunk in handle.output { deliver(parser.feed(chunk)) }
            } onCancel: { handle.terminate() }
            try Task.checkCancellation()
            deliver(parser.finish())
            let exit = await handle.wait()

            if timedOut.value { throw LLMError(.offline, detail: "claude timed out") }
            if let failure { throw Self.classify(failure) }
            if exit.status != 0, !parser.emittedText { throw Self.classify(exit.stderr, status: exit.status) }
            // A run cut short after some text keeps that text; one with no text at all is a failure.
            if !parser.sawResult, !parser.emittedText { throw LLMError(.unavailable, detail: "claude ended without an answer (status \(exit.status))") }
        }
    }

    static func classify(_ text: String, status: Int32 = 0) -> Error {
        let t = text.lowercased()
        if t.contains("/login") || t.contains("log in") || t.contains("not logged in") || t.contains("authenticat") || t.contains("invalid api key") {
            return UserFacingError("The Claude CLI isn't signed in. Run `claude` in Terminal and sign in, then try again.")
        }
        if t.contains("rate limit") || t.contains("usage limit") || t.contains("overloaded") { return LLMError(.rateLimited, detail: "claude: \(String(text.prefix(200)))") }
        return LLMError(.unavailable, detail: "claude status \(status): \(String(text.prefix(200)))")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
