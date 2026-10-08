#!/usr/bin/env bash
# Pinned Node (Contents/Helpers/node) + Pippa's own web fetcher (Contents/Resources/pippa-web) in an app.
# Node serves three things: the web fetcher (WebFetcher.swift), the Pi install payload (PiInstaller copies it to
# ~/.local/share/pi-node) and Pi itself. The fetcher is runtime/pippa-web with its own lockfile; no system npm/node.
# Signing happens in build-app.sh after this returns.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: bundle-web-fetcher.sh /path/to/Pippa.app}"
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
cp "$ROOT/runtime/pippa-web/package.json" "$ROOT/runtime/pippa-web/package-lock.json" "$ROOT/runtime/pippa-web/build-web-provider.mjs" "$STAGE/"
cp -R "$ROOT/runtime/pippa-web/src" "$STAGE/"
rm -rf "$STAGE/src/generated"
# esbuild is a dev dependency: install everything, bundle the two pi-web-access entry points, then drop dev packages.
(cd "$STAGE" && PATH="$NODE_DIR/bin:$PATH" npm_config_cache="$NPM_CACHE" "${NPM[@]}" ci --ignore-scripts --no-audit --no-fund)
(cd "$STAGE" && "$NODE" build-web-provider.mjs)
(cd "$STAGE" && PATH="$NODE_DIR/bin:$PATH" npm_config_cache="$NPM_CACHE" "${NPM[@]}" prune --omit=dev --ignore-scripts --no-audit --no-fund)
rm "$STAGE/build-web-provider.mjs"
[[ ! -e "$STAGE/node_modules/esbuild" ]] || { echo 'esbuild left in the fetcher (dev dependency)' >&2; exit 1; }
# Importing the fetcher must not start serving; its generated pi-web-access bundles must load with the shipped node_modules.
"$NODE" --input-type=module -e "const m = await import(process.argv[1]); if (typeof m.createFetcher !== 'function' || typeof m.serve !== 'function') throw new Error('fetcher exports missing'); await import(process.argv[2]); await import(process.argv[3]); console.log('Web fetcher imports successfully')" "$STAGE/src/fetcher.mjs" "$STAGE/src/generated/extract.mjs" "$STAGE/src/generated/duckduckgo.mjs" </dev/null
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources"
[[ ! -e "$APP/Contents/Resources/pippa-web" ]] || { echo 'pippa-web already exists; build a fresh app bundle' >&2; exit 1; }
cp "$NODE" "$APP/Contents/Helpers/node"
cp "$NODE_DIR/LICENSE" "$APP/Contents/Resources/Node-LICENSE.txt"
cp "$MANIFEST" "$APP/Contents/Resources/node-release.json"
mv "$STAGE" "$APP/Contents/Resources/pippa-web"
echo "    Helpers: Node $VERSION; Resources: pippa-web (web fetcher, $(du -sh "$APP/Contents/Resources/pippa-web" | cut -f1))"
