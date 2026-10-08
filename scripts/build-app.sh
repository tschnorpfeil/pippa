#!/usr/bin/env bash
# Builds dist/Pippa.app (arm64): SwiftPM release, Info.plist, resource bundles,
# app icon, llama-server built from the pinned llama.cpp source plus Pippa's patches, signing.
#
#   scripts/build-app.sh
#
# Environment:
#   PIPPA_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"; without: ad hoc
#   PIPPA_SKIP_BUILD=1   use the existing release build (no swift build)
#   PIPPA_CACHE          download and llama.cpp build cache (default ~/Library/Caches/pippa-build)
#   PIPPA_CMAKE          cmake to build llama-server with (default: cmake from PATH); PIPPA_NINJA likewise
#   PIPPA_REQUIRE_DISTRIBUTION=1  Developer ID mandatory (release pipeline)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/app"
PACKAGING="$APP_SRC/Packaging"
DIST="$ROOT/dist"
APP="$DIST/Pippa.app"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}"
RELEASE_JSON="$ROOT/app/Packaging/llama-release.json"
IDENTITY="${PIPPA_SIGN_IDENTITY:-}"
if [[ "${PIPPA_REQUIRE_DISTRIBUTION:-0}" == 1 && "$IDENTITY" != "Developer ID Application:"* ]]; then
  printf 'Error: a release needs PIPPA_SIGN_IDENTITY with a Developer ID Application.\n' >&2
  exit 1
fi

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
for tool in swift codesign iconutil sips plutil install_name_tool otool shasum curl python3 tar; do
  command -v "$tool" >/dev/null || die "$tool missing (Command Line Tools installed?)"
done

# --- Version -----------------------------------------------------------------
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$APP_SRC/Sources/PippaCore/PippaCore.swift" | head -1)"
[[ -n "$VERSION" ]] || die "Pippa.version not found in app/Sources/PippaCore/PippaCore.swift"
# Build number = base + commit count. The base keeps builds above those of the archived repository (up to 282)
# now that the public repository starts with a single commit; Sparkle only offers higher builds.
COMMITS="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD="$(( $(tr -d '[:space:]' < "$ROOT/app/Packaging/build-number-base") + COMMITS ))"
say "Pippa $VERSION ($BUILD)"

# --- Default models pinned (catalog.json) -----------------------------------
# A model from ModelSelector's table without revision and SHA256 cannot be downloaded: never ship that.
# PIPPA_ALLOW_UNPINNED=1 only for local test builds, never for a distribution build.
if ! python3 "$ROOT/scripts/check-default-models.py"; then
  if [[ "${PIPPA_ALLOW_UNPINNED:-0}" == 1 && "${PIPPA_REQUIRE_DISTRIBUTION:-0}" != 1 ]]; then
    warn "default model not pinned (PIPPA_ALLOW_UNPINNED=1): this build cannot set up 16 GB Macs and up"
  else
    die "default model not pinned; run scripts/pin-model.sh (see above)"
  fi
fi

# --- SwiftPM-Release ---------------------------------------------------------
if [[ "${PIPPA_SKIP_BUILD:-}" != 1 ]]; then
  say "swift build -c release --arch arm64"
  (cd "$APP_SRC" && swift build -c release --arch arm64 --product Pippa)
fi
BIN="$(cd "$APP_SRC" && swift build -c release --arch arm64 --show-bin-path)"
[[ -x "$BIN/Pippa" ]] || die "no release binary at $BIN/Pippa"

