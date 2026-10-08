#!/bin/bash
# Moves Pippa to another Pi release in one step (docs/updating-pi.md). Updates every pin, rebuilds the payload and
# runs the Pi gates. Local only: no commit, no push, no real model, never touches ~/.pi or ~/.local.
#
#   scripts/bump-pi.sh <version>          e.g. scripts/bump-pi.sh 1.1.0
#   scripts/bump-pi.sh <version> --no-gates   only update pins and payload (for a quick look)
#
# Pins it updates:
#   app/Packaging/pi-release/{metadata.json,package.json,package-lock.json}   the official release files the app
#       installs into ~/.pi/agent/install/releases/<v> (from pi.dev's installer API, the same files `pi update` uses)
# Not a Pi pin: runtime/pippa-web (Pippa's web fetcher) depends on pi-web-access + typebox only, no
#   @earendil-works package (checked below); it is tested as a gate but not bumped.
# Gates (all against a fake HOME under .build/):
#   runtime/pippa-web npm test, runtime/pippa-guard node tests (incl. bypass.test.mjs with real Pi),
#   runtime/pippa-local-server node tests (incl. real-pi.test.mjs: `pi -p` starts the server through the extension),
#   scripts/pi-rpc-smoke.mjs (the app's exact flags in RPC mode, scripted stand-in model), PippaChecks with
#   PIPPA_SETUP_CHECKS=1 and PIPPA_MCP_CHECKS=1 against the new payload.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
new="${1:-}"
gates=1; [[ "${2:-}" == --no-gates ]] && gates=0
[[ "$new" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Usage: scripts/bump-pi.sh <exact stable Pi version, e.g. 1.1.0> [--no-gates]' >&2; exit 2;
}
pkg="@earendil-works/pi-coding-agent"
release_dir="$root/app/Packaging/pi-release"
installer_api="${PI_INSTALLER_API_BASE:-https://pi.dev/api/installer/releases}"
old="$(node -p "require('$release_dir/package.json').version")"
echo "== Pi $old -> $new"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# 1. Official release files, checked against npm (a second, independent source for every tarball's integrity).
curl -fsSL "$installer_api/$new" -o "$work/metadata.json"
curl -fsSL "$installer_api/$new/package.json" -o "$work/package.json"
curl -fsSL "$installer_api/$new/package-lock.json" -o "$work/package-lock.json"
node --input-type=module - "$work" "$new" "$pkg" <<'JS'
import fs from "node:fs";
import { execFileSync } from "node:child_process";
const [dir, version, pkg] = process.argv.slice(2);
const read = (f) => JSON.parse(fs.readFileSync(`${dir}/${f}`, "utf8"));
const meta = read("metadata.json"), manifest = read("package.json"), lock = read("package-lock.json");
const fail = (m) => { console.error(`Release files for ${version}: ${m}`); process.exit(1); };
if (meta.schemaVersion !== 1 || meta.version !== version || !meta.sourceCommit || !meta.publishedAt) fail("metadata.json incomplete or wrong version");
if (manifest.version !== version || manifest.dependencies?.[pkg] !== version) fail("package.json does not pin this version");
if (lock.version !== version || lock.packages?.[`node_modules/${pkg}`]?.version !== version) fail("package-lock.json does not lock this version");
// metadata lists every package of the release; the lockfile only those pi-coding-agent installs (as in 1.0.4).
if (!meta.packages.some((p) => p.name === pkg)) fail(`metadata.json does not list ${pkg}`);
for (const p of meta.packages) {
  const locked = lock.packages?.[`node_modules/${p.name}`];
  if (locked && (locked.version !== p.version || locked.resolved !== p.tarball)) fail(`${p.name} differs between metadata and lockfile`);
  const npm = execFileSync("npm", ["view", `${p.name}@${p.version}`, "dist.integrity"], { encoding: "utf8" }).trim();
  if (npm !== p.integrity) fail(`${p.name}@${p.version} integrity differs from npm (${npm} vs ${p.integrity})`);
}
console.log(`   release files ok: ${meta.packages.length} @earendil-works packages, integrity matches npm, commit ${meta.sourceCommit.slice(0, 12)}`);
JS
cp "$work/metadata.json" "$work/package.json" "$work/package-lock.json" "$release_dir/"
if grep -q '"node_modules/@earendil-works/' "$root/runtime/pippa-web/package-lock.json"; then
  echo "runtime/pippa-web now locks an @earendil-works package; pin it to Pi $new by hand." >&2; exit 1
fi
# The license list names the shipped version.
sed -i '' "s#earendil-works/pi) [0-9][0-9.]*#earendil-works/pi) $new#" "$root/THIRD_PARTY_NOTICES.md"

# 2. Payload (what build-app.sh puts into Contents/Resources/pi-payload), with Node for the gates. The old pin's
# payload (from git HEAD) is built too, so the gates can install old -> new in a fake HOME like an app update does.
payload="$root/.build/pi-payload-$new"
rm -rf "$payload"
"$root/scripts/bundle-pi-payload.sh" "$payload" --with-node
previous="$root/.build/pi-payload-$old"
if [[ $gates == 1 && "$old" != "$new" && ! -x "$previous/bin/node" ]]; then
  rm -rf "$previous" "$work/old-repo"
  mkdir -p "$work/old-repo/app/Packaging" "$work/old-repo/scripts"
  git -C "$root" archive HEAD app/Packaging/pi-release app/Packaging/node-release.json scripts/bundle-pi-payload.sh | tar -x -C "$work/old-repo"
  if [[ "$(node -p "require('$work/old-repo/app/Packaging/pi-release/package.json').version")" == "$old" ]]; then
    PIPPA_NPM_CACHE="$root/.build/npm-cache" "$work/old-repo/scripts/bundle-pi-payload.sh" "$previous" --with-node
  fi
fi

# PiRPCClient starts only the tested minor version; a new minor pin needs a deliberate change there.
prefix="$(sed -n -e 's/.*supportedVersionPrefix = "\([0-9.]*\)".*/\1/p' -- "$root/app/Sources/PiRPC/PiRPCClient.swift")"
[[ "$new" == "$prefix"* ]] || { echo "app/Sources/PiRPC/PiRPCClient.swift accepts Pi ${prefix}x, not $new: review the RPC contract, then update supportedVersionPrefix." >&2; exit 1; }

if [[ $gates == 1 ]]; then
  echo "== Gates"
  failed=()
  (cd "$root/runtime/pippa-web" && npm ci --ignore-scripts --no-fund --no-audit --loglevel=error && npm test >"$root/.build/bump-web-test.log" 2>&1) || failed+=("runtime/pippa-web npm test (.build/bump-web-test.log)")
  for t in guard mcp app-entry self-asking bypass; do
    log="$root/.build/bump-guard-$t.log"
    PIPPA_PI_PAYLOAD="$payload" node --experimental-strip-types --test "$root/runtime/pippa-guard/$t.test.mjs" >"$log" 2>&1 || failed+=("guard $t (.build/bump-guard-$t.log)")
    grep -q '^ℹ skipped 0' "$log" || failed+=("guard $t skipped tests")
  done
  log="$root/.build/bump-local-server.log"
  PIPPA_PI_PAYLOAD="$payload" node --experimental-strip-types --test "$root"/runtime/pippa-local-server/test/*.test.mjs >"$log" 2>&1 || failed+=("pippa-local-server (.build/bump-local-server.log)")
  grep -q '^ℹ skipped 0' "$log" || failed+=("pippa-local-server skipped tests")
  node "$root/scripts/pi-rpc-smoke.mjs" "$payload" "$new" || failed+=("RPC smoke")
  swift build --package-path "$root/app" --product PippaChecks >"$root/.build/bump-swift.log" 2>&1 || failed+=("swift build (.build/bump-swift.log)")
  bin="$(swift build --package-path "$root/app" --show-bin-path)"
  for suite in SETUP MCP; do
    log="$root/.build/bump-checks-$suite.log"
    env "PIPPA_${suite}_CHECKS=1" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_PAYLOAD_PREVIOUS="$previous" "$bin/PippaChecks" >"$log" 2>&1 || failed+=("PippaChecks $suite (.build/bump-checks-$suite.log)")
    grep -q '^– Installer mit echter Ladung übersprungen' "$log" && failed+=("PippaChecks $suite skipped the real payload")
  done
  [[ "$old" == "$new" ]] || grep -q '^✓ Pi-Wechsel (echte Ladungen)' "$root/.build/bump-checks-SETUP.log" || failed+=("upgrade $old -> $new with real payloads did not run")
  if ((${#failed[@]})); then printf 'FAILED: %s\n' "${failed[@]}" >&2; exit 1; fi
  echo "   all gates green"
fi

echo; echo "== Pi CHANGELOG $old -> $new (check RPC, extension API, CLI flags, env vars, install layout, models.json, MCP)"
(cd "$work" && npm pack "$pkg@$new" --silent >/dev/null && tar xzf ./*.tgz)
node -e "
const fs = require('fs'), [o, n, f] = process.argv.slice(1);
const v = s => s.split('.').map(Number), gt = (a, b) => { a = v(a); b = v(b); for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i]; return false; };
for (const s of fs.readFileSync(f, 'utf8').split(/^(?=## \[)/m)) {
  const m = s.match(/^## \[([\d.]+)\]/);
  if (m && gt(m[1], o) && !gt(m[1], n)) console.log(s.trim() + '\n');
}" "$old" "$new" "$work/package/CHANGELOG.md"
echo "Done. Review: git diff --stat; then commit. Payload for manual runs: $payload"
