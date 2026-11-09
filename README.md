<p align="center"><img src="docs/assets/icon.png" width="128" alt="Shadow app icon"></p>

<h1 align="center">Shadow</h1>

<p align="center">A free, open-source, on-device live transcript for meetings and interviews. macOS 26+ menu bar app.</p>

<p align="center"><img src="docs/assets/overlay.png" width="560" alt="Shadow's floating overlay showing a live Them and You transcript (sample text)"></p>

## Install with an AI agent

Paste this into an AI coding agent such as Claude Code. Shadow's GitHub releases are the intended way to install, but this prompt builds from source so it works before the first release (Xcode with the macOS 26 SDK is required):

```text
Install Shadow on this Mac.
1. Run: git clone https://github.com/kalahroudi/shadow.git && cd shadow && scripts/bundle.sh
2. Copy dist/Shadow.app to /Applications and open it. Its first-run setup asks for Screen & System Audio Recording and
   Microphone permission. Tell me to click through that window if it is waiting, and wait until it is done.
   If macOS says a relaunch is needed after screen recording is granted, quit and reopen Shadow.
3. Register its MCP server: claude mcp add shadow --scope user -- /Applications/Shadow.app/Contents/MacOS/shadow-mcp
4. Call get_status and tell me what it reports.
Never call a destructive tool without asking me first.
```

## Features

- **Two separate streams.** Them is system audio (ScreenCaptureKit, excluding Shadow's own sounds). You is your microphone. Pick the microphone in Settings > Speech (it takes effect on the next Start). Capturing a single app or window for Them is a planned follow-up; for now Them is whole system audio.
- **On-device speech-to-text.** Apple SpeechAnalyzer, no keys, no account, no cloud.
- **Live floating overlay.** Frosted glass, follows you across Spaces, never steals focus. Compact and Expanded, adjustable opacity, per-display position, optional click-through with a hotkey that always turns it off.
- **Menu bar popover.** Start/Stop, level meters, persona and language pickers, overlay switch.
- **Global hotkeys.** ⌘⇧Space start/stop, ⌘⇧H show/hide, ⌘⇧T click-through, ⌘⇧E compact/expand. All rebindable in Settings, no extra permission.
- **Settings.** Speech, Hotkeys, Privacy and General panes. Every option saves and applies immediately.
- **Visible by design.** No stealth mode and no way to hide the overlay from screen sharing. A reminder before each session is on by default.
- **Private.** Audio is never written to disk. Only the text transcript is saved, under `~/Library/Application Support/Shadow/sessions/`, written atomically, with recovery after a crash.

<p align="center"><img src="docs/assets/popover.png" width="300" alt="Popover"> <img src="docs/assets/settings.png" width="420" alt="Settings"></p>

## Status

Milestone 1 (capture, live transcript, overlay) is in development. The app builds and tests with zero warnings, and unit tests drive the whole session pipeline with fakes. Hardware paths (ScreenCaptureKit, microphone, SpeechAnalyzer) need manual checks on a real Mac. Builds are unsigned.

## Roadmap

Next milestones:

- LLM answers (the Answering state is a stub today)
- Screenshots and OCR
- RAG over your own files
- History
- Notarization and a Homebrew cask

## Cutting a release

1. Pick a version and push a tag named `vX.Y.Z` (for example `git tag v0.2.0 && git push origin v0.2.0`). Tags that are not valid semantic versions do not release.
2. The `Release` workflow (`.github/workflows/release.yml`) builds, runs `swift test`, runs `scripts/bundle.sh` with the version taken from the tag and `APP_REPO=$GITHUB_REPOSITORY`, packs `Shadow-X.Y.Z.dmg` and writes `SHA256SUMS`.
3. It runs `gh release create` with both files as assets. If the signing and notarization secrets (`SIGN_IDENTITY`, `SIGN_CERT_P12`, `SIGN_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`) are all present it signs and notarizes; otherwise it ships ad-hoc signed and the release notes say so.

The `Pages` workflow publishes `docs/` as the project site.

## How updates work

- **Daily check.** At launch, and only if the last successful check is more than 24 hours old and "Automatically check for updates" is on, Shadow asks `api.github.com` for the latest non-draft, non-prerelease release of `kalahroudi/shadow`. Nothing runs in the background: no timers or polling. "Check for updates" in Settings, and the right-click item in the menu bar, check immediately. After a GitHub rate-limit answer (403/429) it waits at least an hour.
- **Local-only.** With Local-only mode on (Settings > Privacy) Shadow never contacts GitHub: no check and no download. The Updates pane says checks are paused. Turning it off does not skip the daily limit.
- **Versions.** The release version must be strictly newer than the running one (semantic versioning, a leading `v` is fine). Development builds never check.
- **Checksum.** "Update and relaunch" first downloads the DMG (or zip) and `SHA256SUMS` and compares the SHA-256. A mismatch or a missing entry deletes the download and stops.
- **Verify.** The app is copied to a staging folder (the DMG is always detached) and must pass `codesign --verify --deep --strict`, have executable `Shadow` and `shadow-mcp`, and `Shadow --self-test` must print `ok` and its commit. Otherwise your installed app is left untouched.
- **Swap and rollback.** Shadow quits and a small script outside the app moves `Shadow.app` to `Shadow.previous.app`, moves the new app in and opens it. The new app writes an `update-ok` marker about 4 seconds after launch; the script then deletes `Shadow.previous.app`. With no marker within 40 seconds it restores the previous app and Shadow shows why in the Updates pane.
- **Ad-hoc builds.** Until releases are notarized, macOS may block the first launch of a downloaded copy: right-click Shadow.app, choose Open, and confirm once. Updates installed by Shadow itself are not quarantined. Shadow must be in a folder you can write to (for example `/Applications` as an admin user).

A Homebrew cask and notarization are still planned.

## Build

```sh
swift build && swift test      # zero warnings expected
scripts/bundle.sh              # dist/Shadow.app
dist/Shadow.app/Contents/MacOS/Shadow --self-test   # prints ok
dist/Shadow.app/Contents/MacOS/Shadow --snapshot /tmp/shots   # sample-data screenshots
```

## License

Apache-2.0
