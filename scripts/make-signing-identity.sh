#!/bin/bash
# Creates the self-signed "Shadow Signing" code-signing identity in your login keychain, once.
# Usage: scripts/make-signing-identity.sh [--export-p12 <path>]
#
# Idempotent: if "Shadow Signing" already exists nothing is created. Other keychain items are never touched.
# --export-p12 writes the new identity as a p12 (mode 600) with a random password printed once, for the
# SIGNING_P12_BASE64 / SIGNING_P12_PASSWORD GitHub secrets. It only works on the run that creates the identity,
# because that is the only time the private key is available outside the keychain.
set -euo pipefail

NAME="Shadow Signing"
OPENSSL=/usr/bin/openssl   # LibreSSL: its p12 files import cleanly with `security`
KEYCHAIN="${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
EXPORT_P12=""

while [ $# -gt 0 ]; do
  case "$1" in
    --export-p12) EXPORT_P12="${2:?--export-p12 needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

list() { security find-identity "$@" -p codesigning "$KEYCHAIN" 2>/dev/null | grep "\"$NAME\"" || true; }

report() {
  local line sha
  line="$(list | head -1)"
  sha="$(echo "$line" | sed -n 's/^ *[0-9]*) \([0-9A-Fa-f]\{40\}\).*/\1/p' | tr 'A-F' 'a-f')"
  echo "Identity:   $NAME"
  echo "SHA-1:      $sha"
  echo "Leaf cert:  $sha   (certificate leaf = H\"$sha\" in the designated requirement)"
}

if [ -n "$(list -v)" ] || [ -n "$(list)" ]; then
  echo "\"$NAME\" already exists; nothing to do."
  [ -z "$EXPORT_P12" ] || echo "note: --export-p12 ignored; the private key can only be exported when the identity is created." >&2
  report
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 7300 -config "$WORK/cert.cnf" 2>/dev/null

# Import through a p12 with a throwaway password that is never printed.
IMPORT_PW="$("$OPENSSL" rand -hex 16)"
PW_ENV="$IMPORT_PW" "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/import.p12" -passout env:PW_ENV
# -T limits access to codesign; no -A, so other apps cannot use the key.
security import "$WORK/import.p12" -k "$KEYCHAIN" -P "$IMPORT_PW" -T /usr/bin/codesign >/dev/null

if [ -n "$EXPORT_P12" ]; then
  P12_PW="$("$OPENSSL" rand -hex 16)"
  PW_ENV="$P12_PW" "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$EXPORT_P12" -passout env:PW_ENV
  chmod 600 "$EXPORT_P12"
fi

# Trust is only needed if codesign refuses the identity. Test with a throwaway binary.
SHA="$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g' | tr 'A-F' 'a-f')"
printf 'int main(void){return 0;}\n' > "$WORK/t.c"
cc "$WORK/t.c" -o "$WORK/t"
if ! codesign --force --keychain "$KEYCHAIN" --sign "$SHA" "$WORK/t" >/dev/null 2>&1; then
  echo "codesign did not accept the new identity; marking it trusted for code signing (current user only)..."
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
  codesign --force --keychain "$KEYCHAIN" --sign "$SHA" "$WORK/t" >/dev/null
fi

echo "Created \"$NAME\" in $KEYCHAIN"
report
if [ -n "$EXPORT_P12" ]; then
  echo "p12:        $EXPORT_P12 (mode 600)"
  echo "p12 password (shown once, store it now): $P12_PW"
fi
