// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Every file the app owns lives under one folder, so uninstalling is deleting it.
/// Never scatter state across ~/.something, /tmp and UserDefaults without listing it here.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shadow", isDirectory: true)
    }

    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Written by the running app so the MCP server can find it (loopback port + token), 0600.
    public var controlFile: URL { root.appendingPathComponent("control.json") }

    /// Downloads and the staged bundle for a self-update. Created on demand by the installer, not by `ensureDirectories`.
    public var updatesDir: URL { root.appendingPathComponent("updates", isDirectory: true) }
    /// Written by the new app about 4 s after launch; the swap script waits for it (R12). Deliberately outside `updatesDir`.
    public var updateOKFile: URL { root.appendingPathComponent("update-ok") }
    /// Written by the swap script when it rolled back; holds the reason (R12, R13).
    public var updateFailedFile: URL { root.appendingPathComponent("update-ok.failed") }
    /// Written before the hand-off; holds the version being installed so the next start can say "Updated to X".
    public var updatePendingFile: URL { root.appendingPathComponent("update-pending") }

    public func ensureDirectories() throws {
        for dir in [root, sessionsDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
}
