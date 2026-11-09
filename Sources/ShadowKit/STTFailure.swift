// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Decides whether a failed recogniser stream is worth restarting (R6, R7).
/// Anything not named in `nonRecoverable` is recoverable, so an unknown error costs at most a few quick restarts.
public enum STTFailure {
    /// Apple error domain and code pairs that a fresh analyzer cannot fix. Add new entries here, with a test.
    static let nonRecoverable: Set<Pair> = [
        Pair(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
    ]
    struct Pair: Hashable { let domain: String; let code: Int }

    /// Errors the provider wrote for people (unsupported locale, unreadable audio format) and cancellation never recover.
    public static func isRecoverable(_ error: Error) -> Bool {
        if error is UserFacingError || error is CancellationError { return false }
        let ns = error as NSError
        return !nonRecoverable.contains(Pair(domain: ns.domain, code: ns.code))
    }
}
