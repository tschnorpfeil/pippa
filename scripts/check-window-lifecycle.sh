#!/usr/bin/env bash
# Test the real app's window behavior without touching Pippa's preferences, single-instance lock or local AI.
# APFS cloning shares payload storage; the temporary bundle identifier isolates cfprefsd as well as HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Pippa.app}"
WORK="$(mktemp -d)"
TEST_ID="io.github.tschnorpfeil.pippa.window-check.$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
  defaults delete "$TEST_ID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cp -cR "$APP" "$WORK/Pippa.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" "$WORK/Pippa.app/Contents/Info.plist"
codesign --force --sign - "$WORK/Pippa.app" >/dev/null 2>&1
mkdir -p "$WORK/home"
# Use LaunchServices, like a Dock/Finder launch. Directly executing the Mach-O does not grant foreground activation.
open -n -W --env "HOME=$WORK/home" --env "CFFIXED_USER_HOME=$WORK/home" --env "PIPPA_PI_HOME=$WORK/home" \
  --stdout "$WORK/checks.log" --stderr "$WORK/errors.log" "$WORK/Pippa.app" --args --check-window-lifecycle
cat "$WORK/checks.log"
if ! rg -q '^Window lifecycle checks passed\.$' "$WORK/checks.log"; then
  cat "$WORK/errors.log" >&2
  exit 1
fi
