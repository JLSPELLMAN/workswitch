#!/bin/bash
# Creates a stable, self-signed code-signing identity for local development.
#
# WHY THIS EXISTS
#
# macOS ties an Accessibility (TCC) grant to the app's *designated requirement*. For an
# ad-hoc signature that requirement is literally the binary's cdhash:
#
#     designated => cdhash H"12d7c965a6190b959ddbabab5521e86a51295b60"
#
# So every rebuild produces a new cdhash, the stored grant stops matching, and
# AXIsProcessTrusted() returns false — while System Settings still shows a stale row that
# looks enabled. Toggling it off and on fixes it only until the next build.
#
# Signing with a certificate instead makes the requirement:
#
#     designated => identifier "com.lorenzospellman.workswitch"
#                   and certificate leaf = H"<cert hash>"
#
# which does not change when the binary does, so the grant survives rebuilds.
#
# Normally this would be an Apple Development certificate from Xcode, but Xcode is not
# installed here. A self-signed certificate produces an equally stable requirement; it is
# only trusted on this machine, which is exactly what local development needs.
#
# Idempotent: re-running does nothing if the identity already exists.
set -euo pipefail

IDENTITY_NAME="WorkSwitch Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$HOME/.config/workswitch/signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "==> Signing identity already present:"
  security find-identity -v -p codesigning | grep "$IDENTITY_NAME" | sed 's/^/    /'
  exit 0
fi

echo "==> Creating self-signed code-signing identity: $IDENTITY_NAME"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

CONFIG="$WORK_DIR/openssl.cnf"
cat > "$CONFIG" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = WorkSwitch Development
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORK_DIR/signing.key" \
  -out "$WORK_DIR/signing.crt" \
  -days 3650 -nodes -config "$CONFIG" 2>/dev/null
chmod 600 "$WORK_DIR/signing.key"

# Apple's importer rejects OpenSSL 3's default PKCS#12 algorithms, so the bundle is written
# with the legacy set it accepts.
openssl pkcs12 -export \
  -inkey "$WORK_DIR/signing.key" \
  -in "$WORK_DIR/signing.crt" \
  -out "$WORK_DIR/signing.p12" \
  -name "$IDENTITY_NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout pass:workswitch 2>/dev/null
chmod 600 "$WORK_DIR/signing.p12"

# -A allows codesign to use the private key without a keychain authorization prompt.
security import "$WORK_DIR/signing.p12" \
  -k "$KEYCHAIN" -P workswitch -A -T /usr/bin/codesign >/dev/null

# Without trust settings the certificate imports but is not a *valid* signing identity.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/signing.crt"

echo "==> Created:"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" | sed 's/^/    /'
echo ""
echo "Next: 'make install', then grant Accessibility once. The grant will now survive rebuilds."
