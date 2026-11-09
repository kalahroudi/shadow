import Foundation
@testable import ShadowKit

/// Scripted deltas, with a counter for the cancel hook. `delayBetween` lets a test cancel mid-stream.
final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let isCloud: Bool
    var status: ProviderStatus = .ready
    private let deltas: [String]
    private let delayBetween: Duration
    private let failure: Error?
    private let lock = NSLock()
    private var _cancelCount = 0, _requests: [LLMRequest] = []

    init(id: String = "fake", isCloud: Bool = false, deltas: [String], delayBetween: Duration = .zero, failure: Error? = nil) {
        self.id = id; self.isCloud = isCloud; self.deltas = deltas; self.delayBetween = delayBetween; self.failure = failure
    }

    var cancelCount: Int { lock.withLock { _cancelCount } }
    var requests: [LLMRequest] { lock.withLock { _requests } }

    func availability() async -> ProviderStatus { status }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _requests.append(request) }
        return LLMStream.make(onCancel: { [self] in lock.withLock { _cancelCount += 1 } }) { [deltas, delayBetween, failure] out in
            for d in deltas {
                if delayBetween > .zero { try await Task.sleep(for: delayBetween) }
                out.yield(d)
            }
            if let failure { throw failure }
        }
    }
}

/// Scripted network: `openResults` is consumed one per `stream` call (the last repeats); `dataResults` likewise for `data`.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Open { case ok(status: Int, chunks: [Data], keepOpen: Bool), fail(Error) }
    private let lock = NSLock()
    private var openResults: [Open], dataResults: [Result<(Data, Int), Error>]
    private var _streamRequests: [URLRequest] = [], _dataRequests: [URLRequest] = [], _bodyTerminations = 0

    init(open: [Open] = [], data: [Result<(Data, Int), Error>] = []) { openResults = open; dataResults = data }

    static func sse(_ text: String, status: Int = 200, chunkSize: Int = 7) -> Open {
        let bytes = Array(text.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { Data(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
        return .ok(status: status, chunks: chunks, keepOpen: false)
    }

    var streamRequests: [URLRequest] { lock.withLock { _streamRequests } }
    var dataRequests: [URLRequest] { lock.withLock { _dataRequests } }
    var bodyTerminations: Int { lock.withLock { _bodyTerminations } }
    var callCount: Int { streamRequests.count + dataRequests.count }

    private func next<T>(_ list: inout [T]) -> T? { list.count > 1 ? list.removeFirst() : list.first }

    func data(for request: URLRequest) async throws -> (data: Data, status: Int) {
        let r = lock.withLock { _dataRequests.append(request); return next(&dataResults) }
        guard let r else { throw URLError(.cannotConnectToHost) }
        return try r.get()
    }

    func stream(for request: URLRequest) async throws -> HTTPStream {
        let r = lock.withLock { _streamRequests.append(request); return next(&openResults) }
        switch r {
        case nil: throw URLError(.cannotConnectToHost)
        case .fail(let e): throw e
        case .ok(let status, let chunks, let keepOpen):
            let body = AsyncThrowingStream<Data, Error> { c in
                for chunk in chunks { c.yield(chunk) }
                if !keepOpen { c.finish() }
                c.onTermination = { [self] reason in if case .cancelled = reason { lock.withLock { _bodyTerminations += 1 } } }
            }
            return HTTPStream(status: status, body: body)
        }
    }
}

/// A scripted child process. `keepOpen` keeps the output open until `terminate()`.
final class FakeProcess: ProcessHandle, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let exit: ProcessExit
    private let lock = NSLock()
    private var _terminations = 0

    init(chunks: [Data], keepOpen: Bool = false, exit: ProcessExit = ProcessExit(status: 0)) {
        (output, continuation) = AsyncStream<Data>.makeStream()
        self.exit = exit
        for c in chunks { continuation.yield(c) }
        if !keepOpen { continuation.finish() }
    }

    var terminations: Int { lock.withLock { _terminations } }
    func terminate() { lock.withLock { _terminations += 1 }; continuation.finish() }
    func wait() async -> ProcessExit { exit }
}

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Launch { var executable: String, arguments: [String], workingDirectory: URL, stdin: Data, dirExistedAtLaunch: Bool }
    private let make: @Sendable () -> FakeProcess
    private let lock = NSLock()
    private var _launches: [Launch] = [], _processes: [FakeProcess] = []

    init(_ make: @escaping @Sendable () -> FakeProcess) { self.make = make }

    var launches: [Launch] { lock.withLock { _launches } }
    var processes: [FakeProcess] { lock.withLock { _processes } }

    func launch(executable: String, arguments: [String], workingDirectory: URL, environment: [String: String], stdin: Data) throws -> any ProcessHandle {
        let p = make()
        lock.withLock {
            _launches.append(Launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory, stdin: stdin,
                                    dirExistedAtLaunch: FileManager.default.fileExists(atPath: workingDirectory.path)))
            _processes.append(p)
        }
        return p
    }
}

func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await d in stream { out.append(d) }
    return out
}

/// Waits (briefly) for a condition that another task makes true.
func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }   // cancelled: stop waiting
    }
    return condition()
}

/// Deterministic pseudo-random bytes for fuzzing.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state ^ (state >> 29) }
}
