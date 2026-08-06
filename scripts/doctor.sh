#!/bin/bash
# Reports the code-signing and TCC identity of every WorkSwitch copy on this machine.
#
# The failure this diagnoses: System Settings shows WorkSwitch enabled for Accessibility,
# but AXIsProcessTrusted() returns false. That happens when the running binary is not the
# one macOS granted — either it was re-signed with a different identity, or a different
# copy is being launched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.lorenzospellman.workswitch"
CANONICAL="$HOME/Applications/WorkSwitch.app"
IDENTITY_NAME="WorkSwitch Development"

echo "══════════════════════════════════════════════════════════"
echo " WorkSwitch identity report"
echo "══════════════════════════════════════════════════════════"

echo ""
echo "── Signing identity ──"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  security find-identity -v -p codesigning | grep "$IDENTITY_NAME" | sed 's/^/  /'
else
  echo "  MISSING — builds will fall back to ad-hoc signing, which breaks the"
  echo "  Accessibility grant on every rebuild. Fix with: make signing-identity"
fi

echo ""
echo "── Running instances ──"
RUNNING="$(ps -Ao pid,args | grep -i 'WorkSwitch.app/Contents/MacOS/WorkSwitch' | grep -v grep)"
if [[ -n "$RUNNING" ]]; then
  echo "$RUNNING" | sed 's/^/  /'
  COUNT="$(echo "$RUNNING" | wc -l | tr -d ' ')"
  [[ "$COUNT" -gt 1 ]] && echo "  WARNING: more than one instance is running."
else
  echo "  (none running)"
fi

echo ""
echo "── Copies on disk ──"
# Every distinct copy is a distinct TCC identity if signed differently.
CANDIDATES=(
  "$CANONICAL"
  "$ROOT/build/WorkSwitch.app"
  "/Applications/WorkSwitch.app"
)
for path in "${CANDIDATES[@]}"; do
  [[ -d "$path" ]] || continue
  MARKER="  "
  [[ "$path" == "$CANONICAL" ]] && MARKER="* "
  echo "${MARKER}${path}"
  INFO="$(codesign -dv --verbose=4 "$path" 2>&1)"
  ID="$(echo "$INFO" | grep '^Identifier=' | cut -d= -f2)"
  # A certificate-signed bundle prints Authority lines and no "Signature=adhoc".
  if echo "$INFO" | grep -q '^Signature=adhoc'; then
    SIG="adhoc"
  elif echo "$INFO" | grep -q '^Authority='; then
    SIG="certificate: $(echo "$INFO" | grep '^Authority=' | head -1 | cut -d= -f2)"
  else
    SIG="unsigned"
  fi
  CD="$(codesign -dv --verbose=4 "$path" 2>&1 | grep '^CDHash=' | cut -d= -f2)"
  DR="$(codesign -d -r- "$path" 2>&1 | grep 'designated' | sed 's/^designated => //')"
  echo "      identifier : ${ID:-unknown}"
  echo "      signature  : ${SIG:-unsigned}"
  echo "      cdhash     : ${CD:-unknown}"
  echo "      designated : ${DR:-unknown}"
  if [[ "$SIG" == "adhoc" ]]; then
    echo "      ⚠ ad-hoc: the requirement IS the cdhash, so it changes on every rebuild."
  fi
done
echo ""
echo "  (* = canonical install path; anything else is a duplicate or stale copy)"

RAW="$ROOT/.build/release/WorkSwitch"
if [[ -f "$RAW" ]]; then
  echo ""
  echo "── Raw SwiftPM binary ──"
  echo "  $RAW"
  echo "      identifier : $(codesign -dv "$RAW" 2>&1 | grep '^Identifier=' | cut -d= -f2)"
  echo "  NOTE: this has a different signing identifier than the bundle, so launching it"
  echo "        directly is a separate TCC identity. Use it only for --self-test/--dump."
fi

echo ""
echo "── Last launch, as reported by the app itself ──"
STARTUP_LOG="$HOME/Library/Application Support/WorkSwitch/startup.log"
if [[ -f "$STARTUP_LOG" ]]; then
  # Read from the app's own log rather than running the binary here: TCC attributes a
  # child process to whatever launched it, so running it from this terminal would report
  # the terminal's Accessibility grant instead of the app's.
  sed 's/^/  /' "$STARTUP_LOG"
else
  echo "  No startup log yet. Launch the app: open \"$CANONICAL\""
fi

echo ""
echo "── If permission looks enabled but is not active ──"
echo "  1. Remove WorkSwitch from System Settings > Privacy & Security > Accessibility"
echo "  2. tccutil reset Accessibility $BUNDLE_ID"
echo "  3. make install && open \"$CANONICAL\""
echo "  4. Enable WorkSwitch in Accessibility again"
echo ""
