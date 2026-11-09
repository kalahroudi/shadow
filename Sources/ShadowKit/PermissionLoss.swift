// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The screen and microphone state just before an update swap (R25).
public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let screenGranted: Bool
    public let microphoneGranted: Bool
    public init(screenGranted: Bool, microphoneGranted: Bool) {
        self.screenGranted = screenGranted; self.microphoneGranted = microphoneGranted
    }
}

/// Records permissions before an update and, on the first launch of the new version, says whether any was lost (R25).
public enum PermissionLossCheck {
    public static let message = "After the update, macOS no longer lists Shadow as allowed for everything it needs. Please allow the permissions below again."

    static func snapshot(_ checker: PermissionChecker) -> PermissionSnapshot {
        PermissionSnapshot(screenGranted: checker.status(.screen) == .granted,
                           microphoneGranted: checker.status(.microphone) == .granted)
    }

    /// Called just before the swap. A write failure is ignored: the check is a courtesy, never a reason to block an update.
    public static func record(checker: PermissionChecker, paths: AppPaths) {
        guard let data = try? JSONEncoder().encode(snapshot(checker)) else { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? data.write(to: paths.permissionSnapshotFile, options: .atomic)
    }

    /// Drops a snapshot whose swap never happened, so a later ordinary launch is not mistaken for an update.
    public static func discard(paths: AppPaths) { try? FileManager.default.removeItem(at: paths.permissionSnapshotFile) }

    /// True if a recorded permission went from granted to not granted. Removes the record, so it answers once.
    public static func checkOnce(checker: PermissionChecker, paths: AppPaths) -> Bool {
        let file = paths.permissionSnapshotFile
        guard let data = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        guard let before = try? JSONDecoder().decode(PermissionSnapshot.self, from: data) else { return false }
        let now = snapshot(checker)
        return (before.screenGranted && !now.screenGranted) || (before.microphoneGranted && !now.microphoneGranted)
    }
}
