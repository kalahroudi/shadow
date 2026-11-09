// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct HTTPStream: Sendable {
    public let status: Int
    /// Raw body chunks; finishes at end of body. Cancelling the consumer cancels the request.
    public let body: AsyncThrowingStream<Data, Error>
    public init(status: Int, body: AsyncThrowingStream<Data, Error>) { self.status = status; self.body = body }
}

/// The network seam for providers: fakes in tests, `URLSessionTransport` in the app.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (data: Data, status: Int)
    func stream(for request: URLRequest) async throws -> HTTPStream
}

/// Refuses every redirect, so a request validated as loopback can never be sent elsewhere (R3, R6).
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let delegate = NoRedirect()

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    public func data(for request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request, delegate: delegate)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func stream(for request: URLRequest) async throws -> HTTPStream {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4096 { continuation.yield(chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStream(status: status, body: body)
    }
}
