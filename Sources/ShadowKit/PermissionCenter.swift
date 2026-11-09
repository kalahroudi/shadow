// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Joins the checker, the registrar and the grant history, so views only render what it returns (R1, R2, R8).
@MainActor
public final class PermissionCenter {
    private let checker: PermissionChecker
    private let registrar: PermissionRegistrar
    private let history: PermissionHistory

    public init(checker: PermissionChecker, registrar: PermissionRegistrar, history: PermissionHistory = PermissionHistory()) {
        self.checker = checker; self.registrar = registrar; self.history = history
    }

    /// Re-reads the system, records any grant, and returns an item for each permission that is not granted.
    public func items() -> [ChecklistItem] {
        for kind in PermissionKind.allCases { history.record(kind, state: checker.status(kind)) }
        return Checklist.items(using: checker, grantedBefore: history.grantedBefore)
    }

    /// Runs the real request path once per call, however often it was pressed before, then re-reads.
    public func allow(_ kind: PermissionKind) async -> [ChecklistItem] {
        await registrar.register(kind)
        return items()
    }
}
