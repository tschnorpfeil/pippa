#!/usr/bin/env bash
# Checks dist/Pippa.app (and dist/Pippa.dmg, if present):
#   plutil, codesign, Hardened Runtime WITHOUT App Sandbox,
#   exact entitlements of app and helpers, the signed Pi install payload, permission texts,
#   runtime probe in the unmodified signed app bundle (no user data).
#
#   scripts/verify-app.sh [--verify-runtime | --no-runtime]   # the runtime probe runs by default
#   PIPPA_REQUIRE_DISTRIBUTION=1 scripts/verify-app.sh  # check real distribution
set -euo pipefail
RUNTIME=1
for arg in "$@"; do
  case "$arg" in
    --verify-runtime) RUNTIME=1 ;;
    --no-runtime) RUNTIME=0 ;;
    *) printf 'Usage: %s [--verify-runtime | --no-runtime]\n' "$0" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Pippa.app"
DMG="$ROOT/dist/Pippa.dmg"
WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  [[ -z "$MOUNT" ]] || hdiutil detach "$MOUNT" -quiet || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ok() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }
[[ -d "$APP" ]] || fail "$APP missing; run scripts/build-app.sh first"

entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist invalid"
ok "Info.plist (plutil -lint)"
codesign --verify --deep --strict "$APP" || fail "codesign --verify --deep --strict"
ok "codesign --verify --deep --strict"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CodeDirectory)' | sed 's/^/    /'
# Sorted entitlement keys of a signed file ("-" if it has none).
entitlement_keys() {
  entitlements "$1" | python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
keys = sorted(plistlib.loads(data)) if data.strip() else []
print(" ".join(keys) if keys else "-")'
}
expect_entitlements() { # <file> <label> <expected keys, sorted, space-separated or "-">
  local found
  found="$(entitlement_keys "$1")"
  [[ "$found" == "$3" ]] || fail "$2 entitlements: expected [$3], found [$found]"
}
signature="$(codesign -dv --verbose=2 "$APP" 2>&1)"
team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
DEVELOPER_ID=0
if grep -q '^Authority=Developer ID Application:' <<<"$signature"; then DEVELOPER_ID=1; fi
# Hardened Runtime: flags=0x10000(runtime). Ad-hoc builds run without it by design (build-app.sh).
has_runtime() {
  local details
  details="$(codesign -dv --verbose=2 "$1" 2>&1)"
  grep -q '^CodeDirectory .*flags=.*runtime' <<<"$details"
}

# No App Sandbox anywhere (a sandboxed app cannot set up Pi in the home folder).
ents="$(entitlements "$APP")"
! grep -q 'com.apple.security.app-sandbox' <<<"$ents" || fail "App Sandbox still on"
! grep -q 'com.apple.security.inherit' <<<"$ents" || fail "app carries com.apple.security.inherit"
# Only what the Hardened Runtime itself requires: Apple Events (Mail, Excel) and EventKit (Calendar + Reminders).
expect_entitlements "$APP" "Pippa.app" "com.apple.security.automation.apple-events com.apple.security.personal-information.calendars"
ok "no App Sandbox; app entitlements exactly Apple Events + Calendars/Reminders"
if ((DEVELOPER_ID)); then
  has_runtime "$APP" || fail "Hardened Runtime missing on Pippa.app"
  ok "Hardened Runtime on Pippa.app (Developer ID, team $team)"
else
  printf '  \033[33mnote\033[0m  ad-hoc signature: Hardened Runtime is only checked for Developer ID builds\n'
fi
# Permission prompt texts: without the sandbox TCC asks for the folders.
usage_keys=(NSCalendarsFullAccessUsageDescription NSRemindersFullAccessUsageDescription NSAppleEventsUsageDescription
  NSDesktopFolderUsageDescription NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription)
for key in "${usage_keys[@]}"; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || fail "Info.plist: $key missing"
  for lang in en de; do
    grep -q "^\"\{0,1\}$key\"\{0,1\} *=" "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" 2>/dev/null ||
      fail "$lang.lproj/InfoPlist.strings: $key missing"
  done
done
ok "Info.plist + en/de: texts for Calendar, Reminders, Apple Events, Desktop, Documents, Downloads"

