#!/bin/bash
# Builds Shadow.app into ./dist (or $DIST_DIR). Usage: scripts/bundle.sh [version]
#
# Signing identity (see README "Why signing matters / permissions"):
#   SIGNING_IDENTITY   a certificate name or SHA-1, or "-" for an explicit ad-hoc build. If unset, a
#                      "Developer ID Application" identity is used, else "Shadow Signing"
#                      (scripts/make-signing-identity.sh), else ad-hoc with a loud warning.
#   SIGNING_KEYCHAIN   optional keychain to search and sign from (used by scripts/test-signing.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.kalahroudi.shadow"

VERSION="${1:-0.1.0}"
APP="${DIST_DIR:-dist}/Shadow.app"
REPO="${APP_REPO:-kalahroudi/shadow}"
BRANCH="${APP_BRANCH:-main}"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi

swift build -c release --product Shadow
swift build -c release --product shadow-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shadow" "$APP/Contents/MacOS/Shadow"
cp "$BIN/shadow-mcp" "$APP/Contents/MacOS/shadow-mcp"

# App icon, drawn by the app itself so no image tools are needed.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN/Shadow" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shadow</string>
  <key>CFBundleDisplayName</key><string>Shadow</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Shadow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>ShadowCommit</key><string>$COMMIT</string>
  <key>ShadowRepo</key><string>$REPO</string>
  <key>ShadowBranch</key><string>$BRANCH</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Shadow transcribes your microphone on this Mac so the overlay can show what you say. Audio is never saved.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Shadow transcribes system audio on this Mac so the overlay can show what the other side says. Audio is never saved.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Shadow uses screen recording permission only to capture system audio from your calls. It does not record your screen.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

scripts/sign-app.sh "$APP"

echo "Built $APP"
