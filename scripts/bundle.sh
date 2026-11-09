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

# --- Signing -------------------------------------------------------------------------------------------
# TCC keys permission grants on the designated requirement (DR), so every build gets an explicit DR that
# does not change with the code: the bundle ID plus the signing certificate.
KC_ARGS=()
[ -n "${SIGNING_KEYCHAIN:-}" ] && KC_ARGS=("${SIGNING_KEYCHAIN}")

# Prints "<SHA-1> <name>" for the first identity whose name starts with $1 (or whose SHA-1 or name equals $1).
# Untrusted self-signed identities are included: codesign accepts them and they are all we need.
find_identity() {
  local valid=()
  [ "$2" = prefix ] && valid=(-v)   # auto-detected Developer ID identities must be valid (not expired)
  security find-identity ${valid[@]+"${valid[@]}"} -p codesigning ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null |
    sed -n 's/^ *[0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)".*$/\1 \2/p' |
    awk -v want="$1" -v mode="$2" '
      { name = substr($0, 42) }
      mode == "prefix" && index(name, want) == 1 { print; exit }
      mode == "exact" && (tolower($1) == tolower(want) || name == want) { print; exit }'
}

KIND=adhoc
IDENT_HASH=""
IDENT_NAME=""
if [ -n "${SIGNING_IDENTITY:-}" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  FOUND="$(find_identity "$SIGNING_IDENTITY" exact)"
  if [ -z "$FOUND" ]; then echo "error: signing identity '$SIGNING_IDENTITY' not found in the keychain" >&2; exit 1; fi
elif [ -z "${SIGNING_IDENTITY:-}" ]; then
  FOUND="$(find_identity "Developer ID Application" prefix)"
  [ -n "$FOUND" ] || FOUND="$(find_identity "Shadow Signing" exact)"
else
  FOUND=""   # explicit ad-hoc
fi
if [ -n "$FOUND" ]; then
  IDENT_HASH="$(echo "${FOUND%% *}" | tr 'A-F' 'a-f')"
  IDENT_NAME="${FOUND#* }"
  case "$IDENT_NAME" in
    "Developer ID Application"*) KIND=developerid ;;
    *) KIND=selfsigned ;;
  esac
fi

SIGN_KC=()
[ -n "${SIGNING_KEYCHAIN:-}" ] && SIGN_KC=(--keychain "$SIGNING_KEYCHAIN")
APP_ENTITLEMENTS=()

case "$KIND" in
  selfsigned)
    DR="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$IDENT_HASH\""
    SIGN_FLAGS=(--force ${SIGN_KC[@]+"${SIGN_KC[@]}"} --identifier "$BUNDLE_ID" -r="$DR" --sign "$IDENT_HASH")
    APP_ENTITLEMENTS=(--entitlements scripts/Shadow.entitlements)
    echo "Signing with \"$IDENT_NAME\" ($IDENT_HASH)"
    ;;
  developerid)
    TEAM_ID="$(echo "$IDENT_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
    if [ -z "$TEAM_ID" ]; then echo "error: cannot read the team ID from '$IDENT_NAME'" >&2; exit 1; fi
    DR="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
    SIGN_FLAGS=(--force ${SIGN_KC[@]+"${SIGN_KC[@]}"} --timestamp --options runtime --identifier "$BUNDLE_ID" -r="designated => $DR" --sign "$IDENT_HASH")
    APP_ENTITLEMENTS=(--entitlements scripts/Shadow.entitlements)
    DR="designated => $DR"
    echo "Signing with \"$IDENT_NAME\" (hardened runtime)"
    ;;
  adhoc)
    DR="designated => identifier \"$BUNDLE_ID\""
    SIGN_FLAGS=(--force --identifier "$BUNDLE_ID" -r="$DR" --sign -)
    if [ "${SIGNING_IDENTITY:-}" = "-" ]; then
      echo "NOTE: explicit ad-hoc build (SIGNING_IDENTITY=-). macOS permission grants will reset on every build." >&2
    else
      {
        echo "########################################################################"
        echo "# WARNING: no stable signing identity found; signing AD-HOC."
        echo "# macOS permission grants (Screen Recording, Microphone) will RESET on"
        echo "# every build. Run scripts/make-signing-identity.sh once to fix this."
        echo "########################################################################"
      } >&2
    fi
    ;;
esac

codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/shadow-mcp"
codesign "${SIGN_FLAGS[@]}" ${APP_ENTITLEMENTS[@]+"${APP_ENTITLEMENTS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"

# Check the DR that was actually written.
ACTUAL_DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => /designated => /p')"
echo "Designated requirement:"
echo "  $ACTUAL_DR"
case "$ACTUAL_DR" in
  *"identifier \"$BUNDLE_ID\""*) ;;
  *) echo "error: designated requirement lacks identifier \"$BUNDLE_ID\"" >&2; exit 1 ;;
esac
if [ "$KIND" = selfsigned ]; then
  LC_DR="$(echo "$ACTUAL_DR" | tr 'A-FH' 'a-fh')"
  case "$LC_DR" in
    *"certificate leaf = h\"$IDENT_HASH\""*) ;;
    *) echo "error: designated requirement lacks the leaf hash $IDENT_HASH" >&2; exit 1 ;;
  esac
fi
echo "cdhash (not the identity): $(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')   [changes on every build; the DR above is what TCC uses]"

echo "Built $APP"
