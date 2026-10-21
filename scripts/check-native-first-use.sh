#!/bin/bash
# Run the existing strict native-first-use app fixture in English and German.
# Usage: bash scripts/check-native-first-use.sh <SwiftPM debug bin directory> <new output directory>
# No model, external app integration, or download is used. External AX reads materialize SwiftUI's public tree;
# missing Accessibility access is a failed acceptance prerequisite, never a skipped assertion.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:?Pass the SwiftPM debug bin directory}
out=${2:?Pass a new output directory}
test -x "$bin/Pippa"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pippa-native-first-use.XXXXXX")
app_pid=
probe_pid=
cleanup() {
  if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
  if [ -n "$probe_pid" ]; then kill "$probe_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# A distinct development identity preserves localization without touching the installed Pippa.
app="$work/PippaNativeFirstUse.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
for bundle in "$bin/"*.bundle; do
  test -e "$bundle" && cp -R "$bundle" "$app/"
done
cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.nativefirstuse "$app/Contents/Info.plist"
swiftc "$root/scripts/native-first-use-ax.swift" -o "$work/ax-reader"

status=0
for language in en de; do
  locale=en_US
  if [ "$language" = de ]; then locale=de_DE; fi
  shot="$out/$language"
  mkdir -p "$shot"
  PIPPA_DEMO=1 PIPPA_DEMO_MODEL=missing PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY=nativefirstuse \
    PIPPA_APPEARANCE=light PIPPA_REDUCE_MOTION=1 PIPPA_SNAPSHOT_HEIGHT=700 \
    "$app/Contents/MacOS/Pippa" -AppleLanguages "($language)" -AppleLocale "$locale" \
    -model.download.allowed NO >"$shot/app.log" 2>&1 &
  app_pid=$!
  "$work/ax-reader" "$app_pid" >"$shot/accessibility-reader.log" 2>&1 &
  probe_pid=$!
  for ((attempt = 0; attempt < 120; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    echo "FAIL: $language native first use exceeded 120 seconds" | tee "$shot/timeout.txt"
    kill "$app_pid" 2>/dev/null || true
    status=1
  fi
  if ! wait "$app_pid"; then status=1; fi
  app_pid=
  if ! wait "$probe_pid"; then
    echo "FAIL: external Accessibility reading unavailable; inspect $shot/accessibility-reader.log"
    status=1
  fi
  probe_pid=
  if ! python3 - "$shot/nativefirstuse.txt" <<'PY'
import pathlib, sys
report = pathlib.Path(sys.argv[1])
if not report.is_file():
    raise SystemExit(f"FAIL: missing acceptance report: {report}")
text = report.read_text()
print(text, end="")
lines = text.splitlines()
assertions = sum(line.startswith("PASS:") for line in lines[1:])
if not lines or lines[0] != "PASS: native first-use flow" or assertions < 24 or any(line.startswith("FAIL:") for line in lines):
    raise SystemExit(1)
print(f"Verified {assertions} native first-use assertions.")
PY
  then status=1; fi
done
exit "$status"
