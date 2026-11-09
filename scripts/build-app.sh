#!/usr/bin/env bash
# Builds dist/Pippa.app (arm64): SwiftPM release, Info.plist, resource bundles,
# app icon, Node, Pi payload, fd and ripgrep, signing. The local AI (oMLX runtime and model) is not bundled:
# setup downloads it (docs/omlx-switch.md).
#
#   scripts/build-app.sh
#
# Environment:
#   PIPPA_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"; without: ad hoc
#   PIPPA_SKIP_BUILD=1   use the existing release build (no swift build)
#   PIPPA_CACHE          download cache (default ~/Library/Caches/pippa-build)
#   PIPPA_REQUIRE_DISTRIBUTION=1  Developer ID mandatory (release pipeline)
#   PIPPA_BUILD_JOBS     parallel compile jobs for swift build (default: cores - 2, at least 1),
#                        so a build leaves the Mac usable
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/app"
PACKAGING="$APP_SRC/Packaging"
DIST="$ROOT/dist"
APP="$DIST/Pippa.app"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}"
IDENTITY="${PIPPA_SIGN_IDENTITY:-}"
. "$ROOT/scripts/lib.sh"
if [[ "${PIPPA_REQUIRE_DISTRIBUTION:-0}" == 1 && "$IDENTITY" != "Developer ID Application:"* ]]; then
  die "a release needs PIPPA_SIGN_IDENTITY with a Developer ID Application."
fi

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
for tool in swift codesign iconutil sips plutil install_name_tool otool shasum curl python3 tar; do
  command -v "$tool" >/dev/null || die "$tool missing (Command Line Tools installed?)"
done

CORES="$(sysctl -n hw.ncpu)"
JOBS="${PIPPA_BUILD_JOBS:-$(( CORES - 2 ))}"
[[ "$JOBS" =~ ^[0-9]+$ ]] || die "PIPPA_BUILD_JOBS must be a whole number, got '$JOBS'"
(( JOBS >= 1 )) || JOBS=1

# --- Version -----------------------------------------------------------------
read_version_build
say "Pippa $VERSION ($BUILD)"

# --- Default model pinned (catalog.json) ------------------------------------
# A catalog model without revision, size and SHA256 per file cannot be downloaded: never ship that.
# PIPPA_ALLOW_UNPINNED=1 only for local test builds, never for a distribution build.
if ! python3 "$ROOT/scripts/check-default-models.py"; then
  if [[ "${PIPPA_ALLOW_UNPINNED:-0}" == 1 && "${PIPPA_REQUIRE_DISTRIBUTION:-0}" != 1 ]]; then
    warn "default model not pinned (PIPPA_ALLOW_UNPINNED=1): this build cannot set up 16 GB Macs and up"
  else
    die "default model not pinned; run scripts/pin-model.sh (see above)"
  fi
fi

# --- SwiftPM-Release ---------------------------------------------------------
SWIFT_ARGS=(-c release --arch arm64)
if [[ "${PIPPA_SKIP_BUILD:-}" != 1 ]]; then
  say "swift build -c release --arch arm64 ($JOBS jobs)"
  (cd "$APP_SRC" && swift build "${SWIFT_ARGS[@]}" --jobs "$JOBS" --product Pippa)
fi
BIN="$(cd "$APP_SRC" && swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
[[ -x "$BIN/Pippa" ]] || die "no release binary at $BIN/Pippa"

mkdir -p "$CACHE"

# --- fd and ripgrep for Pi's find and grep (pinned, checksum-verified) -------
SEARCH_JSON="$ROOT/app/Packaging/search-tools.json"
SEARCH_DIR="$CACHE/search-tools"
mkdir -p "$SEARCH_DIR"
while read -r TOOL URL SHA; do
  FILE="$CACHE/$(basename "$URL")"
  fetch_pinned "$URL" "$FILE" "$SHA"
  rm -rf "${SEARCH_DIR:?}/$TOOL"
  mkdir -p "$SEARCH_DIR/$TOOL"
  tar -xzf "$FILE" -C "$SEARCH_DIR/$TOOL" --strip-components=1
  [[ -x "$SEARCH_DIR/$TOOL/$TOOL" ]] || die "$TOOL binary missing in $(basename "$URL")"
done < <(python3 - "$SEARCH_JSON" <<'PY'
import json, sys
for name, tool in json.load(open(sys.argv[1]))["tools"].items():
    print(name, tool["url"], tool["sha256"])
PY
)

# --- Assemble the bundle -----------------------------------------------------
say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN/Pippa" "$APP/Contents/MacOS/Pippa"
printf 'APPL????' > "$APP/Contents/PkgInfo"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" -e "s/__YEAR__/$(date +%Y)/g" \
  "$PACKAGING/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Localized Info.plist texts (permission prompts, copyright, document type) and the
