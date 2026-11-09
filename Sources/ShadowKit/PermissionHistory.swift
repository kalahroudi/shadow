// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Remembers, per permission, that it was granted once, so a later "not granted" can be called stale (R8).
/// One boolean per permission; no secrets and no audio.
public struct PermissionHistory: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func key(_ kind: PermissionKind) -> String {
        kind == .screen ? PrefsDefaults.permissionGrantedScreen : PrefsDefaults.permissionGrantedMicrophone
    }

    public func wasGranted(_ kind: PermissionKind) -> Bool { defaults.bool(forKey: Self.key(kind)) }

    /// Sets the marker when the state is granted and leaves it as it was otherwise.
    public func record(_ kind: PermissionKind, state: PermissionState) {
        if state == .granted { defaults.set(true, forKey: Self.key(kind)) }
    }

    public var grantedBefore: Set<PermissionKind> { Set(PermissionKind.allCases.filter(wasGranted)) }
}
