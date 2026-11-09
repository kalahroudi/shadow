// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Network access for updates (R17). Everything goes through here so tests can fake it.
public protocol UpdateTransport: Sendable {
    /// GET a small document. Returns the body and HTTP status; does not throw on non-2xx.
    func get(_ url: URL) async throws -> (data: Data, status: Int)
    /// Stream a file to `destination` in chunks. `progress` is 0...1 and never decreases. Returns the HTTP status.
    func download(_ url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> Int
}

/// The only hosts Shadow talks to for updates.
public enum UpdateHosts {
    /// Hosts a request may start at.
    public static let origins: Set<String> = ["api.github.com", "github.com"]
    /// Hosts a release download may be redirected to.
    public static let redirectTargets: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    public static func allowsRequest(_ url: URL) -> Bool {
        url.scheme == "https" && url.host.map { origins.contains($0.lowercased()) } == true
    }
    public static func allowsRedirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.host.map { redirectTargets.contains($0.lowercased()) } == true
    }
}

public enum UpdateRequest {
    /// A plain, unauthenticated GET whose only custom header is `User-Agent: Shadow/<version>`.
    public static func make(_ url: URL, appVersion: String) throws -> URLRequest {
        guard UpdateHosts.allowsRequest(url) else { throw UpdateError(.badRelease, detail: "blocked host") }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Shadow/\(appVersion)", forHTTPHeaderField: "User-Agent")
        return r
    }
}

/// Follows redirects only to allowlisted hosts; anything else is refused and remembered.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _refused = false
    var refused: Bool { lock.withLock { _refused } }

    func decide(_ request: URLRequest) -> URLRequest? {
        if let url = request.url, UpdateHosts.allowsRedirect(url) { return request }
        lock.withLock { _refused = true }
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { decide(request) }
}

/// The real transport: ephemeral session, no cookies, cache or credentials.
public struct GitHubTransport: UpdateTransport {
    private let appVersion: String
    public init(appVersion: String) { self.appVersion = appVersion }

    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let request = try UpdateRequest.make(url, appVersion: appVersion)
        let guardian = RedirectGuard()
        let session = makeSession(); defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: guardian)
        if guardian.refused { throw UpdateError(.badRelease, detail: "redirect to a host that is not allowed") }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func download(_ url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> Int {
        let request = try UpdateRequest.make(url, appVersion: appVersion)
        let guardian = RedirectGuard()
        let session = makeSession(); defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
        if guardian.refused { throw UpdateError(.badRelease, detail: "redirect to a host that is not allowed") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return status }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let total = response.expectedContentLength
        var chunk = Data(), written: Int64 = 0, last = 0.0
        chunk.reserveCapacity(Self.chunkSize)
        func flush() throws {
            guard !chunk.isEmpty else { return }
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count); chunk.removeAll(keepingCapacity: true)
            if total > 0 { last = max(last, min(1, Double(written) / Double(total))); progress(last) }
        }
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= Self.chunkSize { try flush() }
            }
            try flush()
        } catch { try? fm.removeItem(at: destination); throw error }
        progress(1)
        return status
    }

    static let chunkSize = 64 * 1024
}
