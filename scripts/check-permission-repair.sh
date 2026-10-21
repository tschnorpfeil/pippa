#!/bin/bash
# Real-controller permission repair actions and 400-point layouts, with an injected URL opener and synthetic data.
# Usage: bash scripts/check-permission-repair.sh <SwiftPM debug bin directory> <new output directory>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:?Pass the SwiftPM debug bin directory}
out=${2:?Pass a new output directory}
test -x "$bin/Pippa"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pippa-permission-repair.XXXXXX")
trap 'rm -rf "$work"' EXIT

app="$work/PippaPermissionRepair.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
for bundle in "$bin/"*.bundle; do
  test -e "$bundle" && cp -R "$bundle" "$app/"
done
cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.permissionrepair "$app/Contents/Info.plist"

python3 - "$app/Contents/MacOS/Pippa" "$out" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

binary, output = sys.argv[1], Path(sys.argv[2])
for language, locale in [("en", "en_US"), ("de", "de_DE")]:
    folder = output / language
    folder.mkdir()
    env = os.environ | {"PIPPA_DEMO": "1", "PIPPA_DEMO_MODEL": "missing", "PIPPA_SNAPSHOT": str(folder),
                        "PIPPA_SNAPSHOT_ONLY": "permissionrepair", "PIPPA_APPEARANCE": "light", "PIPPA_REDUCE_MOTION": "1",
                        "PIPPA_SNAPSHOT_WIDTH": "400", "PIPPA_SNAPSHOT_HEIGHT": "700"}
    with (folder / "app.log").open("wb") as log:
        subprocess.run([binary, "-AppleLanguages", f"({language})", "-AppleLocale", locale, "-model.download.allowed", "NO"],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    report = (folder / "permissionrepair.txt").read_text()
    lines = report.splitlines()
    assertions = sum(line.startswith("PASS:") for line in lines[1:])
    if not lines or lines[0] != "PASS: permission repair" or assertions < 30 or any(line.startswith("FAIL:") for line in lines):
        raise SystemExit(f"FAIL: {language} permission repair fixture:\n{report}")
    for name in ("files", "drive", "photos", "photo-previews", "mail", "calendar", "reminders"):
        if (folder / f"permission-repair-{name}.png").stat().st_size == 0:
            raise SystemExit(f"FAIL: empty {language} permission repair capture {name}")
    print(f"{language}: {assertions} permission-repair assertions passed at 400 points.")
PY
