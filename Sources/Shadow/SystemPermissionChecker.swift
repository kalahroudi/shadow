// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import ShadowKit

/// The real permission checker. Screen recording only reports a yes/no, so a flag picks the wording "Not asked yet" or "Not granted".
/// The flag never decides whether Allow is offered.
struct SystemPermissionChecker: PermissionChecker {
    static let askedScreenKey = "askedScreenRecording"

    func status(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            return Checklist.state(fromAuthorization: AVCaptureDevice.authorizationStatus(for: .audio))
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: Self.askedScreenKey) ? .notGranted : .notYetAsked
        }
    }

    /// Registration lives in `SystemPermissionRegistrar`; this only re-reads.
    func request(_ kind: PermissionKind) async -> PermissionState { status(kind) }
}
