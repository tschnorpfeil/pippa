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
# What only those Pi packages needed stays behind otherwise (the provider SDKs openai, @anthropic-ai/sdk, @google/genai,
# @aws-sdk, …: about 75 MB and 10,000 files). Keep only what pippa-web's own dependencies reach, resolved like Node does.
python3 - "$STAGE" <<'PY'
import json, os, shutil, sys
stage = os.path.realpath(sys.argv[1])  # /var is /private/var on macOS
modules = os.path.join(stage, "node_modules")
def manifest(directory):
    with open(os.path.join(directory, "package.json")) as f:
        return json.load(f)
def resolve(name, directory):
    while True:
        candidate = os.path.join(directory, "node_modules", name)
        if os.path.isfile(os.path.join(candidate, "package.json")):
            return os.path.realpath(candidate)
        if directory == stage or not directory.startswith(stage):
            return None
        directory = os.path.dirname(directory)
reached, todo = set(), [stage]
while todo:
    directory = todo.pop()
    m = manifest(directory)
    names = list(m.get("dependencies", {})) + list(m.get("optionalDependencies", {}))
    names += [n for n in m.get("peerDependencies", {}) if not n.startswith("@earendil-works/")]
    for name in names:
        found = resolve(name, directory)
        if found and found not in reached:
            reached.add(found)
            todo.append(found)
def packages(directory):
    for entry in sorted(os.listdir(directory)):
        path = os.path.join(directory, entry)
        if entry.startswith(".") or not os.path.isdir(path) or os.path.islink(path):
            continue
        if entry.startswith("@"):
            yield from packages(path)
        else:
            yield path
removed = 0
def prune(directory):
    global removed
    for package in packages(directory):
        if os.path.realpath(package) not in reached:
            shutil.rmtree(package)
            removed += 1
        elif os.path.isdir(os.path.join(package, "node_modules")):
            prune(os.path.join(package, "node_modules"))
prune(modules)
for scope in os.listdir(modules):
    path = os.path.join(modules, scope)
    if scope.startswith("@") and os.path.isdir(path) and not os.listdir(path):
        os.rmdir(path)
print(f"    pippa-web: {len(reached)} packages kept, {removed} only the Pi packages needed removed")
PY
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
