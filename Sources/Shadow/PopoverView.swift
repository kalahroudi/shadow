// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ShadowKit

/// The menu bar popover. Placeholder until the milestone 1 popover lands; keep it light, since AppDelegate drops its views on close.
struct PopoverView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 34)).resizable().frame(width: 34, height: 34)
            Text("Shadow").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { OnboardingWindowController.shared.show() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Run setup again").accessibilityLabel("Run setup again")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit Shadow").accessibilityLabel("Quit")
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.pane)   // an opaque themed background: the popover must follow the app theme
    }
}
