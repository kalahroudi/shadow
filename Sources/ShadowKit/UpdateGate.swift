// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Asks the person whether to install an update signed with a different identity (R24).
public protocol UpdateConfirming: Sendable {
    /// True for "Update anyway", false for "Cancel".
    func confirmIdentityChange() async -> Bool
}

/// Decides, between verification and the swap, whether an update may go ahead (R22, R24).
public struct UpdateGate: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The swap ran; the note says whether permissions carry over.
        case swapped(UpdateDecision.Note)
        /// The person chose Cancel: nothing was swapped and the installed app is untouched.
        case cancelled
    }

    public static let confirmText = "This update is signed with a different identity; Screen Recording and Microphone access will need to be granted again"
    public static let confirmButton = "Update anyway"

    public let inspector: SigningInspector
    public let confirmer: UpdateConfirming

    public init(inspector: SigningInspector = SecurityFrameworkInspector(), confirmer: UpdateConfirming) {
        self.inspector = inspector; self.confirmer = confirmer
    }

    /// Runs `swap` only on proceed, or on confirm followed by "Update anyway". A refusal throws.
    /// `onNote` reports the permissions outcome just before the swap so the Updates pane can show it.
    public func run(installed: URL, staged: URL, onNote: @Sendable (UpdateDecision.Note) -> Void = { _ in },
                    swap: @Sendable () throws -> Void) async throws -> Outcome {
        var decision = UpdateDecision.decide(installed: installed, staged: staged, userConfirmed: false, inspector: inspector)
        if decision == .confirm {
            guard await confirmer.confirmIdentityChange() else { return .cancelled }
            decision = UpdateDecision.decide(installed: installed, staged: staged, userConfirmed: true, inspector: inspector)
        }
        switch decision {
        case .refuse(let error): throw error
        case .confirm: throw UpdateError(.identityRefused, detail: "unexpected second confirmation")
        case .proceed(let note):
            onNote(note)
            try swap()
            return .swapped(note)
        }
    }
}
