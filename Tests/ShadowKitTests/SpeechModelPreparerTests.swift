import XCTest
@testable import ShadowKit

private final class FakeSpeechAssetService: SpeechAssetService, @unchecked Sendable {
    var supported: Locale?
    var allSupported: [Locale] = []
    /// Consumed one per `status` call; the last value repeats.
    var statuses: [SpeechAssetStatus] = [.needsDownload]
    var steps: [Double] = []
    /// Consumed one per `download` call; nil or missing means success.
    var downloadErrors: [Error?] = []
    private(set) var downloads = 0
    private var statusCalls = 0
    init(supported: Locale? = Locale(identifier: "en-US")) { self.supported = supported }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { supported }
    func supportedLocales() async -> [Locale] { allSupported }
    func status(for locale: Locale) async -> SpeechAssetStatus {
        defer { statusCalls += 1 }
        return statuses[min(statusCalls, statuses.count - 1)]
    }
    func download(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        defer { downloads += 1 }
        for s in steps { progress(s) }
        if downloads < downloadErrors.count, let e = downloadErrors[downloads] { throw e }
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ isError: Bool, _ line: String) { lock.withLock { items.append((isError ? "E " : "I ") + line) } }
    var all: [String] { lock.withLock { items } }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func add(_ v: Double?) { lock.withLock { values.append(v) } }
    var all: [Double?] { lock.withLock { values } }
}

final class SpeechModelPreparerTests: XCTestCase {
    private let locale = Locale(identifier: "en-US")

    func testUnsupportedLocaleThrowsWithoutProgress() async {
        let service = FakeSpeechAssetService(supported: nil)
        let log = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, "Speech recognition doesn't support this language yet. Pick another language.")
        }
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertEqual(service.downloads, 0)
    }

    func testInstalledModelSkipsDownload() async throws {
        let service = FakeSpeechAssetService()
        service.statuses = [.installed]
        let log = ProgressLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add, log: { _, _ in }, sleep: { _ in })
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertEqual(service.downloads, 0)
    }

    func testDownloadReportsProgressAndEndsWithNil() async throws {
        let service = FakeSpeechAssetService()
        service.steps = [0.25, 0.5, 1]
        let log = ProgressLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add, log: { _, _ in }, sleep: { _ in })
        XCTAssertEqual(log.all, [0, 0.25, 0.5, 1, nil])
        XCTAssertEqual(service.downloads, 1)
    }

    func testDownloadFailureThrowsFriendlyMessageAndClearsProgress() async {
        let service = FakeSpeechAssetService()
        service.steps = [0.3]
        service.downloadErrors = Array(repeating: URLError(.badServerResponse), count: 4)
        let log = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, "Couldn't download the speech model. Check your internet connection and try again.")
        }
        XCTAssertEqual(log.all, [0, 0.3, nil])
        XCTAssertEqual(service.downloads, 1, "a non-network error is not retried")
    }

    func testCancellationPassesThroughAndClearsProgress() async {
        let service = FakeSpeechAssetService()
        service.downloadErrors = [CancellationError()]
        let log = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(log.all, [0, nil])
    }

    // MARK: locale normalization, retries, status

    func testLocaleFoundInSupportedListWhenSystemLookupMisses() async throws {
        let service = FakeSpeechAssetService(supported: nil)
        service.allSupported = [Locale(identifier: "de_DE"), Locale(identifier: "en_US")]
        service.statuses = [.installed]
        let lines = LineLog()
        try await SpeechModelPreparer.prepare(locale: Locale(identifier: "en-US"), service: service, onProgress: { _ in }, log: lines.add, sleep: { _ in })
        XCTAssertEqual(lines.all, [
            "I speech prepare [en-us]: start",
            "I speech prepare [en-us]: system lookup found none; list of 2 matched en-us",
            "I speech prepare [en-us]: status installed",
        ])
    }

    func testUnsupportedWhenNeitherLookupNorListMatches() async {
        let service = FakeSpeechAssetService(supported: nil)
        service.allSupported = [Locale(identifier: "de_DE")]
        let lines = LineLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: { _ in }, log: lines.add, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, SpeechModelPreparer.unsupportedMessage)
        }
        XCTAssertEqual(lines.all.last, "E speech prepare [en-us]: locale unsupported")
    }

    func testStatusUnsupportedThrowsUnsupported() async {
        let service = FakeSpeechAssetService()
        service.statuses = [.unsupported]
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: { _ in }, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, SpeechModelPreparer.unsupportedMessage)
        }
        XCTAssertEqual(service.downloads, 0)
    }

    func testTransientNetworkErrorRetriesThenSucceeds() async throws {
        let service = FakeSpeechAssetService()
        service.steps = [0.5]
        service.downloadErrors = [URLError(.notConnectedToInternet), URLError(.timedOut)]
        let progress = ProgressLog(), lines = LineLog(), delays = DelayLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: progress.add, log: lines.add, sleep: { delays.add($0) })
        XCTAssertEqual(service.downloads, 3)
        XCTAssertEqual(delays.all, [.milliseconds(500), .seconds(1)])
        XCTAssertEqual(progress.all, [0, 0.5, 0, 0.5, 0, 0.5, nil])
        XCTAssertEqual(lines.all, [
            "I speech prepare [en-us]: start",
            "I speech prepare [en-us]: status needsDownload",
            "E download speech model attempt 1 [en-US]: NSURLErrorDomain Code=-1009",
            "I speech prepare [en-us]: status after failure needsDownload",
            "I speech prepare [en-us]: retry 1 of 3",
            "E download speech model attempt 2 [en-US]: NSURLErrorDomain Code=-1001",
            "I speech prepare [en-us]: status after failure needsDownload",
            "I speech prepare [en-us]: retry 2 of 3",
            "I speech prepare [en-us]: download finished",
        ])
    }

    func testOfflineAfterThreeRetriesExplainsTheRealReason() async {
        let service = FakeSpeechAssetService()
        service.downloadErrors = Array(repeating: URLError(.notConnectedToInternet), count: 10)
        let progress = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: progress.add, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, SpeechModelPreparer.offlineMessage)
        }
        XCTAssertEqual(service.downloads, 4, "one attempt plus three retries")
        XCTAssertEqual(progress.all.last, .some(nil))
    }

    func testTimeoutAfterRetriesUsesGenericMessage() async {
        let service = FakeSpeechAssetService()
        service.downloadErrors = Array(repeating: URLError(.timedOut), count: 10)
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: { _ in }, log: { _, _ in }, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, SpeechModelPreparer.downloadFailedMessage)
        }
    }

    func testFailureIsSuccessWhenModelIsInstalledMeanwhile() async throws {
        let service = FakeSpeechAssetService()
        service.statuses = [.downloading, .installed]
        service.downloadErrors = [URLError(.notConnectedToInternet)]
        let progress = ProgressLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: progress.add, log: { _, _ in }, sleep: { _ in })
        XCTAssertEqual(service.downloads, 1)
        XCTAssertEqual(progress.all, [0, nil])
    }

    func testLocaleNormalization() {
        XCTAssertEqual(SpeechModelPreparer.normalized(Locale(identifier: "en_US")), SpeechModelPreparer.normalized(Locale(identifier: "en-US")))
    }
}

private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Duration] = []
    func add(_ d: Duration) { lock.withLock { items.append(d) } }
    var all: [Duration] { lock.withLock { items } }
}
