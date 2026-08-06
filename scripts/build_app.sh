#!/bin/bash
# Assembles a .app bundle from the SwiftPM binary.
#
# This exists because the machine has Command Line Tools but no Xcode, so there is no
# xcodebuild to produce a bundle. Everything here is plain file layout plus codesign.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="WorkSwitch"
APP="$ROOT/build/$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
BRIDGE_BIN="$BIN_DIR/WorkSwitchBridge"

for required in "$BIN" "$BRIDGE_BIN"; do
  if [[ ! -f "$required" ]]; then
    echo "error: binary not found at $required" >&2
    exit 1
  fi
done

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# Chrome launches this relay directly, so it ships inside the bundle at a fixed path that
# the native messaging host manifest points at.
cp "$BRIDGE_BIN" "$APP/Contents/MacOS/workswitch-bridge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PanelBackground.png" "$APP/Contents/Resources/PanelBackground.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with the stable development identity when it exists.
#
# This matters more than it looks: with an ad-hoc signature the designated requirement is
# the binary's cdhash, so every rebuild invalidates the Accessibility grant. A certificate
# makes the requirement depend on the cert instead, so the grant survives rebuilds.
# See scripts/setup_signing_identity.sh.
IDENTITY_NAME="WorkSwitch Development"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "==> Signing with '$IDENTITY_NAME'"
  # Nested binaries are signed first; --deep is deprecated and unreliable for this.
  codesign --force --options runtime --sign "$IDENTITY_NAME" \
    "$APP/Contents/MacOS/workswitch-bridge"
  codesign --force --sign "$IDENTITY_NAME" --identifier "$BUNDLE_ID" "$APP"
else
  echo "==> WARNING: '$IDENTITY_NAME' not found; falling back to an ad-hoc signature."
  echo "    The Accessibility grant will break on every rebuild."
  echo "    Fix once with: make signing-identity"
  codesign --force --sign - "$APP/Contents/MacOS/workswitch-bridge"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
echo "==> Designated requirement:"
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/    /'

echo "==> Built $APP"
