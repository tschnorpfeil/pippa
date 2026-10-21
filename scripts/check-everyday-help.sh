#!/bin/bash
# Real file-task and morning-overview controllers, synthetic sources, no model or private account reads.
# Usage: bash scripts/check-everyday-help.sh <SwiftPM debug bin directory> <new output directory>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:?Pass the SwiftPM debug bin directory}
out=${2:?Pass a new output directory}
test -x "$bin/Pippa"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pippa-everyday-help.XXXXXX")
trap 'rm -rf "$work"' EXIT

app="$work/PippaEverydayHelp.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
for bundle in "$bin/"*.bundle; do
  test -e "$bundle" && cp -R "$bundle" "$app/"
done
cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.everydayhelp "$app/Contents/Info.plist"

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
                        "PIPPA_SNAPSHOT_ONLY": "everydayhelp", "PIPPA_APPEARANCE": "light", "PIPPA_REDUCE_MOTION": "1",
                        "PIPPA_SNAPSHOT_WIDTH": "400", "PIPPA_SNAPSHOT_HEIGHT": "700"}
    with (folder / "app.log").open("wb") as log:
        subprocess.run([binary, "-AppleLanguages", f"({language})", "-AppleLocale", locale, "-model.download.allowed", "NO"],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    report = (folder / "everydayhelp.txt").read_text()
    lines = report.splitlines()
    assertions = sum(line.startswith("PASS:") for line in lines[1:])
    if not lines or lines[0] != "PASS: everyday help" or assertions < 60 or any(line.startswith("FAIL:") for line in lines):
        raise SystemExit(f"FAIL: {language} everyday help fixture:\n{report}")
    for name in ("everyday-01-preview", "everyday-02-result", "everyday-03-save-failure",
                 "morning-settings-off", "morning-settings", "morning-result", "morning-denied",
                 "prepared-files-card", "prepared-files-changed"):
        if (folder / f"{name}.png").stat().st_size == 0:
            raise SystemExit(f"FAIL: empty {language} everyday help capture {name}")
    print(f"{language}: {assertions} everyday-help assertions passed at 400 points.")
PY
