#!/bin/bash
# Signs <app> (and its nested shadow-mcp) with a stable identity and verifies the designated requirement.
# Usage: scripts/sign-app.sh <path/to/Shadow.app>   (called by scripts/bundle.sh; env: see bundle.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: sign-app.sh <Shadow.app>}"
BUNDLE_ID="com.kalahroudi.shadow"

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

# Prints the team ID (subject OU) of the certificate named $1; empty if there is none.
team_id_of() {
  security find-certificate -c "$1" -p ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null |
    /usr/bin/openssl x509 -noout -subject 2>/dev/null |
    tr ',/' '\n\n' | sed -n 's/^ *OU *= *\([A-Z0-9]\{10\}\) *$/\1/p' | head -1
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
    TEAM_ID="$(team_id_of "$IDENT_NAME")"
    if [ -z "$TEAM_ID" ]; then echo "error: cannot read the team ID (subject OU) from the certificate '$IDENT_NAME'" >&2; exit 1; fi
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
if [ "$KIND" = developerid ]; then
  # codesign prints the team ID with or without quotes; accept both.
  case "$ACTUAL_DR" in
    *"anchor apple generic"*) ;;
    *) echo "error: designated requirement lacks 'anchor apple generic'" >&2; exit 1 ;;
  esac
  if ! [[ "$ACTUAL_DR" =~ certificate\ leaf\[subject\.OU\]\ =\ \"?$TEAM_ID\"?($|[[:space:]]) ]]; then
    echo "error: designated requirement lacks the team ID $TEAM_ID" >&2; exit 1
  fi
fi
echo "cdhash (not the identity): $(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')   [changes on every build; the DR above is what TCC uses]"
