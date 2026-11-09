#!/bin/bash
# Reports how an app is signed and whether macOS permission grants will survive a rebuild.
# Usage: scripts/check-signing.sh [--adhoc-fallback] <path/to/Shadow.app>
#   Prints the identity, authority, team and designated requirement (DR) of <app>, then builds the same source
#   twice with scripts/bundle.sh (into temp dirs, honouring SIGNING_IDENTITY / SIGNING_KEYCHAIN) and compares the
#   two DRs: "grants will persist" if they match and the identity is stable, "grants will reset" otherwise.
#   --adhoc-fallback forces ad-hoc builds (CI) and checks the fallback DR is `designated => identifier "<id>"`.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.kalahroudi.shadow"
ADHOC=0
if [ "${1:-}" = "--adhoc-fallback" ]; then ADHOC=1; shift; fi
APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then echo "usage: $0 [--adhoc-fallback] <path/to/Shadow.app>" >&2; exit 2; fi

dr_of() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
cdhash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

describe() {
  local info; info="$(codesign -dvvv "$1" 2>&1)"
  echo "App:        $1"
  echo "Identifier: $(echo "$info" | sed -n 's/^Identifier=//p')"
  echo "Signature:  $(echo "$info" | sed -n 's/^Signature=//p')"
  echo "Authority:  $(echo "$info" | sed -n 's/^Authority=//p' | paste -sd '>' - | sed 's/>/ > /g')"
  echo "Team:       $(echo "$info" | sed -n 's/^TeamIdentifier=//p')"
  echo "DR:         designated => $(dr_of "$1")"
}

describe "$APP"
DR_APP="$(dr_of "$APP")"
case "$DR_APP" in *"identifier \"$BUNDLE_ID\""*) ;; *) echo "error: DR lacks identifier \"$BUNDLE_ID\"" >&2; exit 1 ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ "$ADHOC" = 1 ] && export SIGNING_IDENTITY="-"

echo "Building the same source twice to compare designated requirements..."
for n in 1 2; do
  DIST_DIR="$TMP/build$n" scripts/bundle.sh "0.0.0-check$n" >"$TMP/build$n.log" 2>&1 ||
    { cat "$TMP/build$n.log" >&2; echo "error: build $n failed" >&2; exit 1; }
done
DR1="$(dr_of "$TMP/build1/Shadow.app")"
DR2="$(dr_of "$TMP/build2/Shadow.app")"
echo "Build 1 DR: designated => $DR1"
echo "Build 2 DR: designated => $DR2"
echo "cdhash (not the identity): $(cdhash_of "$TMP/build1/Shadow.app") / $(cdhash_of "$TMP/build2/Shadow.app")"

if [ "$ADHOC" = 1 ] && [ "$DR1" != "identifier \"$BUNDLE_ID\"" ]; then
  echo "error: ad-hoc fallback DR is not exactly 'designated => identifier \"$BUNDLE_ID\"'" >&2; exit 1
fi

if [ "$DR1" = "$DR2" ] && [ "$DR1" != "identifier \"$BUNDLE_ID\"" ]; then
  echo "Result: grants will persist (identical DR across rebuilds)"
elif [ "$DR1" = "$DR2" ]; then
  echo "Result: grants will reset (ad-hoc signing has no certificate in its DR; whether macOS honours this DR is untested)"
else
  echo "Result: grants will reset (the DR changes between builds)"
fi
