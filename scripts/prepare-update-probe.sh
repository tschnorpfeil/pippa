#!/usr/bin/env bash
# Prepares a real local Sparkle installation. No push/release/tag, no changes to the host app:
# the host is copied (ditto, signature intact) into dist/update-probe/host, and Sparkle updates that copy.
# The probe uses the host's own Sparkle.framework (an old sandboxed Pippa brings its XPC services and
# SUEnableInstallerLauncherService; the probe mirrors that switch).
# Afterwards start the local server and open the probe app (PIPPA_PROBE_AUTOMATIC=1 → no button:
# background check, automatic download, immediate install, relaunch logs UPDATE INSTALLED).
# Note: Sparkle stores its check state (SULastCheckTime …) in the host's defaults domain.
# PIPPA_SIGN_IDENTITY='Developer ID Application: …' scripts/prepare-update-probe.sh /Applications/Pippa.app dist/releases/v…
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 2 && -d "$1/Contents" && -d "$2" ]] || { echo 'Pass the host .app and the prepared release folder' >&2; exit 1; }
SOURCE_HOST="$(cd "$1" && pwd)"
RELEASE="$(cd "$2" && pwd)"
IDENTITY="${PIPPA_SIGN_IDENTITY:-}"
[[ "$IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID missing' >&2; exit 1; }
PROBE_ROOT="$ROOT/dist/update-probe"
[[ ! -e "$PROBE_ROOT" ]] || { echo 'probe folder already exists; not overwriting' >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE_HOST"
mkdir -p "$PROBE_ROOT/host"
HOST="$PROBE_ROOT/host/$(basename "$SOURCE_HOST")"
ditto "$SOURCE_HOST" "$HOST"
codesign --verify --deep --strict "$HOST"
(cd "$RELEASE" && shasum -a 256 -c SHA256SUMS)
swift build --package-path "$ROOT/app" --product PippaUpdateProbe
BIN="$(swift build --package-path "$ROOT/app" --show-bin-path)"
APP="$PROBE_ROOT/Pippa Updateprobe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$PROBE_ROOT/feed"
cp "$BIN/PippaUpdateProbe" "$APP/Contents/MacOS/PippaUpdateProbe"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PippaUpdateProbe" 2>/dev/null || true
HOST_SPARKLE="$HOST/Contents/Frameworks/Sparkle.framework"
if [[ -d "$HOST_SPARKLE/Versions/B/XPCServices" ]]; then SPARKLE_SRC="$HOST_SPARKLE"
else SPARKLE_SRC="$ROOT/app/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; fi
[[ -d "$SPARKLE_SRC/Versions/B/XPCServices" ]] || { echo "Sparkle with XPC services missing: $SPARKLE_SRC" >&2; exit 1; }
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
python3 - "$RELEASE" "$APP" "$HOST" "$PROBE_ROOT" "${PIPPA_PROBE_AUTOMATIC:-0}" <<'PY'
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
release, app, host, probe = map(pathlib.Path, sys.argv[1:5])
automatic = sys.argv[5] == '1'
host_info = plistlib.loads((host / 'Contents/Info.plist').read_bytes())
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
tree = ET.parse(release / 'appcast.xml')
item = tree.find('channel/item')
enclosure = item.find('enclosure')
import urllib.parse, shutil
# release.sh also writes Pippa.dmg (stable website name); the feed names the versioned asset.
asset = release / urllib.parse.unquote(enclosure.get('url').rsplit('/', 1)[1])
if not asset.is_file(): raise SystemExit(f'Appcast asset missing: {asset.name}')
if int(enclosure.get('length')) != asset.stat().st_size: raise SystemExit('DMG length does not match')
enclosure.set('url', 'http://127.0.0.1:18765/' + urllib.parse.quote(asset.name))
tree.write(probe / 'feed/appcast.xml', encoding='utf-8', xml_declaration=True)
shutil.copyfile(asset, probe / 'feed' / asset.name)
info = dict(CFBundleIdentifier='io.github.tschnorpfeil.pippa.update-probe', CFBundleName='Pippa Updateprobe',
    CFBundleExecutable='PippaUpdateProbe', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1',
    LSMinimumSystemVersion='15.0', NSAppTransportSecurity={'NSAllowsLocalNetworking': True},
    PippaProbeHost=str(host), PippaProbeTarget=item.findtext(ns+'version'),
    PippaProbeFeed='http://127.0.0.1:18765/appcast.xml', PippaProbeLog=str(probe / 'events.log'),
    PippaProbeAutomatic=automatic, SUEnableInstallerLauncherService=bool(host_info.get('SUEnableInstallerLauncherService', False)))
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Probe ready: %s\nHost copy: %s\nServer: python3 -m http.server 18765 --bind 127.0.0.1 --directory %s/feed\n' "$APP" "$HOST" "$PROBE_ROOT"
