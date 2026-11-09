// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import ShadowKit

/// The only place that asks macOS to list Shadow in a privacy list (R2, R9).
struct SystemPermissionRegistrar: PermissionRegistrar {
    func register(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screen:
            UserDefaults.standard.set(true, forKey: SystemPermissionChecker.askedScreenKey)   // wording only
            _ = CGRequestScreenCaptureAccess()
            // A short ScreenCaptureKit probe also registers the app; its result and errors are ignored.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }
}
