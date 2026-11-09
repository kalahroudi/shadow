// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ShadowKit

/// The "fix your permissions" checklist (R7). Used by onboarding and, later, by the Start path.
struct PermissionChecklistView: View {
    let checker: PermissionChecker
    @State private var items: [ChecklistItem] = []
    @State private var copied: PermissionKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PermissionKind.allCases, id: \.self) { kind in row(kind) }
            Text("After granting Screen Recording, macOS may ask you to reopen Shadow.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("I did it - check again") { refresh() }
        }
        .onAppear { refresh() }
    }

    private func refresh() { items = Checklist.items(using: checker) }

    @ViewBuilder private func row(_ kind: PermissionKind) -> some View {
        if let item = items.first(where: { $0.kind == kind }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(item.state == .notYetAsked ? "Not asked yet" : "Not granted").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
                }
                Text(item.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if item.canRequest { Button("Allow") { Task { _ = await checker.request(kind); refresh() } } }
                    Button("Open System Settings") { if let u = URL(string: item.settingsURL) { NSWorkspace.shared.open(u) } }
                    Button(copied == kind ? "Copied" : "Copy link") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.settingsURL, forType: .string); copied = kind
                    }
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