# Helpers: run without a sandbox, also outside the bundle (the installer copies Node and esbuild to the home folder).
[[ -x "$APP/Contents/Helpers/node" ]] || fail "bundled Node runtime missing"
# fd and rg for Pi's find and grep (next to Node, first in Pi's PATH).
for tool in fd rg; do [[ -x "$APP/Contents/Helpers/$tool" ]] || fail "bundled $tool missing"; done
WEB="$APP/Contents/Resources/pippa-web"
for path in index.ts package-lock.json node_modules/pi-web-access/dist/index.js; do
  [[ -f "$WEB/$path" ]] || fail "pippa-web/$path missing (web access)"
done
cmp -s "$ROOT/runtime/pippa-web/package-lock.json" "$WEB/package-lock.json" || fail "bundled web access lockfile differs from this checkout; rebuild the app"
cmp -s "$ROOT/runtime/pippa-web/index.ts" "$WEB/index.ts" || fail "bundled web access settings differ from this checkout; rebuild the app"
[[ ! -e "$WEB/node_modules/@earendil-works/pi-coding-agent" ]] || fail "pippa-web ships its test-only Pi (dev dependency)"
ok "web access (pi-web-access) in Contents/Resources/pippa-web, same as this checkout"
# Pippa's abilities: exactly the folders of runtime/pippa-skills, each with its SKILL.md.
expected_skills="$(find "$ROOT/runtime/pippa-skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
found_skills="$(find "$APP/Contents/Resources/pippa-skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
((expected_skills >= 14)) || fail "runtime/pippa-skills has only $expected_skills abilities"
[[ "$found_skills" == "$expected_skills" ]] || fail "Pippa's abilities: $found_skills in the bundle, $expected_skills in runtime/pippa-skills"
diff -rq "$ROOT/runtime/pippa-skills" "$APP/Contents/Resources/pippa-skills" -x .DS_Store >/dev/null || fail "bundled abilities differ from runtime/pippa-skills"
ok "Pippa's abilities: $found_skills in Contents/Resources/pippa-skills, same as runtime/pippa-skills"
# The old conversation core is gone and must not come along from an old build.
[[ ! -e "$APP/Contents/Resources/pi-runtime" ]] || fail "old conversation core (Contents/Resources/pi-runtime) still in the bundle"
# The Pi RPC path starts Pi with Pippa's extensions from the bundle.
for f in pippa-tools.ts pippa-assist.ts pippa-memory.ts pippa-context.ts pippa-mcp.ts files.ts budget.ts search.mjs; do
  cmp -s "$ROOT/runtime/pippa-tools/$f" "$APP/Contents/Resources/pippa-tools/$f" || fail "pippa-tools/$f missing or stale (Pi extensions)"
done
[[ ! -e "$APP/Contents/Resources/pippa-guard" ]] || fail "old guard (Contents/Resources/pippa-guard) still in the bundle"
ok "Pippa's Pi extensions in Contents/Resources/pippa-tools"
expect_entitlements "$APP/Contents/Helpers/node" "Helpers/node" "com.apple.security.cs.allow-jit com.apple.security.cs.disable-library-validation"
expect_entitlements "$APP/Contents/Helpers/llama-server" "Helpers/llama-server" "-"
expect_entitlements "$APP/Contents/Helpers/fd" "Helpers/fd" "-"
expect_entitlements "$APP/Contents/Helpers/rg" "Helpers/rg" "-"
# llama-server is built by build-app.sh: static (only system libraries) and with Pippa's K2 Horizon patch.
LLAMA_BIN="$APP/Contents/Helpers/llama-server"
if otool -L "$LLAMA_BIN" | awk 'NR > 1 { print $1 }' | grep -qv '^/\(usr/lib\|System/Library\)/'; then
  fail "llama-server links libraries outside the system (otool -L): $(otool -L "$LLAMA_BIN" | awk 'NR > 1 { print $1 }' | grep -v '^/\(usr/lib\|System/Library\)/' | tr '\n' ' ')"
fi
llama_strings="$(strings -a "$LLAMA_BIN")"
[[ "$llama_strings" == *'</ifm|think_faster>'* && "$llama_strings" == *'</ifm|think_fast>'* ]] ||
  fail "llama-server lacks the K2 Horizon end tags (app/Packaging/llama-patches not applied?)"
ok "llama-server: static, only system libraries, K2 Horizon think-tag patch included"
native_executables=()
while IFS= read -r -d '' file; do
  if [[ "$file" != *.node ]] && file -b "$file" | grep -q 'Mach-O.*executable'; then native_executables+=("$file"); fi
