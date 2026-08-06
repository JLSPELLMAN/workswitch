#!/bin/bash
# Installs the Chrome native messaging host manifest.
#
# Chrome only launches a native host that is declared by a manifest in a well-known
# directory, and only for extensions listed in `allowed_origins`. The extension ID is
# deterministic because manifest.json pins a public key (see gen_extension_key.sh).
#
# The manifest is installed at the Chrome level, so it applies to every profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_NAME="com.lorenzospellman.workswitch"
INSTALLED_APP="${INSTALLED_APP:-$HOME/Applications/WorkSwitch.app}"
RELAY="$INSTALLED_APP/Contents/MacOS/workswitch-bridge"
ID_FILE="$ROOT/chrome-extension/.keys/extension_id.txt"

if [[ ! -f "$ID_FILE" ]]; then
  echo "error: $ID_FILE missing. Run scripts/gen_extension_key.sh first." >&2
  exit 1
fi
EXT_ID="$(tr -d '[:space:]' < "$ID_FILE")"

if [[ ! -x "$RELAY" ]]; then
  echo "error: relay not found at $RELAY" >&2
  echo "       Run 'make install' first so the app bundle exists." >&2
  exit 1
fi

# Chromium-family browsers each read their own directory. Installing into all present ones
# means the extension works in whichever the user actually loads it into.
TARGETS=(
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  "$HOME/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts"
  "$HOME/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
)

INSTALLED_COUNT=0
for dir in "${TARGETS[@]}"; do
  parent="$(dirname "$dir")"
  # Only install where the browser is actually present, to avoid creating stray folders.
  [[ -d "$parent" ]] || continue
  mkdir -p "$dir"
  cat > "$dir/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "WorkSwitch tab bridge",
  "path": "$RELAY",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
EOF
  echo "==> Installed $dir/$HOST_NAME.json"
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
done

if [[ $INSTALLED_COUNT -eq 0 ]]; then
  echo "warning: no Chromium-family browser directories found" >&2
  exit 1
fi

echo "==> Extension ID: $EXT_ID"
echo "==> Relay:        $RELAY"
echo
echo "Restart Chrome for the manifest to be picked up."
