#!/bin/bash
# Shell test for stable signing (macOS only). Builds the app twice with a stable throwaway identity and twice ad-hoc, and checks:
#   - stable builds: identical designated requirement, different cdhash
#   - ad-hoc builds: different cdhash
# Everything happens in a throwaway keychain under a temp dir that is passed to bundle.sh explicitly. The user's
# keychain search list and login keychain are never modified. Usage: scripts/test-signing.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
KC="$TMP/shadow-test.keychain-db"
KC_PW="$(uuidgen)"
LIST_BEFORE="$(security list-keychains -d user)"
FAILED=0

cleanup() {
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; FAILED=1; }
dr_of() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
cdhash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
SIGNING_KEYCHAIN="$KC" scripts/make-signing-identity.sh
# Idempotent: a second run creates nothing, and asking it to export a key it no longer has is an error.
SIGNING_KEYCHAIN="$KC" scripts/make-signing-identity.sh >/dev/null || fail "second make-signing-identity run failed"
[ "$(security find-certificate -a -c "Shadow Signing" "$KC" | grep -c '"labl"')" = 1 ] || fail "Shadow Signing was duplicated"
if SIGNING_KEYCHAIN="$KC" scripts/make-signing-identity.sh --export-p12 "$TMP/x.p12" >/dev/null 2>&1; then
  fail "--export-p12 on an existing identity should fail"
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC" >/dev/null

build() { # <name> <version> [env assignments...]
  local name="$1" version="$2"; shift 2
  env DIST_DIR="$TMP/$name" SIGNING_KEYCHAIN="$KC" "$@" scripts/bundle.sh "$version" >"$TMP/$name.log" 2>&1 ||
    { cat "$TMP/$name.log" >&2; fail "bundle.sh failed for $name"; return 1; }
}

# A trivial change between builds (the version string lands in Info.plist, which the code signature covers),
# so cdhash differs while the designated requirement must not.
build stable1 0.0.1-sign-test SIGNING_IDENTITY="Shadow Signing"
build stable2 0.0.2-sign-test SIGNING_IDENTITY="Shadow Signing"
build auto 0.0.5-sign-test                       # no SIGNING_IDENTITY: picks Shadow Signing from the keychain
KC_EMPTY="$TMP/empty.keychain-db"
security create-keychain -p "$KC_PW" "$KC_EMPTY"
build fallback 0.0.6-sign-test SIGNING_KEYCHAIN="$KC_EMPTY"   # nothing usable: ad-hoc with a warning, exit 0
build adhoc1 0.0.3-sign-test SIGNING_IDENTITY=-
build adhoc2 0.0.4-sign-test SIGNING_IDENTITY=-

S1="$TMP/stable1/Shadow.app"; S2="$TMP/stable2/Shadow.app"
A1="$TMP/adhoc1/Shadow.app"; A2="$TMP/adhoc2/Shadow.app"

[ "$(dr_of "$TMP/auto/Shadow.app")" = "$(dr_of "$S1")" ] || fail "auto-detected identity did not give the Shadow Signing DR"
grep -q "WARNING: no stable signing identity" "$TMP/fallback.log" || fail "ad-hoc fallback did not warn loudly"
case "$(dr_of "$TMP/fallback/Shadow.app")" in 'identifier "com.kalahroudi.shadow"') ;; *) fail "fallback is not ad-hoc" ;; esac
for app in "$S1" "$S2" "$TMP/auto/Shadow.app"; do
  codesign -d --entitlements - "$app" 2>&1 | grep -q "com.apple.security.device.audio-input" || fail "entitlements missing from $app"
done

echo "stable DR 1: $(dr_of "$S1")"
echo "stable DR 2: $(dr_of "$S2")"
[ -n "$(dr_of "$S1")" ] || fail "stable build has no designated requirement"
[ "$(dr_of "$S1")" = "$(dr_of "$S2")" ] || fail "stable builds have different designated requirements"
case "$(dr_of "$S1")" in *'certificate leaf = H"'*) ;; *) fail "stable DR lacks the certificate leaf hash" ;; esac
[ "$(cdhash_of "$S1")" != "$(cdhash_of "$S2")" ] || fail "stable builds have the same cdhash (the test change had no effect)"
[ "$(cdhash_of "$A1")" != "$(cdhash_of "$A2")" ] || fail "ad-hoc builds have the same cdhash"
case "$(dr_of "$A1")" in 'identifier "com.kalahroudi.shadow"') ;; *) fail "ad-hoc DR is not the bundle identifier: $(dr_of "$A1")" ;; esac

cleanup
trap - EXIT
[ ! -e "$KC" ] || fail "throwaway keychain still exists"
[ "$(security list-keychains -d user)" = "$LIST_BEFORE" ] || fail "keychain search list changed"

if [ "$FAILED" -ne 0 ]; then exit 1; fi
echo "test-signing: ok"
