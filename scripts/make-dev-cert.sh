#!/bin/zsh
# Creates a self-signed "Murmur Dev" code-signing identity in your login keychain.
#
# macOS ties privacy permissions (Accessibility, Microphone) to an app's code
# signature. Ad-hoc signatures change on every build, so permissions silently stop
# working after a rebuild. Signing with one stable local identity keeps them.
#
# Run once. Remove later in Keychain Access → login → My Certificates → "Murmur Dev".
set -euo pipefail

NAME="Murmur Dev"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in $KEYCHAIN. Nothing to do."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# /usr/bin/openssl is LibreSSL, whose PKCS#12 output `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout "pass:$pass"

security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign

# Let codesign use the key without a "codesign wants to access…" dialog on every build.
# This asks for your Mac login password (the keychain password).
echo
echo "Allowing codesign to use the key. Enter your Mac login password if asked:"
pw_args=()
[[ -n "${KEYCHAIN_PASSWORD:-}" ]] && pw_args=(-k "$KEYCHAIN_PASSWORD")  # for non-interactive testing
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "${pw_args[@]}" "$KEYCHAIN" >/dev/null

echo
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
echo "(\"NOT_TRUSTED\" is expected for a self-signed certificate; codesign can still use it.)"
echo "Done. scripts/install.sh will now sign Murmur with \"$NAME\"."
