#!/bin/bash
# Script-level test of scripts/sign-app.sh with stubbed `codesign` and `security` on PATH (the real keychain is never
# touched). Asserts the exact designated requirements from spec 008 R5/R6/R8 and the Developer ID team-ID checks.
# Usage: scripts/test-signing-stubs.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

TEAM=ABCDE12345
DEV_HASH=0123456789ABCDEF0123456789ABCDEF01234567
SS_HASH=FEDCBA9876543210FEDCBA9876543210FEDCBA98
BID=com.kalahroudi.shadow

# A certificate with the team ID as subject OU, and one without.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/with-ou.pem" -days 2 \
  -subj "/CN=Developer ID Application: Test ($TEAM)/OU=$TEAM/O=Test" 2>/dev/null
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/no-ou.pem" -days 2 \
  -subj "/CN=Developer ID Application: Test ($TEAM)/O=Test" 2>/dev/null

cat > "$BIN/security" <<STUB
#!/bin/bash
case "\$1" in
  find-identity) printf '  1) %s "%s"\n     1 valid identities found\n' "\$STUB_HASH" "\$STUB_NAME" ;;
  find-certificate) cat "\$STUB_CERT" ;;
  *) echo "unexpected security call: \$*" >&2; exit 99 ;;
esac
STUB
cat > "$BIN/codesign" <<'STUB'
#!/bin/bash
case "$1" in
  --verify) exit 0 ;;
  -d) echo "Executable=x"; [ -z "${STUB_DR:-}" ] || echo "$STUB_DR"; exit 0 ;;
  -dvvv) echo "CDHash=deadbeef" >&2; exit 0 ;;
esac
{ echo "CALL"; for a in "$@"; do echo "$a"; done; } >> "$STUB_LOG"
STUB
chmod +x "$BIN/security" "$BIN/codesign"

APP="$TMP/Shadow.app"; mkdir -p "$APP/Contents/MacOS"; : > "$APP/Contents/MacOS/shadow-mcp"

# run <name> <hash> <cert> <reported DR> [env...]; sets RC, OUT, and the codesign call log in $TMP/log
run() {
  local name="$1" hash="$2" cert="$3" dr="$4"; shift 4
  : > "$TMP/log"
  set +e
  OUT="$(env PATH="$BIN:$PATH" STUB_NAME="$name" STUB_HASH="$hash" STUB_CERT="$cert" STUB_DR="$dr" STUB_LOG="$TMP/log" \
    "$@" "$ROOT/scripts/sign-app.sh" "$APP" 2>&1)"
  RC=$?
  set -e
}
expect_ok() { [ "$RC" = 0 ] || fail "$1: expected success, got $RC: $OUT"; }
expect_fail() { [ "$RC" != 0 ] || fail "$1: expected failure"; case "$OUT" in *"$2"*) ;; *) fail "$1: missing message '$2' in: $OUT" ;; esac; }
has_arg() { grep -qxF -- "$1" "$TMP/log" || fail "$2: codesign was not given: $1"; }

# --- R6 Developer ID: exact requirement, hardened runtime, entitlements, quoted and unquoted team ID.
R6="designated => anchor apple generic and identifier \"$BID\" and certificate leaf[subject.OU] = \"$TEAM\""
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" "$R6" env
expect_ok "devid quoted"
has_arg "-r=$R6" "devid"; has_arg "--options" devid; has_arg "runtime" devid; has_arg "--timestamp" devid
has_arg "--entitlements" devid; has_arg "scripts/Shadow.entitlements" devid; has_arg "--identifier" devid; has_arg "$BID" devid
[ "$(grep -c '^CALL$' "$TMP/log")" = 2 ] || fail "devid: expected shadow-mcp then the app to be signed"

run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => anchor apple generic and identifier \"$BID\" and certificate leaf[subject.OU] = $TEAM" env
expect_ok "devid unquoted"

run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => anchor apple generic and identifier \"$BID\" and certificate leaf[subject.OU] = ${TEAM}9" env
expect_fail "devid longer team id" "lacks the team ID"
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => anchor apple generic and identifier \"$BID\"" env
expect_fail "devid DR without team" "lacks the team ID"
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => anchor apple generic and identifier \"$BID\" and certificate leaf[subject.OU] = \"ZZZZZ99999\"" env
expect_fail "devid wrong team" "lacks the team ID"
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => identifier \"$BID\" and certificate leaf[subject.OU] = \"$TEAM\"" env
expect_fail "devid DR without anchor" "anchor apple generic"
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/with-ou.pem" \
  "designated => anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" env
expect_fail "devid DR without identifier" "lacks identifier"

# The team ID comes from the certificate, and a certificate without one stops the build before anything is signed.
run "Developer ID Application: Test ($TEAM)" "$DEV_HASH" "$TMP/no-ou.pem" "$R6" env
expect_fail "devid cert without OU" "cannot read the team ID"
[ ! -s "$TMP/log" ] || fail "devid cert without OU: codesign ran anyway"

# --- R5 Shadow Signing: exact requirement and entitlements, leaf hash checked case-insensitively.
LC_SS="$(echo "$SS_HASH" | tr 'A-F' 'a-f')"
R5="designated => identifier \"$BID\" and certificate leaf = H\"$LC_SS\""
run "Shadow Signing" "$SS_HASH" "$TMP/with-ou.pem" "$R5" env
expect_ok "shadow signing"
has_arg "-r=$R5" "shadow signing"; has_arg "--entitlements" "shadow signing"
run "Shadow Signing" "$SS_HASH" "$TMP/with-ou.pem" "designated => identifier \"$BID\" and certificate leaf = H\"0000000000000000000000000000000000000000\"" env
expect_fail "shadow signing wrong leaf" "lacks the leaf hash"

# --- R8 ad-hoc: exact requirement, loud warning on fallback, still succeeds.
R8="designated => identifier \"$BID\""
run "none" "$SS_HASH" "$TMP/with-ou.pem" "$R8" env SIGNING_IDENTITY=-
expect_ok "explicit ad-hoc"
has_arg "-r=$R8" adhoc
run "none" "$SS_HASH" "$TMP/with-ou.pem" "$R8" env STUB_NAME=nothing-usable
expect_ok "ad-hoc fallback"
case "$OUT" in *"WARNING: no stable signing identity"*"RESET"*) ;; *) fail "fallback warning missing: $OUT" ;; esac

# run_t must turn a hang (for example an unanswerable keychain prompt) into a loud failure naming the command.
. scripts/lib-timeout.sh
RC=0; OUT="$(run_t 1 sleep 30 2>&1)" || RC=$?
[ "$RC" = 124 ] || fail "run_t did not time out a hung command (rc=$RC)"
case "$OUT" in *"TIMEOUT after 1s: sleep"*) ;; *) fail "run_t timeout message missing: $OUT" ;; esac
RC=0; run_t 5 sh -c 'exit 3' || RC=$?
[ "$RC" = 3 ] || fail "run_t changed the exit status (rc=$RC)"

if [ "$FAILED" -ne 0 ]; then exit 1; fi
echo "test-signing-stubs: ok"