done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -perm -111 -print0)
((${#native_executables[@]})) || fail "no native executables (esbuild) in pi-payload"
for file in "${native_executables[@]}"; do
  expect_entitlements "$file" "${file#"$APP/"}" "-"
done
signed_helpers=("$APP/Contents/Helpers/node" "$APP/Contents/Helpers/llama-server" "$APP/Contents/Helpers/fd" "$APP/Contents/Helpers/rg" "${native_executables[@]}")
while IFS= read -r -d '' file; do signed_helpers+=("$file"); done < <(find "$APP/Contents/Resources/pi-payload" "$APP/Contents/Resources/pippa-web" -type f -name '*.node' -print0)
for file in "${signed_helpers[@]}"; do
  codesign --verify --strict "$file" 2>/dev/null || fail "${file#"$APP/"} invalidly signed"
  helper_team="$(codesign -dv --verbose=2 "$file" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$helper_team" == "$team" ]] || fail "${file#"$APP/"}: team $helper_team, app $team"
  if ((DEVELOPER_ID)) && [[ "$file" != *.node ]]; then has_runtime "$file" || fail "${file#"$APP/"} without Hardened Runtime"; fi
done
ok "helpers without sandbox: node (JIT, own add-ons), llama-server and ${#native_executables[@]} esbuild binaries without entitlements; ${#signed_helpers[@]} Mach-O signed by the app's team"

# Pi install payload (PiInstaller): pinned release in layout releases-v1 plus npm.
PAYLOAD="$APP/Contents/Resources/pi-payload"
pin="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/app/Packaging/pi-release/package.json")"
for path in release/package.json release/package-lock.json release/metadata.json lib/node_modules/npm/bin/npm-cli.js Node-LICENSE.txt; do
  [[ -f "$PAYLOAD/$path" ]] || fail "pi-payload/$path missing"
done
[[ "$(readlink "$PAYLOAD/release/node_modules/.bin/pi")" == "../@earendil-works/pi-coding-agent/dist/bundle/cli.js" ]] || fail "pi-payload: node_modules/.bin/pi missing or wrong"
cmp -s "$ROOT/app/Packaging/pi-release/package-lock.json" "$PAYLOAD/release/package-lock.json" || fail "pi-payload lockfile differs from app/Packaging/pi-release"
for f in index.ts common.mjs ensure.mjs supervisor.mjs; do
  cmp -s "$ROOT/runtime/pippa-local-server/$f" "$PAYLOAD/extensions/pippa-local-server/$f" || fail "pi-payload/extensions/pippa-local-server/$f missing or stale (terminal autostart)"
done
ok "Pippa's terminal extension (pippa-local-server) in pi-payload"
ok "Pi $pin install payload (releases-v1, official lockfile, npm)"
if ! ls "$APP"/Contents/Resources/*.bundle >/dev/null 2>&1; then fail "no SwiftPM resources in Contents/Resources"; fi
ok "SwiftPM resources in Contents/Resources"
for lang in en de; do
  [[ -f "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" ]] || fail "$lang.lproj/InfoPlist.strings missing"
  for pair in Pippa_Pippa.bundle:Views Pippa_PippaCore.bundle:Core; do
    bundle="${pair%%:*}"; table="${pair#*:}"
    [[ -n "$(find "$APP/Contents/Resources/$bundle" -path "*/$lang.lproj/$table.strings" 2>/dev/null)" ]] ||
      fail "$bundle: $lang.lproj/$table.strings missing"
  done
done
ok "Translations (en, de) in the app and the SwiftPM resource bundles"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || fail "Sparkle.framework missing"
for helper in Autoupdate Updater.app; do
  codesign --verify --strict "$SPARKLE/Versions/B/$helper" || fail "Sparkle helper $helper invalidly signed"
done
# Without the sandbox Sparkle installs directly: no XPC services, no sandbox-only Info.plist switches.
[[ ! -e "$SPARKLE/Versions/B/XPCServices" && ! -e "$SPARKLE/XPCServices" ]] || fail "Sparkle XPC services still bundled (unused without sandbox)"
for key in SUEnableInstallerLauncherService SUEnableDownloaderService; do
  ! /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || fail "Info.plist: $key is sandbox-only"
done
for key in SUFeedURL SUPublicEDKey; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || printf '  \033[33mnote\033[0m  Info.plist: %s missing (local test copy?)\n' "$key"
done
ok "Sparkle framework without XPC services or sandbox switches"