# Services menu title: Contents/Resources/<language>.lproj/{InfoPlist,ServicesMenu}.strings.
for lproj in "$PACKAGING"/Localization/*.lproj; do
  target="$APP/Contents/Resources/$(basename "$lproj")"
  mkdir -p "$target"
  for strings in "$lproj"/*.strings; do
    sed -e "s/__YEAR__/$(date +%Y)/g" "$strings" > "$target/$(basename "$strings")"
    plutil -lint "$target/$(basename "$strings")" >/dev/null || die "$(basename "$lproj")/$(basename "$strings") invalid"
  done
done
echo "    Localizations: $(cd "$PACKAGING/Localization" && echo *.lproj)"

# SwiftPM resources: Bundle.module looks in Bundle.main.resourceURL first
# (see DerivedSources/resource_bundle_accessor.swift), i.e. Contents/Resources.
# cp -R keeps each bundle's en.lproj/de.lproj (UI translations, see docs/development.md "Localization").
shopt -s nullglob
bundles=("$BIN"/*.bundle)
for b in "${bundles[@]}"; do
  cp -R "$b" "$APP/Contents/Resources/"
  echo "    Resources: $(basename "$b")"
done
# Dynamic SwiftPM dependencies (should there ever be any) go to Frameworks.
frameworks=("$BIN"/PackageFrameworks/*.framework)
if [[ -d "$BIN/Sparkle.framework" ]]; then frameworks+=("$BIN/Sparkle.framework"); fi
if ((${#frameworks[@]})); then
  cp -R "${frameworks[@]}" "$APP/Contents/Frameworks/"
  otool -l "$APP/Contents/MacOS/Pippa" | grep -q '@executable_path/../Frameworks' ||
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Pippa"
fi
shopt -u nullglob

cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Pi is bundled by default. Customers never need a separate Node/npm install.
say "Node, web access, Pi install payload, abilities"
# Node (Contents/Helpers/node) and Pippa's web access for Pi (Contents/Resources/pippa-web: pi-web-access).
"$ROOT/scripts/bundle-web.sh" "$APP"
# Install payload for Pi's standard location (PiInstaller): pinned release in layout releases-v1 plus npm.
# Node itself comes from Contents/Helpers/node, not duplicated.
"$ROOT/scripts/bundle-pi-payload.sh" "$APP/Contents/Resources/pi-payload"
# fd and rg next to Node: Pi's PATH starts with Node's folder (PiInstaller.baseEnvironment), so find and grep use these.
for TOOL in fd rg; do
  cp "$SEARCH_DIR/$TOOL/$TOOL" "$APP/Contents/Helpers/$TOOL"
  for LICENSE in $(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['tools'][sys.argv[2]]['licenses']))" "$SEARCH_JSON" "$TOOL"); do
    cp "$SEARCH_DIR/$TOOL/$LICENSE" "$APP/Contents/Resources/$TOOL-$LICENSE.txt"
  done
done
# Pippa's curated abilities (SKILL.md per folder; PippaSkill.bundledDirectory). Pi loads them with --skill (PippaPiLaunch).
cp -R "$ROOT/runtime/pippa-skills" "$APP/Contents/Resources/pippa-skills"
find "$APP/Contents/Resources/pippa-skills" -name '.DS_Store' -delete
echo "    Resources: pippa-skills ($(find "$APP/Contents/Resources/pippa-skills" -name SKILL.md | wc -l | tr -d ' ') abilities)"
# Pippa's Pi extensions (file tools, helps for small models, MCP connection) for the Pi RPC path.
# Only the sources Pi loads; tests stay out.
mkdir -p "$APP/Contents/Resources/pippa-tools"
for f in $(runtime_files pippa-tools); do
  cp "$ROOT/runtime/pippa-tools/$f" "$APP/Contents/Resources/pippa-tools/$f"
done
# The file lists verify-app.sh and the runtime probe (Pippa --verify-runtime) check the bundle against.
cp "$PACKAGING/runtime-files.json" "$APP/Contents/Resources/runtime-files.json"
# Provider discovery and native sign-in through Pi's public APIs; tests stay out.
mkdir -p "$APP/Contents/Resources/pippa-auth"
cp "$ROOT/runtime/pippa-auth/pi-providers.mjs" "$APP/Contents/Resources/pippa-auth/pi-providers.mjs"

# --- App icon ----------------------------------------------------------------
say "App icon"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$PACKAGING/make-icon.swift" "$ICON_WORK/icon-1024.png" 1024
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- Signing -----------------------------------------------------------------
# Quarantine and other extended attributes upset codesign ("detritus").
xattr -cr "$APP"
# Apple's timestamp service fails now and then ("The timestamp service is not available"); two release runs on
# 2026-10-09 died on it while a direct codesign --timestamp a minute later worked. Retry only that error.
sign_retry() {
  local attempt err
  for attempt in 1 2 3 4; do
    if err="$("$@" 2>&1)"; then [[ -n "$err" ]] && printf '%s\n' "$err"; return 0; fi
    printf '%s\n' "$err" >&2
    [[ "$err" == *"timestamp service is not available"* && $attempt -lt 4 ]] || return 1
    sleep $(( attempt * 5 ))
  done
}
if [[ -n "$IDENTITY" ]]; then
  say "Signing with \"${IDENTITY}\""
  SIGN=(sign_retry codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
  say "Signing ad hoc"
  SIGN=(codesign --force --timestamp=none --sign -)
fi
# Hardened Runtime enforces library validation: every dylib must carry the same
# team ID as the process. With a Developer ID that holds (everything is re-signed
# here), hence no cs.disable-library-validation. Ad-hoc signatures have no team
# ID, so dyld would reject the dylibs ("different Team IDs"). Ad hoc, the app and
# Sparkle also run without Hardened Runtime. Developer ID builds keep Hardened
# Runtime and library validation. An ad-hoc build cannot be notarized anyway.
# No App Sandbox (Pi has to work in the home folder and run commands the person approves): Pippa.entitlements
# holds only Hardened Runtime rights, Node.entitlements JIT + library validation off
# (it is copied to ~/.local/share/pi-node for the terminal Pi), all other helpers
# (fd, rg, esbuild) carry no entitlements at all.
if [[ -n "$IDENTITY" ]]; then
  SIGN_HELPER=("${SIGN[@]}")
else
  SIGN_HELPER=(codesign --force --timestamp=none --sign -)
fi
# Inside out: dylibs, helpers, app. No --deep signing (it overwrites entitlements).
for lib in "$APP"/Contents/Frameworks/*.dylib; do [[ -e "$lib" ]] && "${SIGN_HELPER[@]}" "$lib"; done
for fw in "$APP"/Contents/Frameworks/*.framework; do
  if [[ -e "$fw" ]]; then
    if [[ "$(basename "$fw")" == Sparkle.framework ]]; then
      # Sparkle without App Sandbox: its XPC services are unused (no SUEnableInstallerLauncherService /
      # SUEnableDownloaderService) and may be removed (https://sparkle-project.org/documentation/sandboxing/).
      # Then sign installer and updater from the inside out.
      sparkle_version="$fw/Versions/B"
      rm -rf "$fw/XPCServices" "$sparkle_version/XPCServices"
      "${SIGN[@]}" "$sparkle_version/Autoupdate"
      "${SIGN[@]}" "$sparkle_version/Updater.app"
    fi
    "${SIGN[@]}" "$fw"
  fi
done
while IFS= read -r -d '' addon; do
  "${SIGN_HELPER[@]}" "$addon"
done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -name '*.node' -print0)
# esbuild (used by Pi extension loading) is a real native executable too.
# Sign every executable Mach-O in the dependency tree, not just .node add-ons. No entitlements:
# the installer copies them out of the bundle with their signature, and they run without a sandbox.
while IFS= read -r -d '' helper; do
  if [[ "$helper" != *.node ]] && file -b "$helper" | grep -q 'Mach-O.*executable'; then
    "${SIGN_HELPER[@]}" "$helper"
  fi
done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -perm -111 -print0)
"${SIGN_HELPER[@]}" --identifier io.github.tschnorpfeil.pippa.node \
  --entitlements "$PACKAGING/Node.entitlements" "$APP/Contents/Helpers/node"
"${SIGN_HELPER[@]}" --identifier io.github.tschnorpfeil.pippa.fd "$APP/Contents/Helpers/fd"
"${SIGN_HELPER[@]}" --identifier io.github.tschnorpfeil.pippa.rg "$APP/Contents/Helpers/rg"
"${SIGN[@]}" --entitlements "$PACKAGING/Pippa.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

say "Done: $APP ($(du -sh "$APP" | cut -f1))"
if [[ -z "$IDENTITY" ]]; then
  warn "Signed ad hoc. This runs on your Mac; friends who download Pippa
         hit Gatekeeper (\"Pippa kann nicht geöffnet werden\") and must confirm under
         System Settings → Privacy & Security → \"Open Anyway\".
         For real distribution: set PIPPA_SIGN_IDENTITY and notarize with make-dmg.sh
         and PIPPA_NOTARY_PROFILE (see docs/development.md)."
fi
