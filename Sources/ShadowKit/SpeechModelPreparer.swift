// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the platform says about a locale's speech model.
public enum SpeechAssetStatus: Sendable, Equatable {
    case installed, downloading, needsDownload, unsupported
}

/// The platform questions `SpeechModelPreparer` asks. The real one wraps SpeechTranscriber and AssetInventory (R12).
public protocol SpeechAssetService: Sendable {
    /// The locale the recognizer supports that matches `locale`, or nil when the system finds none.
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    /// Every locale the recognizer supports, for a second look when `supportedLocale(equivalentTo:)` comes back empty.
    func supportedLocales() async -> [Locale]
    /// Installed, downloading, needing a download or unsupported, as AssetInventory and the installed locales report it.
    func status(for locale: Locale) async -> SpeechAssetStatus
    /// Downloads and installs the model, calling `progress` with 0...1 while it runs.
    func download(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Decides whether a speech model is usable, downloading it when needed (R11, R12).
public enum SpeechModelPreparer {
    /// Retries after the first failed download attempt, each after the matching delay.
    public static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    public static let unsupportedMessage = "Speech recognition doesn't support this language yet. Pick another language."
    public static let offlineMessage = "The speech model needs a download and macOS reports no connection. Check the network or Low Data Mode and try again."
    public static let downloadFailedMessage = "Couldn't download the speech model. Check your internet connection and try again."

    /// Lower-cased BCP-47 form, so "en-US", "en_US" and "EN-us" compare equal.
    public static func normalized(_ locale: Locale) -> String {
        locale.identifier(.bcp47).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Network failures worth retrying: no connection, timeout, host unreachable or connection lost.
    public static func isTransientNetwork(_ error: Error) -> Bool {
        let transient = [-1001, -1003, -1004, -1005, -1009]
        // AssetInventory can wrap the URL error; only domain and code are read, never message text.
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let ns = current else { return false }
            if ns.domain == NSURLErrorDomain && transient.contains(ns.code) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Passes progress through until `close()`, so a late callback from a finished download cannot revive the indicator.
    private final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        private let sink: @Sendable (Double?) -> Void
        init(_ sink: @escaping @Sendable (Double?) -> Void) { self.sink = sink }
        func send(_ v: Double) { lock.withLock { if open { sink(v) } } }
        func close() { lock.withLock { open = false; sink(nil) } }
    }

    private static func isOffline(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let ns = current else { return false }
            if ns.domain == NSURLErrorDomain && ns.code == -1009 { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// `onProgress` gets 0...1 while downloading and always ends with nil, including when the download fails or is cancelled.
    /// `log` receives each decision in order (`isError`, line) with the locale and any error's domain and code, never message text.
    public static func prepare(
        locale: Locale, service: some SpeechAssetService,
        onProgress: @escaping @Sendable (Double?) -> Void,
        log: @escaping @Sendable (_ isError: Bool, _ line: String) -> Void = { isError, line in
            if isError { AppLog.record(error: line) } else { AppLog.info(line) }
        },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        let want = normalized(locale)
        log(false, "speech prepare [\(want)]: start")

        var supported = await service.supportedLocale(equivalentTo: locale)
        if supported == nil {
            // The system lookup can miss a locale that is in the supported list; compare normalized identifiers.
            let all = await service.supportedLocales()
            supported = all.first { normalized($0) == want }
            log(false, "speech prepare [\(want)]: system lookup found none; list of \(all.count) \(supported == nil ? "has no match" : "matched \(normalized(supported!))")")
        }
        guard let supported else {
            log(true, "speech prepare [\(want)]: locale unsupported")
            throw UserFacingError(unsupportedMessage)
        }
        let id = normalized(supported)

        var status = await service.status(for: supported)
        log(false, "speech prepare [\(id)]: status \(status)")
        switch status {
        case .installed: return
        case .unsupported:
            log(true, "speech prepare [\(id)]: asset status unsupported")
            throw UserFacingError(unsupportedMessage)
        case .downloading, .needsDownload: break
        }

        let gate = ProgressGate(onProgress)
        gate.send(0)
        defer { gate.close() }
        var attempt = 0
        while true {
            do {
                try await service.download(supported) { gate.send($0) }
                log(false, "speech prepare [\(id)]: download finished")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(true, SpeechLog.line(context: "download speech model attempt \(attempt + 1)", locale: supported, error: error))
                // Another download (or a late finish) may have installed it meanwhile: that is success, not failure.
                status = await service.status(for: supported)
                log(false, "speech prepare [\(id)]: status after failure \(status)")
                if status == .installed { return }
                guard isTransientNetwork(error), attempt < retryDelays.count else {
                    throw UserFacingError(isOffline(error) ? offlineMessage : downloadFailedMessage)
                }
                log(false, "speech prepare [\(id)]: retry \(attempt + 1) of \(retryDelays.count)")
                try await sleep(retryDelays[attempt])
                attempt += 1
                gate.send(0)
            }
        }
    }
}