# Out of the bundle, as the installer leaves them: Node (copied to ~/.local/share/pi-node) runs JIT code and the
# pinned Pi CLI; esbuild runs. With the old inherit entitlement both aborted outside a sandboxed parent.
mkdir -p "$WORK/home" "$WORK/bin"
cp "$APP/Contents/Helpers/node" "$WORK/bin/node"
[[ "$("$WORK/bin/node" -e 'console.log(new Function("return 6*7")())')" == 42 ]] || fail "copied Node does not run outside the bundle"
found="$(HOME="$WORK/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 "$WORK/bin/node" "$PAYLOAD/release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" --version 2>&1)" ||
  fail "pinned Pi CLI does not start with the copied Node: $found"
[[ "$found" == "$pin" ]] || fail "pi --version from the payload: $found, expected $pin"
esbuild="$(printf '%s\n' "${native_executables[@]}" | grep '/pi-payload/' | grep -m1 '/esbuild$' || true)"
if [[ -n "$esbuild" ]]; then
  cp "$esbuild" "$WORK/bin/esbuild"
  "$WORK/bin/esbuild" --version >/dev/null || fail "payload esbuild does not run outside the bundle"
fi
[[ -n "$(find "$WORK/home" -mindepth 1 -print -quit)" ]] && printf '  \033[33mnote\033[0m  pi --version wrote to its (temporary) HOME\n'
ok "outside the bundle: Node (JIT), Pi $pin --version${esbuild:+, esbuild}"

# The same signed process as on a customer's Mac launches the helpers.
# The bundle is neither copied nor re-signed. The probe starts no AppModel and
# does not write to settings, journal or conversations. First launch/UI stay manual.
if ((RUNTIME)) && ! python3 - "$APP/Contents/MacOS/Pippa" "$WORK/probe.log" "${PIPPA_VERIFY_TIMEOUT_SECONDS:-120}" <<'PYTHON'
import os, signal, subprocess, sys
timeout = int(sys.argv[3])
if not 1 <= timeout <= 300:
    raise SystemExit('PIPPA_VERIFY_TIMEOUT_SECONDS must be between 1 and 300')
with open(sys.argv[2], 'wb') as log:
    process = subprocess.Popen([sys.argv[1], '--verify-runtime'], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        status = 124
sys.exit(status if status >= 0 else 128 - status)
PYTHON
then
  tail -20 "$WORK/probe.log" >&2
  fail "runtime probe failed (time limit ${PIPPA_VERIFY_TIMEOUT_SECONDS:-120} s)"
fi
if ((RUNTIME)); then
  grep -q '^pippa_bundle_ok ' "$WORK/probe.log" || fail "bundle does not know the runtime probe, or it is incomplete"
  ok "original bundle: resources, skills, llama-server, Pi/Node, native add-on and esbuild ($(grep '^pippa_bundle_ok ' "$WORK/probe.log"))"
  # The original signature must still be valid after the run.
  codesign --verify --deep --strict "$APP" || fail "app signature invalid after runtime probe"
fi

if [[ -f "$DMG" ]]; then
  hdiutil verify "$DMG" >/dev/null 2>&1 || fail "hdiutil verify $(basename "$DMG")"
  ok "hdiutil verify $(basename "$DMG")"
  MOUNT="$WORK/dmg"
  mkdir -p "$MOUNT"
  hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null || fail "DMG cannot be opened read-only"
  codesign --verify --deep --strict "$MOUNT/Pippa.app" || fail "app in the DMG invalidly signed"
  # An old dist/Pippa.dmg must not accidentally count as a check of the new build.
  original_hash="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
  mounted_hash="$(codesign -dvvv "$MOUNT/Pippa.app" 2>&1 | sed -n 's/^CDHash=//p')"
  [[ -n "$original_hash" && "$original_hash" == "$mounted_hash" ]] || fail "DMG contains a different app build"
  hdiutil detach "$MOUNT" -quiet
  MOUNT=""
  ok "DMG contains the same signed app build"
fi
if [[ "${PIPPA_REQUIRE_DISTRIBUTION:-0}" == 1 ]]; then
  [[ -f "$DMG" ]] || fail "release image Pippa.dmg missing"
  signature_details="$(codesign -dv --verbose=2 "$APP" 2>&1)" || fail "app signature cannot be read"
  grep -q '^Authority=Developer ID Application:' <<<"$signature_details" || fail "Developer ID signature missing"
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "notarization ticket on the DMG missing"
  spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1 || fail "Gatekeeper rejects the DMG"
  ok "Developer ID, notarization ticket and Gatekeeper for distribution"
fi
echo "  Pippa.app: $(du -sh "$APP" | cut -f1)"
if [[ -f "$DMG" ]]; then echo "  Pippa.dmg: $(du -h "$DMG" | cut -f1)"; fi
