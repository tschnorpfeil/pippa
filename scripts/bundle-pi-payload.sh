#!/usr/bin/env bash
# Pi install payload: the pinned Pi release in layout `releases-v1`
# (package.json, package-lock.json, metadata.json, node_modules with .bin/pi), as Pi's own installer creates it under
# ~/.pi/agent/install/releases/<version>. Pippa's installer (PiInstaller) copies the `release` folder there as an APFS
# clone. Also npm from the pinned Node archive, so `pi update` in the terminal works without a Node/npm of its own.
#
#   scripts/bundle-pi-payload.sh <target-dir> [--with-node]
#
# Result:
#   <target>/release/{package.json,package-lock.json,metadata.json,node_modules}
#   <target>/lib/node_modules/npm, <target>/Node-LICENSE.txt
#   <target>/extensions/pippa-local-server   Pippa's terminal extension (starts the llama-server for `pi` in the terminal)
#   <target>/bin/node            only with --with-node (development, tests); in the app, Node lives in Contents/Helpers/node
#
# Inputs: app/Packaging/pi-release/{package.json,package-lock.json,metadata.json} (the release's official files) and
# app/Packaging/node-release.json. No system Node/npm; npm cache under $PIPPA_NPM_CACHE (default: .build/npm-cache).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?Usage: bundle-pi-payload.sh <dir> [--with-node]}"
WITH_NODE="${2:-}"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}"
NPM_CACHE="${PIPPA_NPM_CACHE:-$ROOT/.build/npm-cache}"
RELEASE_SRC="$ROOT/app/Packaging/pi-release"
MANIFEST="$ROOT/app/Packaging/node-release.json"
[[ ! -e "$DEST/release" ]] || { echo "$DEST/release already exists; use a fresh directory" >&2; exit 1; }

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
[[ "$("$NODE" --version)" == "$VERSION" ]] || { echo 'Unexpected Node version' >&2; exit 1; }

# metadata.json: fields as in the real release (schemaVersion, version, sourceCommit, publishedAt, packages).
# Checked against package.json and the lockfile; the official lockfile has no `integrity` for the @earendil-works
# packages, it comes from metadata.json here so `npm ci` verifies those tarballs too.
STAGE="$WORK/release"
mkdir -p "$STAGE"
PI_VERSION="$(python3 - "$RELEASE_SRC" "$STAGE" <<'PY'
import json, sys, pathlib
src, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
pkg = json.loads((src / "package.json").read_text())
lock = json.loads((src / "package-lock.json").read_text())
meta = json.loads((src / "metadata.json").read_text())
version = pkg["dependencies"]["@earendil-works/pi-coding-agent"]
assert pkg["version"] == version == meta["version"] == lock["version"], "release versions disagree"
assert meta["schemaVersion"] == 1 and meta["sourceCommit"] and meta["publishedAt"], "metadata incomplete"
by_name = {p["name"]: p for p in meta["packages"]}
for key, entry in lock["packages"].items():
    name = key.removeprefix("node_modules/")
    if name in by_name:
        known = by_name[name]
        assert entry["version"] == known["version"] and entry["resolved"] == known["tarball"], f"{name} differs"
        if "integrity" in entry:
            assert entry["integrity"] == known["integrity"], f"{name} integrity differs"
        entry["integrity"] = known["integrity"]
assert "node_modules/@earendil-works/pi-coding-agent" in lock["packages"]
out = {k: meta[k] for k in ("schemaVersion", "version", "sourceCommit", "publishedAt")}
out["packages"] = [{k: p[k] for k in ("name", "version", "tarball", "integrity")} for p in meta["packages"]]
(stage / "metadata.json").write_text(json.dumps(out, indent="\t") + "\n")
(stage / "package.json").write_bytes((src / "package.json").read_bytes())
(stage / "package-lock.json").write_text(json.dumps(lock, indent="\t") + "\n")
print(version)
PY
)"
(cd "$STAGE" && PATH="$NODE_DIR/bin:$PATH" npm_config_cache="$NPM_CACHE" "$NODE" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" \
  ci --ignore-scripts --omit=dev --include=optional --no-fund --no-audit --loglevel=error --progress=false)
# As in the real release: the official lockfile, unchanged.
cp "$RELEASE_SRC/package-lock.json" "$STAGE/package-lock.json"
# Only the platform Pippa supports. JS and licenses stay.
NATIVE="$STAGE/node_modules/@earendil-works/pi-tui/native"
for other in "$NATIVE/linux" "$NATIVE/win32" "$NATIVE/darwin/prebuilds/darwin-x64"; do
  if [[ -d "$other" ]]; then rm -rf "$other"; fi
done

# Check the layout: .bin/pi points to the pi-coding-agent CLI and reports the pinned version.
[[ -L "$STAGE/node_modules/.bin/pi" ]] || { echo 'node_modules/.bin/pi missing' >&2; exit 1; }
[[ "$(readlink "$STAGE/node_modules/.bin/pi")" == "../@earendil-works/pi-coding-agent/dist/bundle/cli.js" ]] || { echo 'unexpected .bin/pi target' >&2; exit 1; }
FOUND="$(PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 "$NODE" "$STAGE/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" --version)"
[[ "$FOUND" == "$PI_VERSION" ]] || { echo "pi --version: $FOUND, expected $PI_VERSION" >&2; exit 1; }

mkdir -p "$DEST/lib/node_modules"
mv "$STAGE" "$DEST/release"
# Pippa's terminal extension (runtime/pippa-local-server): PiInstaller copies it to ~/.pi/agent/extensions so that
# `pi` in the terminal starts Pippa's llama-server itself. Runtime files only, no tests.
mkdir -p "$DEST/extensions/pippa-local-server"
for f in index.ts common.mjs ensure.mjs supervisor.mjs; do
  cp "$ROOT/runtime/pippa-local-server/$f" "$DEST/extensions/pippa-local-server/$f"
done
cp -R "$NODE_DIR/lib/node_modules/npm" "$DEST/lib/node_modules/npm"
cp "$NODE_DIR/LICENSE" "$DEST/Node-LICENSE.txt"
if [[ "$WITH_NODE" == --with-node ]]; then
  mkdir -p "$DEST/bin"
  cp "$NODE" "$DEST/bin/node"
fi
echo "    Resources: Pi $PI_VERSION install payload (releases-v1), npm from Node $VERSION ($(du -sh "$DEST" | cut -f1))"
