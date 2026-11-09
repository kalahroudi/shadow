# Shadow permissions audit (macOS 26)

Shadow needs two privacy permissions: **Screen & System Audio Recording** (`kTCCServiceScreenCapture`) and **Microphone** (`kTCCServiceMicrophone`). This page records which calls make Shadow appear in each System Settings list, and whether a third service, `kTCCServiceAudioCapture` ("System Audio Recording Only"), is needed.

## Status of this audit

**The empirical runs have not been done yet.** They need a real Mac with a logged-in GUI session, a throwaway copy of the app and clicks in System Settings. They were not run when this page was written, so every result cell below is `TBD`. Fill in the cells and the date as you run each case. Do not copy results from another macOS version.

- Audit date: `TBD`
- macOS version: `TBD` (run `sw_vers`; the target is macOS 26)
- Hardware: `TBD`

## Decision: is kTCCServiceAudioCapture needed?

**Provisional answer: no. To be confirmed by the audit below.**

Reasoning (from Apple's documented behavior, not yet measured here):

- Shadow captures system audio with an audio-only `SCStream` (`Sources/Shadow/SCKAudioSource.swift`). ScreenCaptureKit is gated by Screen & System Audio Recording (`kTCCServiceScreenCapture`), including for streams that only capture audio.
- `kTCCServiceAudioCapture` ("System Audio Recording Only") is the service used by Core Audio process taps (`AudioHardwareCreateProcessTap`). Shadow does not use process taps.
- The existing `NSAudioCaptureUsageDescription` key stays in `bundle.sh`. It is harmless and covers the tap case.

The answer becomes **yes** only if the audit shows that the audio-only `SCStream` path fails without, or is only registered by, `kTCCServiceAudioCapture` (that is, Shadow shows up only in the "System Audio Recording Only" list, or capture stays silent without it). In that case, open a follow-up: add `PermissionKind.systemAudio`, a minimal process tap in the app target's registrar, a third checklist row that gates Start, and add `tccutil reset AudioCapture com.kalahroudi.shadow` to `scripts/reset-permissions.sh`.

## Method

For each signing mode, build a throwaway copy and do not use the installed Shadow:

1. Copy the bundle, for example `cp -R Shadow.app /tmp/ShadowAudit.app`. Keep the bundle id `com.kalahroudi.shadow`, because the reset script only touches that id. Quit any other running Shadow first.
2. Sign the copy:
   - Ad-hoc: `codesign --force --deep --sign - /tmp/ShadowAudit.app`
   - Self-signed: create a code-signing certificate in Keychain Access (Certificate Assistant > Create a Certificate > Code Signing), then `codesign --force --deep --sign "<certificate name>" /tmp/ShadowAudit.app`
3. Reset: `scripts/reset-permissions.sh`, answer `y`.
4. Launch the copy. Trigger exactly one call at a time (a small throwaway harness or a debug build that calls only that API), then open System Settings > Privacy & Security and check each list. Reset between cases.
5. Record the result as `listed` (Shadow appears, toggle off), `prompt` (macOS shows a prompt), `granted` or `no`.

## Results: ad-hoc signed copy

| Call | Screen & System Audio Recording | Microphone | System Audio Recording Only |
| --- | --- | --- | --- |
| `CGRequestScreenCaptureAccess` | TBD | TBD | TBD |
| `SCShareableContent.excludingDesktopWindows` | TBD | TBD | TBD |
| Starting an audio-only `SCStream` | TBD | TBD | TBD |
| `AVCaptureDevice.requestAccess(for: .audio)` | TBD | TBD | TBD |
| Core Audio process tap | TBD | TBD | TBD |

## Results: self-signed copy

| Call | Screen & System Audio Recording | Microphone | System Audio Recording Only |
| --- | --- | --- | --- |
| `CGRequestScreenCaptureAccess` | TBD | TBD | TBD |
| `SCShareableContent.excludingDesktopWindows` | TBD | TBD | TBD |
| Starting an audio-only `SCStream` | TBD | TBD | TBD |
| `AVCaptureDevice.requestAccess(for: .audio)` | TBD | TBD | TBD |
| Core Audio process tap | TBD | TBD | TBD |

Also note, per signing mode, whether a grant survives a rebuild. Ad-hoc rebuilds change the cdhash, so grants are expected to reset until stable signing (spec 008) lands.

## Reset and re-test

- `scripts/reset-permissions.sh` asks `[y/N]` and, on `y`, runs `tccutil reset ScreenCapture` and `tccutil reset Microphone` for `com.kalahroudi.shadow` only. It refuses to run without a terminal.
- After a reset, relaunch the app, press Start, and confirm Shadow appears in both lists. Grant it, confirm capture works, remove the entry with "-", press Allow again and confirm it re-appears.
- Screen recording changes only apply after Shadow is relaunched.
