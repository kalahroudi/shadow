// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Builds speech-related log lines from the locale and the Apple error domain and code only (R13).
/// It never reads `userInfo` or the localized description, so no transcript text can reach the log.
public enum SpeechLog {
    public static func line(context: String, locale: Locale, error: Error) -> String {
        let ns = error as NSError
        return "\(context) [\(locale.identifier(.bcp47))]: \(ns.domain) Code=\(ns.code)"
    }
}

extension AppLog {
    /// Logs a speech failure as `ERROR transcribe you [en-US]: SFSpeechErrorDomain Code=17`.
    public static func speechError(_ error: Error, context: String, locale: Locale) {
        record(error: SpeechLog.line(context: context, locale: locale, error: error))
    }
}
