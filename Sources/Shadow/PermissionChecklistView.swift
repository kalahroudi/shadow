// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// The "fix your permissions" checklist (R7). Used by onboarding and, later, by the Start path.
struct PermissionChecklistView: View {
    let center: PermissionCenter
    /// Called after every re-read, so the owner can drop the checklist once everything is granted.
    var onRefresh: (() -> Void)?
    @State private var items: [ChecklistItem] = []
    @State private var copied: PermissionKind?
    /// Kinds where Allow was pressed and the permission is still missing, so the next steps show.
    @State private var tried: Set<PermissionKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PermissionKind.allCases, id: \.self) { kind in row(kind) }
            Button(items.first?.nextSteps.checkAgainTitle ?? "I did it - check again") { refresh() }
        }
        .onAppear { refresh() }
    }

    private func refresh() { items = center.items(); onRefresh?() }
    private func allow(_ kind: PermissionKind) {
        Task { items = await center.allow(kind); tried.insert(kind); onRefresh?() }
    }

    @ViewBuilder private func row(_ kind: PermissionKind) -> some View {
        if let item = items.first(where: { $0.kind == kind }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(item.statusLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
                }
                Text(item.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                if let stale = item.staleText { Text(stale).font(.system(size: 12)).foregroundStyle(Theme.warn) }
                HStack(spacing: 8) {
                    if item.canRequest { Button("Allow") { allow(kind) } }
                    Button("Open System Settings") { if let u = URL(string: item.settingsURL) { NSWorkspace.shared.open(u) } }
                    Button(copied == kind ? "Copied" : "Copy link") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.settingsURL, forType: .string); copied = kind
                    }
                }
                if tried.contains(kind) {
                    let steps = item.nextSteps
                    Button(steps.revealTitle) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Text(steps.hint).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let relaunch = steps.relaunchNote { Text(relaunch).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }.card()
        } else {
            HStack {
                Text(kind == .screen ? "Screen & System Audio Recording" : "Microphone").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label("Granted", systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ok)
            }.card()
        }
    }
}