# --- llama.cpp (pinned source + Pippa patches, built here) -------------------
# Not the official binary: the K2 Horizon parser of b11503 needs a patch (app/Packaging/llama-patches).
# Source tarball and patches are checksum-pinned in llama-release.json ("bundled").
find_cmake() {
  if [[ -n "${PIPPA_CMAKE:-}" ]]; then
    [[ -x "$PIPPA_CMAKE" ]] || die "PIPPA_CMAKE=$PIPPA_CMAKE is not an executable"
    printf '%s\n' "$PIPPA_CMAKE"
  elif command -v cmake >/dev/null; then
    command -v cmake
  else
    die "cmake missing: llama-server is built from source. Install cmake (e.g. brew install cmake, or pip install cmake ninja in a venv) or set PIPPA_CMAKE=/path/to/cmake"
  fi
}
CMAKE="$(find_cmake)"
# Prefer Ninja (also next to a venv cmake), else Makefiles.
NINJA="${PIPPA_NINJA:-$(command -v ninja || true)}"
[[ -n "$NINJA" || ! -x "$(dirname "$CMAKE")/ninja" ]] || NINJA="$(dirname "$CMAKE")/ninja"
if [[ -n "$NINJA" ]]; then GENERATOR=(-G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA"); else GENERATOR=(-G "Unix Makefiles"); fi
command -v patch >/dev/null || die "patch missing (Command Line Tools installed?)"

LLAMA_INFO="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
b = r["bundled"]
print(b["tag"]); print(b["source"]); print(b["sourceSha256"])
print(" ".join(b["cmake"]))
for p in b["patches"]:
    print("PATCH " + p["file"] + " " + p["sha256"])
PY
)"
LLAMA_TAG="$(sed -n 1p <<<"$LLAMA_INFO")"
LLAMA_URL="$(sed -n 2p <<<"$LLAMA_INFO")"
LLAMA_SHA="$(sed -n 3p <<<"$LLAMA_INFO")"
read -r -a LLAMA_CMAKE_ARGS <<<"$(sed -n 4p <<<"$LLAMA_INFO")"
[[ -n "$LLAMA_SHA" && "$LLAMA_URL" == https://github.com/ggml-org/llama.cpp/* ]] || die "bundled source missing or unexpected in $RELEASE_JSON"
mkdir -p "$CACHE"
ARCHIVE="$CACHE/llama.cpp-$LLAMA_TAG.tar.gz"
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
if [[ -f "$ARCHIVE" && "$(sha_of "$ARCHIVE")" != "$LLAMA_SHA" ]]; then
  warn "cached file has the wrong checksum, downloading again"
  rm -f "$ARCHIVE"
fi
if [[ ! -f "$ARCHIVE" ]]; then
  say "Downloading llama.cpp $LLAMA_TAG source"
  curl -fL --retry 3 --progress-bar -o "$ARCHIVE.part" "$LLAMA_URL"
  ACTUAL="$(sha_of "$ARCHIVE.part")"
  if [[ "$ACTUAL" != "$LLAMA_SHA" ]]; then
    rm -f "$ARCHIVE.part"
    die "SHA256 of the llama.cpp source does not match: expected $LLAMA_SHA, got $ACTUAL"
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
say "llama.cpp $LLAMA_TAG source verified (sha256 $LLAMA_SHA)"

PATCHES=()
PATCH_KEY=""
while read -r _ pfile psha; do
  [[ -f "$PACKAGING/$pfile" ]] || die "patch $pfile missing"
  [[ "$(sha_of "$PACKAGING/$pfile")" == "$psha" ]] || die "patch $pfile does not match the SHA256 in $RELEASE_JSON"
  PATCHES+=("$PACKAGING/$pfile")
  PATCH_KEY+="$psha"
done < <(grep '^PATCH ' <<<"$LLAMA_INFO")

# Build tree is keyed by source + patches + flags: any change starts from a clean tree, otherwise it is reused (incremental).
BUILD_KEY="$(printf '%s|%s|%s|%s' "$LLAMA_SHA" "$PATCH_KEY" "${LLAMA_CMAKE_ARGS[*]}" "${GENERATOR[*]}" | shasum -a 256 | cut -c1-12)"
LLAMA_DIR="$CACHE/llama-$LLAMA_TAG-$BUILD_KEY"
LLAMA_SRC="$LLAMA_DIR/src"
LLAMA_BUILD="$LLAMA_DIR/build"
if [[ ! -f "$LLAMA_DIR/.patched" ]]; then
  rm -rf "$LLAMA_DIR"
  mkdir -p "$LLAMA_SRC"
  tar -xzf "$ARCHIVE" -C "$LLAMA_SRC" --strip-components=1
  for p in "${PATCHES[@]}"; do
    say "Applying $(basename "$p")"
    patch -p1 --batch -d "$LLAMA_SRC" -i "$p" || die "patch $(basename "$p") does not apply to llama.cpp $LLAMA_TAG"
  done
  touch "$LLAMA_DIR/.patched"
fi
say "Building llama-server $LLAMA_TAG (cmake: $CMAKE)"
"$CMAKE" -S "$LLAMA_SRC" -B "$LLAMA_BUILD" "${GENERATOR[@]}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  "${LLAMA_CMAKE_ARGS[@]}" >"$LLAMA_DIR/configure.log" 2>&1 || { tail -30 "$LLAMA_DIR/configure.log" >&2; die "llama.cpp configure failed (log: $LLAMA_DIR/configure.log)"; }
"$CMAKE" --build "$LLAMA_BUILD" --target llama-server -j "$(sysctl -n hw.ncpu)" >"$LLAMA_DIR/build.log" 2>&1 ||
  { tail -30 "$LLAMA_DIR/build.log" >&2; die "llama.cpp build failed (log: $LLAMA_DIR/build.log)"; }
LLAMA_BIN="$LLAMA_BUILD/bin/llama-server"
[[ -x "$LLAMA_BIN" ]] || die "no llama-server at $LLAMA_BIN"
# Static build: everything except system libraries/frameworks must be inside the binary.
if otool -L "$LLAMA_BIN" | awk 'NR > 1 { print $1 }' | grep -q '^@rpath/'; then
  die "llama-server links shared libraries (@rpath); expected a static build (-DBUILD_SHARED_LIBS=OFF in llama-release.json)"
fi

# --- fd and ripgrep for Pi's find and grep (pinned, checksum-verified) -------
SEARCH_JSON="$ROOT/app/Packaging/search-tools.json"
SEARCH_DIR="$CACHE/search-tools"
mkdir -p "$SEARCH_DIR"
while read -r TOOL URL SHA; do
  FILE="$CACHE/$(basename "$URL")"
  if [[ -f "$FILE" && "$(sha_of "$FILE")" != "$SHA" ]]; then rm -f "$FILE"; fi
  if [[ ! -f "$FILE" ]]; then
    say "Downloading $TOOL ($(basename "$URL"))"
    curl -fL --retry 3 --progress-bar -o "$FILE.part" "$URL"
    ACTUAL="$(sha_of "$FILE.part")"
    [[ "$ACTUAL" == "$SHA" ]] || { rm -f "$FILE.part"; die "SHA256 of $(basename "$URL") does not match: expected $SHA, got $ACTUAL"; }
    mv "$FILE.part" "$FILE"
  fi
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

# llama-server (static build, no dylibs) goes to Helpers.
cp "$LLAMA_BIN" "$APP/Contents/Helpers/llama-server"
cp "$LLAMA_SRC/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
echo "    Helpers: llama-server $LLAMA_TAG (patched, static, $(du -h "$APP/Contents/Helpers/llama-server" | cut -f1 | tr -d ' '))"

# Pi is bundled by default. Customers never need a separate Node/npm install.
say "Node, web fetcher, Pi install payload, abilities"
# Node (Contents/Helpers/node) and Pippa's own web fetcher (Contents/Resources/pippa-web).
"$ROOT/scripts/bundle-web-fetcher.sh" "$APP"
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
# Pippa's guard and Pi extensions (tools, MCP connection) for the Pi RPC path.
# Only the sources Pi loads; tests and restore.mjs (the app does undo itself, PiUndo) stay out.
mkdir -p "$APP/Contents/Resources/pippa-guard"
for f in pippa-guard.ts pippa-tools.ts pippa-mcp.ts files.ts policy.ts self-asking.ts budget.ts; do
  cp "$ROOT/runtime/pippa-guard/$f" "$APP/Contents/Resources/pippa-guard/$f"
done

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
if [[ -n "$IDENTITY" ]]; then
  say "Signing with \"${IDENTITY}\""
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
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
# (llama-server, esbuild) carry no entitlements at all.
if [[ -n "$IDENTITY" ]]; then
  SIGN_LLAMA=("${SIGN[@]}")
else
  SIGN_LLAMA=(codesign --force --timestamp=none --sign -)
fi
# Inside out: dylibs, helpers, app. No --deep signing (it overwrites entitlements).
for lib in "$APP"/Contents/Frameworks/*.dylib; do [[ -e "$lib" ]] && "${SIGN_LLAMA[@]}" "$lib"; done
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
  "${SIGN_LLAMA[@]}" "$addon"
done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -name '*.node' -print0)
# esbuild (used by Pi extension loading) is a real native executable too.
# Sign every executable Mach-O in the dependency tree, not just .node add-ons. No entitlements:
# the installer copies them out of the bundle with their signature, and they run without a sandbox.
while IFS= read -r -d '' helper; do
  if [[ "$helper" != *.node ]] && file -b "$helper" | grep -q 'Mach-O.*executable'; then
    "${SIGN_LLAMA[@]}" "$helper"
  fi
done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -perm -111 -print0)
"${SIGN_LLAMA[@]}" --identifier io.github.tschnorpfeil.pippa.node \
  --entitlements "$PACKAGING/Node.entitlements" "$APP/Contents/Helpers/node"
"${SIGN_LLAMA[@]}" --identifier io.github.tschnorpfeil.pippa.llama-server "$APP/Contents/Helpers/llama-server"
"${SIGN_LLAMA[@]}" --identifier io.github.tschnorpfeil.pippa.fd "$APP/Contents/Helpers/fd"
"${SIGN_LLAMA[@]}" --identifier io.github.tschnorpfeil.pippa.rg "$APP/Contents/Helpers/rg"
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
