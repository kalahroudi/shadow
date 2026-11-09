// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import ShadowKit

/// The real permission checker. Screen recording only reports a yes/no, so "not yet asked" is tracked by a flag.
struct SystemPermissionChecker: PermissionChecker {
    private static let askedScreenKey = "askedScreenRecording"

    func status(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notYetAsked
            default: return .notGranted
            }
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: Self.askedScreenKey) ? .notGranted : .notYetAsked
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screen:
            UserDefaults.standard.set(true, forKey: Self.askedScreenKey)
            _ = CGRequestScreenCaptureAccess()
        }
        return status(kind)
    }
}
