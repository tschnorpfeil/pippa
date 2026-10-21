#!/bin/bash
# Run the real-controller reminder fixture with synthetic evidence, isolated history and no native app writes.
# Usage: bash scripts/check-reminder-status.sh <SwiftPM debug bin directory> <new output directory>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:?Pass the SwiftPM debug bin directory}
out=${2:?Pass a new output directory}
test -x "$bin/Pippa"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pippa-reminder-status.XXXXXX")
trap 'rm -rf "$work"' EXIT

app="$work/PippaReminderStatus.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
for bundle in "$bin/"*.bundle; do
  test -e "$bundle" && cp -R "$bundle" "$app/"
done
cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.reminderstatus "$app/Contents/Info.plist"

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
                        "PIPPA_SNAPSHOT_ONLY": "reminderstatus", "PIPPA_APPEARANCE": "light", "PIPPA_REDUCE_MOTION": "1",
                        "PIPPA_SNAPSHOT_WIDTH": "400", "PIPPA_SNAPSHOT_HEIGHT": "700"}
    with (folder / "app.log").open("wb") as log:
        subprocess.run([binary, "-AppleLanguages", f"({language})", "-AppleLocale", locale, "-model.download.allowed", "NO"],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    report = (folder / "reminderstatus.txt").read_text()
    lines = report.splitlines()
    assertions = sum(line.startswith("PASS:") for line in lines[1:])
    if not lines or lines[0] != "PASS: reminder status" or assertions < 10 or any(line.startswith("FAIL:") for line in lines):
        raise SystemExit(f"FAIL: {language} reminder status fixture:\n{report}")
    for name in ("reminder-status-idle.png", "reminder-status-checking.png"):
        if (folder / name).stat().st_size == 0:
            raise SystemExit(f"FAIL: empty {language} receipt capture {name}")
    print(f"{language}: {assertions} reminder-status assertions passed at 400 points.")
PY
