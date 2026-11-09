// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The platform questions `SpeechModelPreparer` asks. The real one wraps SpeechTranscriber and AssetInventory (R12).
public protocol SpeechAssetService: Sendable {
    /// The locale the recognizer supports that matches `locale`, or nil when none does.
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func isInstalled(_ locale: Locale) async -> Bool
    /// Downloads and installs the model, calling `progress` with 0...1 while it runs.
    func download(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Decides whether a speech model is usable, downloading it when needed (R11, R12).
public enum SpeechModelPreparer {
    /// `onProgress` gets 0...1 while downloading and always ends with nil, including when the download fails or is cancelled.
    public static func prepare(locale: Locale, service: some SpeechAssetService,
                               onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let supported = await service.supportedLocale(equivalentTo: locale) else {
            AppLog.info("unsupported speech locale \(locale.identifier)")
            throw UserFacingError("Speech recognition doesn't support this language yet. Pick another language.")
        }
        if await service.isInstalled(supported) { return }

        onProgress(0)
        defer { onProgress(nil) }
        do {
            try await service.download(supported) { onProgress($0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.speechError(error, context: "download speech model", locale: supported)
            throw UserFacingError("Couldn't download the speech model. Check your internet connection and try again.")
        }
    }
}
