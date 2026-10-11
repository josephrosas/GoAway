#!/bin/zsh
# Creates (or reuses) a self-signed code-signing identity for local GoAway builds.
#
# Why: Full Disk Access is tied to the app's code-signing requirement. An ad-hoc
# signature's requirement is the hash of one exact binary, so every rebuild
# silently invalidates the grant. Signing with a stable identity makes the
# requirement "identifier com.unga.GoAway signed by this certificate", which
# survives rebuilds.
set -euo pipefail

NAME="${GOAWAY_SIGN_IDENTITY:-GoAway Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Signing identity \"$NAME\" already exists."
  exit 0
fi

echo "Creating self-signed code-signing identity \"$NAME\"…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $NAME
O = R6.ai

[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

P12_PASS="goaway"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$P12_PASS" -out "$WORK/identity.p12" >/dev/null 2>&1 \
|| openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$P12_PASS" -out "$WORK/identity.p12" >/dev/null 2>&1

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Mark the certificate as trusted for code signing. macOS may show a password
# dialog here; that is expected.
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null; then
  cat <<EOF

Could not set trust automatically. Finish in Keychain Access:
  1. Open Keychain Access → login → My Certificates → "$NAME".
  2. Double-click it, expand Trust, set Code Signing to "Always Trust".
  3. Re-run Scripts/build-app.sh.
EOF
  exit 1
fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Created \"$NAME\". The first codesign may ask for keychain access; choose Always Allow."
else
  echo "Identity was imported but is not yet valid for code signing. Check its trust settings in Keychain Access." >&2
  exit 1
fi
