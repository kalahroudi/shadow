// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// What to do about missing permissions at launch (R5). Pure, so the rules are tested without TCC.
public enum LaunchRegistration {
    public enum Decision: Equatable, Sendable { case register([PermissionKind]), skip }

    /// Registers only when onboarding is done, something is missing, and this launch has not registered yet.
    /// Each missing kind is listed once, in `PermissionKind.allCases` order.
    public static func decide(onboardingCompleted: Bool, missing: [PermissionKind], alreadyRan: Bool) -> Decision {
        guard onboardingCompleted, !alreadyRan else { return .skip }
        let kinds = PermissionKind.allCases.filter(missing.contains)
        return kinds.isEmpty ? .skip : .register(kinds)
    }
}

/// Joins the checker, the registrar and the grant history, so views only render what it returns (R1, R2, R4, R5, R6, R8).
@MainActor @Observable
public final class PermissionCenter {
    /// True while a permission is missing; the popover shows its "Permissions needed" row from this (R6).
    public private(set) var needsAttention = false
    public static let neededRowTitle = "Permissions needed"

    @ObservationIgnored private let checker: PermissionChecker
    @ObservationIgnored private let registrar: PermissionRegistrar
    @ObservationIgnored private let history: PermissionHistory
    @ObservationIgnored private var launchRan = false

    public init(checker: PermissionChecker, registrar: PermissionRegistrar, history: PermissionHistory = PermissionHistory()) {
        self.checker = checker; self.registrar = registrar; self.history = history
    }

    /// Re-reads the system, records any grant, and returns an item for each permission that is not granted.
    @discardableResult
    public func items() -> [ChecklistItem] {
        for kind in PermissionKind.allCases { history.record(kind, state: checker.status(kind)) }
        let items = Checklist.items(using: checker, grantedBefore: history.grantedBefore)
        needsAttention = !items.isEmpty
        return items
    }

    /// Runs the real request path once per call, however often it was pressed before, then re-reads.
    public func allow(_ kind: PermissionKind) async -> [ChecklistItem] {
        await registrar.register(kind)
        return items()
    }

    /// The Start path: one registration per missing permission, then a re-read (R4). Granted ones are never touched.
    @discardableResult
    public func registerMissing() async -> [ChecklistItem] {
        for kind in items().map(\.kind) { await registrar.register(kind) }
        return items()
    }

    /// Once per launch, after onboarding: registers each missing permission at most once, so it can never loop (R5).
    public func registerOnLaunch(onboardingCompleted: Bool) async {
        let missing = items().map(\.kind)
        let decision = LaunchRegistration.decide(onboardingCompleted: onboardingCompleted, missing: missing, alreadyRan: launchRan)
        launchRan = true
        guard case .register(let kinds) = decision else { return }
        for kind in kinds { await registrar.register(kind) }
        items()
    }
}
