// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs real child processes for `ProcessRunning`. Every live process is tracked so `terminateAll()` can stop them on quit.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func launch(executable: String, arguments: [String], workingDirectory: URL, environment: [String: String], stdin: Data) throws -> any ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        // A process that exits early must not kill the app with SIGPIPE when we write its input.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let handle = SystemProcessHandle(process: process)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; continuation.finish() } else { continuation.yield(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { handle.appendStderr(d) }
        }
        process.terminationHandler = { p in handle.finished(status: p.terminationStatus) }
        handle.output = stream
        try process.run()
        SystemProcessHandle.track(handle)
        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? inPipe.fileHandleForWriting.close()
        return handle
    }

    /// Stops every process this runner started that is still running (app quit).
    public static func terminateAll() { SystemProcessHandle.terminateAll() }
}

private final class SystemProcessHandle: ProcessHandle, @unchecked Sendable {
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: SystemProcessHandle] = [:]
    static func track(_ h: SystemProcessHandle) { liveLock.withLock { live[ObjectIdentifier(h)] = h } }
    static func untrack(_ h: SystemProcessHandle) { _ = liveLock.withLock { live.removeValue(forKey: ObjectIdentifier(h)) } }
    static func terminateAll() { liveLock.withLock { Array(live.values) }.forEach { $0.terminate() } }

    private static let stderrCap = 8 * 1024
    private let process: Process
    private let lock = NSLock()
    private var stderr = Data()
    private var exit: ProcessExit?
    private var waiters: [CheckedContinuation<ProcessExit, Never>] = []
    var output: AsyncStream<Data> = AsyncStream { $0.finish() }

    init(process: Process) { self.process = process }

    func appendStderr(_ d: Data) {
        lock.withLock { stderr.append(d); if stderr.count > Self.stderrCap { stderr = stderr.suffix(Self.stderrCap) } }
    }

    func finished(status: Int32) {
        let (result, pending): (ProcessExit, [CheckedContinuation<ProcessExit, Never>]) = lock.withLock {
            let r = ProcessExit(status: status, stderr: String(decoding: stderr, as: UTF8.self))
            exit = r
            defer { waiters = [] }
            return (r, waiters)
        }
        Self.untrack(self)
        pending.forEach { $0.resume(returning: result) }
    }

    func wait() async -> ProcessExit {
        await withCheckedContinuation { cont in
            let done: ProcessExit? = lock.withLock {
                if let exit { return exit }
                waiters.append(cont); return nil
            }
            if let done { cont.resume(returning: done) }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in if process.isRunning { kill(pid, SIGKILL) } }
    }
}
