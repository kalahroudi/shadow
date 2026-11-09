// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What to do with a verified, staged update given who signed it (R22).
public enum UpdateDecision: Equatable, Sendable {
    public enum Note: Equatable, Sendable {
        /// Same stable identity: macOS keeps Screen Recording and Microphone access.
        case permissionsCarryOver
        /// The identity changes or is ad-hoc: access has to be granted again.
        case permissionsWillReset
    }
    case proceed(Note)
    /// Ask first: "This update is signed with a different identity; ..." (R24).
    case confirm
    case refuse(UpdateError)

    /// `userConfirmed` is true after the user answered "Update anyway" to a previous `.confirm`.
    /// An installed app whose requirement can't be read is treated as ad-hoc: there is nothing stable to preserve.
    public static func decide(installed: URL, staged: URL, userConfirmed: Bool, inspector: SigningInspector) -> UpdateDecision {
        let new: SigningIdentity
        do { new = try inspector.identity(of: staged) } catch {
            return .refuse(UpdateError(.identityRefused, detail: "staged bundle has no readable designated requirement"))
        }
        let old = (try? inspector.identity(of: installed))
            ?? SigningIdentity(kind: .adHoc, identifier: "", requirement: "")

        guard old.kind.isStable else { return .proceed(.permissionsWillReset) }

        if old.compare(to: new) == .same {
            guard inspector.satisfies(staged: staged, requirement: old.requirement) else {
                return .refuse(UpdateError(.identityRefused, detail: "staged bundle does not satisfy the installed requirement"))
            }
            return .proceed(.permissionsCarryOver)
        }
        return userConfirmed ? .proceed(.permissionsWillReset) : .confirm
    }
}
