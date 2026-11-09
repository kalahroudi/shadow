import XCTest
@testable import ShadowKit

/// R4 / A4.
private func cliChunks(_ s: String) -> [Data] { [Data(s.utf8)] }

final class ClaudeCLIProviderTests: XCTestCase {
    private let req = LLMRequest(system: "SYSTEM TEXT", user: "USER TEXT", model: "")
    private var tempRoot: URL!

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tempRoot) }

    private func provider(_ runner: FakeProcessRunner, find: @escaping @Sendable (String) -> String? = { _ in "/fake/claude" },
                          timeout: Duration = .seconds(30)) -> ClaudeCLIProvider {
        ClaudeCLIProvider(runner: runner, find: find, timeout: timeout, tempRoot: tempRoot)
    }
    private var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? [] }

    func testMissingCLIIsUnavailableWithInstallGuidanceAndNothingRuns() async {
        let runner = FakeProcessRunner { FakeProcess(chunks: []) }
        let p = provider(runner, find: { _ in nil })
        let status = await p.availability()
        XCTAssertEqual(status, .unavailable(ClaudeCLIProvider.installGuidance))
        XCTAssertTrue(ClaudeCLIProvider.installGuidance.contains("Install"))
        do { _ = try await collect(p.stream(req)); XCTFail() }
        catch { XCTAssertEqual(UserError.message(for: error, action: "answer"), ClaudeCLIProvider.installGuidance) }
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testFindsClaudeThroughTheShellPathResolution() async {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [String] = []
            func add(_ t: String) { lock.withLock { list.append(t) } }
            var tools: [String] { lock.withLock { list } }
        }
        let asked = Asked()
        let p = ClaudeCLIProvider(runner: FakeProcessRunner { FakeProcess(chunks: []) }, find: { tool in asked.add(tool); return nil }, tempRoot: tempRoot)
        _ = await p.availability()
        XCTAssertEqual(asked.tools, ["claude"])
        // The default resolver is Shell.find.
        let d = ClaudeCLIProvider()
        let found = Shell.find("claude") != nil
        let status = await d.availability()
        XCTAssertEqual(status.isReady, found)
    }

    func testNormalRunStreamsDeltasInATempDirWithNoToolsAndPromptOnStdin() async throws {
        let runner = FakeProcessRunner { FakeProcess(chunks: cliChunks(LLMFixtures.cliNormal)) }
        let got = try await collect(provider(runner).stream(req))
        XCTAssertEqual(got, ["2+2 is", " 4."])

        let l = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(l.executable, "/fake/claude")
        XCTAssertEqual(l.arguments.prefix(4), ["-p", "--output-format", "stream-json", "--verbose"])
        let toolsAt = try XCTUnwrap(l.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(l.arguments[toolsAt + 1], "", "tools are switched off, not just unlisted")
        XCTAssertTrue(l.arguments.contains("--strict-mcp-config"))
        let flags = Set(l.arguments.filter { $0.hasPrefix("--") })
        XCTAssertEqual(flags, ["--output-format", "--verbose", "--include-partial-messages", "--tools", "--strict-mcp-config",
                               "--disable-slash-commands", "--setting-sources", "--no-session-persistence", "--system-prompt"],
                       "no tool, permission, MCP or directory flags beyond the locked-down set")
        XCTAssertFalse(l.arguments.contains("--model"))
        XCTAssertEqual(l.arguments[try XCTUnwrap(l.arguments.firstIndex(of: "--system-prompt")) + 1], "SYSTEM TEXT")
        XCTAssertEqual(String(decoding: l.stdin, as: UTF8.self), "USER TEXT")
        XCTAssertFalse(l.arguments.contains("USER TEXT"), "the conversation never goes on the command line")

        XCTAssertEqual(l.workingDirectory.deletingLastPathComponent().standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertTrue(l.dirExistedAtLaunch)
        XCTAssertTrue(leftovers.isEmpty, "temp directory is removed afterwards")
    }

    func testModelIsPassedWhenChosen() async throws {
        let runner = FakeProcessRunner { FakeProcess(chunks: cliChunks(LLMFixtures.cliNormal)) }
        _ = try await collect(provider(runner).stream(LLMRequest(system: "s", user: "u", model: "sonnet")))
        let a = try XCTUnwrap(runner.launches.first).arguments
        XCTAssertEqual(a[try XCTUnwrap(a.firstIndex(of: "--model")) + 1], "sonnet")
    }

    func testCancellingKillsTheProcessAndCleansUp() async throws {
        let runner = FakeProcessRunner { FakeProcess(chunks: cliChunks(LLMFixtures.cliInit + LLMFixtures.cliDelta("a")), keepOpen: true) }
        let p = provider(runner), r = req
        let task = Task { try await collect(p.stream(r)) }
        let started = await eventually { runner.processes.count == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result
        let killed = await eventually { (runner.processes.first?.terminations ?? 0) >= 1 }
        XCTAssertTrue(killed)
        let clean = await eventually { leftovers.isEmpty }
        XCTAssertTrue(clean)
    }

    func testTruncatedRunWithTextKeepsTheTextWithoutAnError() async throws {
        let cut = LLMFixtures.cliInit + LLMFixtures.cliDelta("Partial") + String(LLMFixtures.cliDelta(" more").dropLast(30))
        let runner = FakeProcessRunner { FakeProcess(chunks: cliChunks(cut), exit: ProcessExit(status: 143)) }
        let got = try await collect(provider(runner).stream(req))
        XCTAssertEqual(got, ["Partial"])
    }

    func testRunWithNoOutputIsAnError() async {
        let runner = FakeProcessRunner { FakeProcess(chunks: cliChunks(LLMFixtures.cliInit), exit: ProcessExit(status: 1, stderr: "boom")) }
        do { _ = try await collect(provider(runner).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .unavailable) }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testErrorLineMapsToAFriendlyMessage() async {
        let signedOut = LLMFixtures.cliInit + LLMFixtures.cliResult("Invalid API key · Please run /login", isError: true)
        do { _ = try await collect(provider(FakeProcessRunner { FakeProcess(chunks: cliChunks(signedOut)) }).stream(req)); XCTFail() }
        catch { XCTAssertTrue(UserError.message(for: error, action: "answer").contains("isn't signed in")) }

        let limited = LLMFixtures.cliInit + LLMFixtures.cliResult("Usage limit reached", isError: true)
        do { _ = try await collect(provider(FakeProcessRunner { FakeProcess(chunks: cliChunks(limited)) }).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .rateLimited) }
    }

    func testAHangingProcessIsKilledAtTheTimeout() async {
        let runner = FakeProcessRunner { FakeProcess(chunks: [], keepOpen: true) }
        do { _ = try await collect(provider(runner, timeout: .milliseconds(80)).stream(req)); XCTFail() }
        catch { XCTAssertEqual((error as? LLMError)?.kind, .offline) }
        XCTAssertGreaterThanOrEqual(runner.processes.first?.terminations ?? 0, 1)
    }

    func testIsLocalNotCloud() { XCTAssertFalse(ClaudeCLIProvider().isCloud) }
}

/// The real process runner, against harmless system tools.
final class SystemProcessRunnerTests: XCTestCase {
    func testRunsAProcessFeedsStdinAndReportsExit() async throws {
        let h = try SystemProcessRunner().launch(executable: "/bin/cat", arguments: [], workingDirectory: FileManager.default.temporaryDirectory,
                                                  environment: Shell.environment, stdin: Data("hello".utf8))
        var out = Data()
        for await c in h.output { out.append(c) }
        let exit = await h.wait()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello")
        XCTAssertEqual(exit.status, 0)
    }

    func testTerminateStopsALongRunningProcess() async throws {
        let h = try SystemProcessRunner().launch(executable: "/bin/sleep", arguments: ["30"], workingDirectory: FileManager.default.temporaryDirectory,
                                                  environment: Shell.environment, stdin: Data())
        let started = Date()
        h.terminate()
        let exit = await h.wait()
        XCTAssertNotEqual(exit.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        for await _ in h.output {}
    }

    func testTerminateAllStopsLiveProcesses() async throws {
        let h = try SystemProcessRunner().launch(executable: "/bin/sleep", arguments: ["30"], workingDirectory: FileManager.default.temporaryDirectory,
                                                  environment: Shell.environment, stdin: Data())
        SystemProcessRunner.terminateAll()
        let exit = await h.wait()
        XCTAssertNotEqual(exit.status, 0)
    }
}
