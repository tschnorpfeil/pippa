#!/usr/bin/env bash
# Pinned Node (Contents/Helpers/node) + Pippa's web access for Pi (Contents/Resources/pippa-web) in an app.
# Node serves two things: the Pi install payload (PiInstaller copies it to ~/.local/share/pi-node) and Pi itself.
# pippa-web is runtime/pippa-web: index.ts plus the pinned Pi package pi-web-access from its own lockfile; no system npm/node.
# Signing happens in build-app.sh after this returns.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: bundle-web.sh /path/to/Pippa.app}"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}"
NPM_CACHE="${PIPPA_NPM_CACHE:-$ROOT/.build/npm-cache}"
MANIFEST="$ROOT/app/Packaging/node-release.json"
read -r VERSION ASSET SHA < <(python3 - "$MANIFEST" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); print(m['version'],m['asset'],m['sha256'])
PY
)
mkdir -p "$CACHE"
ARCHIVE="$CACHE/$ASSET"
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
if [[ -f "$ARCHIVE" && "$(sha_of "$ARCHIVE")" != "$SHA" ]]; then rm -f "$ARCHIVE"; fi
if [[ ! -f "$ARCHIVE" ]]; then
  curl -fL --retry 3 --progress-bar -o "$ARCHIVE.part" "https://nodejs.org/dist/$VERSION/$ASSET"
  [[ "$(sha_of "$ARCHIVE.part")" == "$SHA" ]] || { rm -f "$ARCHIVE.part"; echo 'Node SHA256 mismatch' >&2; exit 1; }
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK"
NODE_DIR="$WORK/node-$VERSION-darwin-arm64"
NODE="$NODE_DIR/bin/node"
NPM=("$NODE" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js")
[[ "$("$NODE" --version)" == "$VERSION" ]] || { echo 'Unexpected Node version' >&2; exit 1; }
STAGE="$WORK/pippa-web"
mkdir -p "$STAGE"
cp "$ROOT/runtime/pippa-web/package.json" "$ROOT/runtime/pippa-web/package-lock.json" "$ROOT/runtime/pippa-web/index.ts" "$STAGE/"
# Only what Pi loads: no dev dependencies (the test-only Pi), no install scripts.
(cd "$STAGE" && PATH="$NODE_DIR/bin:$PATH" npm_config_cache="$NPM_CACHE" "${NPM[@]}" ci --omit=dev --ignore-scripts --no-audit --no-fund)
# The Pi packages are peers of pi-web-access, so npm installs them despite --omit=dev. The running Pi hands its own
# copies to extensions (jiti aliases in Pi's extension loader), so they and their dangling .bin links go.
rm -rf "$STAGE/node_modules/@earendil-works"
find "$STAGE/node_modules/.bin" -type l ! -exec test -e {} \; -delete
[[ ! -e "$STAGE/node_modules/@earendil-works/pi-coding-agent" ]] || { echo 'pippa-web ships its test-only Pi (dev dependency)' >&2; exit 1; }
[[ -f "$STAGE/node_modules/pi-web-access/dist/index.js" ]] || { echo 'pi-web-access missing in pippa-web' >&2; exit 1; }
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources"
[[ ! -e "$APP/Contents/Resources/pippa-web" ]] || { echo 'pippa-web already exists; build a fresh app bundle' >&2; exit 1; }
cp "$NODE" "$APP/Contents/Helpers/node"
cp "$NODE_DIR/LICENSE" "$APP/Contents/Resources/Node-LICENSE.txt"
cp "$MANIFEST" "$APP/Contents/Resources/node-release.json"
mv "$STAGE" "$APP/Contents/Resources/pippa-web"
echo "    Helpers: Node $VERSION; Resources: pippa-web (pi-web-access, $(du -sh "$APP/Contents/Resources/pippa-web" | cut -f1))"
