import XCTest
@testable import ShadowKit

private final class FakeSpeechAssetService: SpeechAssetService, @unchecked Sendable {
    var supported: Locale?
    var installed = false
    var steps: [Double] = []
    var downloadError: Error?
    private(set) var downloads = 0
    init(supported: Locale? = Locale(identifier: "en-US")) { self.supported = supported }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { supported }
    func isInstalled(_ locale: Locale) async -> Bool { installed }
    func download(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloads += 1
        for s in steps { progress(s) }
        if let downloadError { throw downloadError }
    }
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
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, "Speech recognition doesn't support this language yet. Pick another language.")
        }
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertEqual(service.downloads, 0)
    }

    func testInstalledModelSkipsDownload() async throws {
        let service = FakeSpeechAssetService()
        service.installed = true
        let log = ProgressLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add)
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertEqual(service.downloads, 0)
    }

    func testDownloadReportsProgressAndEndsWithNil() async throws {
        let service = FakeSpeechAssetService()
        service.steps = [0.25, 0.5, 1]
        let log = ProgressLog()
        try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add)
        XCTAssertEqual(log.all, [0, 0.25, 0.5, 1, nil])
        XCTAssertEqual(service.downloads, 1)
    }

    func testDownloadFailureThrowsFriendlyMessageAndClearsProgress() async {
        let service = FakeSpeechAssetService()
        service.steps = [0.3]
        service.downloadError = URLError(.notConnectedToInternet)
        let log = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? UserFacingError)?.message, "Couldn't download the speech model. Check your internet connection and try again.")
        }
        XCTAssertEqual(log.all, [0, 0.3, nil])
    }

    func testCancellationPassesThroughAndClearsProgress() async {
        let service = FakeSpeechAssetService()
        service.downloadError = CancellationError()
        let log = ProgressLog()
        do {
            try await SpeechModelPreparer.prepare(locale: locale, service: service, onProgress: log.add)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(log.all, [0, nil])
    }
}
