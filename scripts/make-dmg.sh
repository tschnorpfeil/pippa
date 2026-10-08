#!/usr/bin/env bash
# Packs dist/Pippa.app into dist/Pippa.dmg (UDZO, volume "Pippa") with an
# Applications link (named "Programme"), background image and, if Finder plays
# along, window layout. Optionally notarizes and staples.
#
#   scripts/make-dmg.sh
#
# Environment:
#   PIPPA_NOTARY_PROFILE  Keychain profile for `xcrun notarytool` (see docs/development.md)
#   PIPPA_DMG_LAYOUT=0    skip the Finder layout via AppleScript
#   PIPPA_REQUIRE_DISTRIBUTION=1  signing and notarization mandatory
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Pippa.app"
DMG="$DIST/Pippa.dmg"
VOLNAME="Pippa"
PROFILE="${PIPPA_NOTARY_PROFILE:-}"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mNote: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || die "$APP missing; run scripts/build-app.sh first"
codesign --verify --deep --strict "$APP" || die "Pippa.app is not validly signed"
if [[ "${PIPPA_REQUIRE_DISTRIBUTION:-0}" == 1 ]]; then
  [[ -n "$PROFILE" ]] || die "a release needs PIPPA_NOTARY_PROFILE"
  [[ "${PIPPA_SIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || die "a release needs a Developer ID Application"
fi
if [[ -n "$PROFILE" ]]; then
  [[ -n "${PIPPA_SIGN_IDENTITY:-}" ]] || die "notarization needs PIPPA_SIGN_IDENTITY"
  [[ "$(codesign -dvv "$APP" 2>&1)" == *$'\nAuthority=Developer ID Application:'* ]] || die "Pippa.app is not signed with a Developer ID; rebuild first"
  xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not available"
fi

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet -force || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Contents ------------------------------------------------------------------
say "Assembling contents"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
# Background: 640×400 pt, @1x and @2x in one TIFF (sharp on Retina).
swift "$ROOT/app/Packaging/make-icon.swift" --dmg-background "$WORK/bg.png" 640x400
swift "$ROOT/app/Packaging/make-icon.swift" --dmg-background "$WORK/bg@2x.png" 1280x800
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 ||
  cp "$WORK/bg.png" "$STAGE/.background/background.tiff"

# --- Writable image, Finder layout ------------------------------------------------
say "Creating image"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 100 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs APFS -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"

layout_finder() {
  # Needs a logged-in Finder and Automation permission for the calling
  # program. Headless (SSH, CI) this fails; then we go without a layout.
  MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen 2>/dev/null | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  [[ -n "$MOUNT" ]] || return 1
  local disk
  disk="$(basename "$MOUNT")"
  cat >"$WORK/layout.applescript" <<APPLESCRIPT
tell application "Finder"
  tell disk "$disk"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Pippa.app" of container window to {160, 190}
    set position of item "Programme" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  timeout_osascript 30 "$WORK/layout.applescript"
  local status=$? waited=0
  # Finder writes .DS_Store with a delay; without it the layout is missing.
  while ((status == 0)) && [[ ! -f "$MOUNT/.DS_Store" ]] && ((waited < 15)); do
    sleep 1
    waited=$((waited + 1))
  done
  if [[ ! -f "$MOUNT/.DS_Store" ]]; then
    echo "Finder did not write a .DS_Store" >>"$WORK/osascript.err"
    status=1
  fi
  sync
  hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -quiet -force
  MOUNT=""
  return "$status"
}

# osascript with a time limit (macOS has no `timeout`).
timeout_osascript() {
  local limit="$1" script="$2" pid waited=0
  osascript "$script" >/dev/null 2>"$WORK/osascript.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= limit)); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

if [[ "${PIPPA_DMG_LAYOUT:-1}" == 0 ]]; then
  warn "Finder layout skipped (PIPPA_DMG_LAYOUT=0)"
elif layout_finder; then
  echo "    Finder window arranged"
else
  warn "Finder layout not possible ($(head -c 200 "$WORK/osascript.err" 2>/dev/null | tr '\n' ' ')); DMG without layout"
fi

# --- Compress ----------------------------------------------------------------
say "Compressing to $DMG (UDZO)"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
if [[ -n "${PIPPA_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$PIPPA_SIGN_IDENTITY" "$DMG"
fi
hdiutil verify -quiet "$DMG"

# --- Notarize ----------------------------------------------------------------
if [[ -n "$PROFILE" ]]; then
  [[ -n "${PIPPA_SIGN_IDENTITY:-}" ]] || die "notarization needs a Developer ID signature (PIPPA_SIGN_IDENTITY)"
  xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not available"
  say "Notarizing (profile $PROFILE), this usually takes a few minutes"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG" || die "Gatekeeper does not accept the notarized image"
else
  warn "Not notarized (PIPPA_NOTARY_PROFILE not set). For distributing to others see docs/development.md."
fi

say "Done: $DMG ($(du -h "$DMG" | cut -f1))"
