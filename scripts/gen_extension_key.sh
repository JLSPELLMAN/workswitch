#!/bin/bash
# Generates the extension's signing key and derives its deterministic extension ID.
#
# Why this exists: an unpacked extension normally gets an ID derived from its filesystem
# path, so the ID changes if the folder moves and is unknown before the first load. The
# native messaging host manifest has to name that ID in `allowed_origins` up front. Pinning
# a public key in manifest.json makes the ID stable and knowable ahead of time.
#
# Run once. The generated ID is written into manifest.json and the host manifest template.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="$ROOT/chrome-extension/.keys"
PRIVATE_KEY="$KEY_DIR/extension_private_key.pem"
PUBLIC_DER="$KEY_DIR/extension_public_key.der"

mkdir -p "$KEY_DIR"

if [[ -f "$PRIVATE_KEY" ]]; then
  echo "==> Reusing existing key at $PRIVATE_KEY"
else
  echo "==> Generating 2048-bit RSA key"
  openssl genrsa -out "$PRIVATE_KEY" 2048 2>/dev/null
  chmod 600 "$PRIVATE_KEY"
fi

openssl rsa -in "$PRIVATE_KEY" -pubout -outform DER -out "$PUBLIC_DER" 2>/dev/null

# Chrome derives the extension ID from the SHA-256 of the DER public key: take the first
# 16 bytes, hex-encode, then map 0-9a-f onto a-p.
EXT_ID="$(python3 -c "
import hashlib, sys
der = open('$PUBLIC_DER','rb').read()
digest = hashlib.sha256(der).hexdigest()[:32]
print(''.join(chr(ord('a') + int(c, 16)) for c in digest))
")"

MANIFEST_KEY="$(base64 < "$PUBLIC_DER" | tr -d '\n')"

echo "$EXT_ID" > "$KEY_DIR/extension_id.txt"
echo "$MANIFEST_KEY" > "$KEY_DIR/manifest_key.txt"

echo "==> Extension ID: $EXT_ID"
echo "==> Wrote $KEY_DIR/extension_id.txt and manifest_key.txt"
