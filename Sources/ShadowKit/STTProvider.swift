// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Speech-to-text behind a seam (R9). Milestone 1 has one on-device implementation; others plug in later.
public protocol STTProvider: Sendable {
    /// Makes the provider ready for a locale (for example downloading models) before any capture starts.
    /// Throws a `UserFacingError` when it cannot, so the session never starts half-working.
    func prepare(locale: Locale) async throws
    /// Consumes one stream and yields partial and final segments. Finishes after the source stream ends and its last words are final.
    /// If recognition fails mid-session the stream finishes by throwing (a `UserFacingError` when the message is user-ready) and stops
    /// reading `source`; the other speaker's stream is independent and unaffected.
    func transcribe(_ source: AsyncStream<TimedBuffer>, speaker: Speaker, locale: Locale) -> AsyncThrowingStream<Segment, Error>
}
