#!/bin/zsh
# One-time setup, run by you: creates a self-signed code-signing certificate named
# "One Commander Local Signing" in your login keychain and trusts it for code signing.
#
# Why: build-app.sh otherwise signs "ad hoc", so every rebuild looks like a brand-new app to
# macOS and it asks again for Desktop/Documents/Downloads access. Signing with a stable
# certificate keeps those permissions across rebuilds.
#
# What it changes: adds one certificate + private key to your login keychain and marks the
# certificate trusted for code signing only (macOS asks for your password to allow that).
# Undo: open Keychain Access, search "One Commander Local Signing", delete the certificate
# and its key.
set -euo pipefail
NAME="One Commander Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ \"$NAME\" is already set up. build-app.sh will use it."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

echo "Creating certificate…"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# The .p12 only exists for the import below; its password never leaves this script.
P12PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$P12PASS"

echo "Adding it to your login keychain…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null

echo "Trusting it for code signing (macOS will ask for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ Done. Run ./build-app.sh — it now signs with \"$NAME\"."
  echo "  macOS will ask for folder access once more for the newly signed app, then remember it."
else
  echo "✗ The certificate was added but isn't usable for code signing yet." >&2
  exit 1
fi
