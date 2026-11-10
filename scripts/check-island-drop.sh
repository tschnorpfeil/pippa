#!/usr/bin/env bash
# Drags a file from another app onto the open Pippa Island with real mouse events and presses the default shortcut,
# in a cloned app that touches neither Pippa's preferences nor her AI. Moves the pointer for a few seconds; the
# Terminal needs Accessibility access.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Pippa.app}"
WORK="$(mktemp -d)"
TEST_ID="io.github.tschnorpfeil.pippa.island-drop-check.$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
  pkill -f "$WORK/Pippa.app" >/dev/null 2>&1 || true
  defaults delete "$TEST_ID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cp -cR "$APP" "$WORK/Pippa.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" "$WORK/Pippa.app/Contents/Info.plist"
codesign --force --sign - "$WORK/Pippa.app" >/dev/null 2>&1
mkdir -p "$WORK/home"
printf 'fixture\n' > "$WORK/dropped.txt"
printf 'second fixture\n' > "$WORK/second.txt"
swiftc -O -o "$WORK/source" "$ROOT/scripts/island-drop-source.swift"
: > "$WORK/checks.log"
open -n --env "HOME=$WORK/home" --env "CFFIXED_USER_HOME=$WORK/home" --env "PIPPA_PI_HOME=$WORK/home" \
  --stdout "$WORK/checks.log" --stderr "$WORK/errors.log" "$WORK/Pippa.app" --args --check-island-drop
"$WORK/source" "$WORK/checks.log" "$WORK/dropped.txt" "$WORK/second.txt" || { cat "$WORK/checks.log"; exit 1; }
