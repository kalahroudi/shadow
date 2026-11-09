// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ShadowKit

/// The Updates pane (R14, R16, R18). Reuses the other panes' `Row` and `.card()` helpers.
struct UpdatesPane: View {
    @State private var prefs = Prefs.shared
    @State private var updater = Updater.shared

    var body: some View {
        let state = updater.state
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 12) {
                Row(title: "Current version", detail: updater.versionLine) {
                    Button("Check for updates") { Task { await updater.checkNow() } }.disabled(!state.canCheck)
                }
                Divider()
                Row(title: "Latest version", detail: latestDetail(state)) {
                    Button("Update and relaunch") { Task { await updater.updateAndRelaunch() } }.disabled(!state.canInstall)
                }
                if let update = state.availableUpdate, !update.notes.isEmpty {
                    Text(update.notes).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .installing(let step, let fraction) = state {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UpdatesCopy.stepLabel(step)).font(.system(size: 12)).foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                    }
                }
                Divider()
                Row(title: "Automatically check for updates", detail: "Checks once a day when Shadow starts.") {
                    Toggle("", isOn: $prefs.autoUpdateChecks).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                Row(title: "Last checked") { Text(UpdatesCopy.lastChecked(updater.lastChecked)).foregroundStyle(.secondary) }
            }.card()
            if let note = updater.permissionsNote {
                Text(UpdatesCopy.permissionsNote(note)).font(.system(size: 12)).foregroundStyle(note == .permissionsWillReset ? Theme.danger : .secondary)
            }
            if let text = updater.handoffText { Text(text).font(.system(size: 12)).foregroundStyle(.secondary) }
            status(state)
        }
        .onAppear { updater.refreshGate() }
        .onChange(of: prefs.localOnly) { updater.refreshGate() }
    }

    private func latestDetail(_ state: UpdateState) -> String {
        if let u = state.availableUpdate { return "Version \(u.version)" }
        return state == .upToDate ? "You have the latest version." : "Not checked yet."
    }

    @ViewBuilder private func status(_ state: UpdateState) -> some View {
        if let text = UpdatesCopy.status(state), !state.canInstall {
            if case .failed = state {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    HStack {
                        Button("Copy details") { updater.copyDetails() }
                        Button("Report on GitHub") { updater.reportOnGitHub() }
                    }
                }
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
