#!/bin/bash
# Run the synthetic three-pane conversation fixture in English and German.
# Usage: bash scripts/check-conversation-rails.sh <SwiftPM debug bin directory> <new output directory>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:?Pass the SwiftPM debug bin directory}
out=${2:?Pass a new output directory}
test -x "$bin/Pippa"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pippa-conversation-rails.XXXXXX")
trap 'rm -rf "$work"' EXIT

app="$work/PippaConversationRails.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
for bundle in "$bin/"*.bundle; do
  test -e "$bundle" && cp -R "$bundle" "$app/"
done
cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.conversationrails "$app/Contents/Info.plist"

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
                        "PIPPA_SNAPSHOT_ONLY": "rails", "PIPPA_APPEARANCE": os.environ.get("PIPPA_APPEARANCE", "light"), "PIPPA_REDUCE_MOTION": "1"}
    with (folder / "app.log").open("wb") as log:
        subprocess.run([binary, "-AppleLanguages", f"({language})", "-AppleLocale", locale, "-model.download.allowed", "NO"],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    report = (folder / "rails.txt").read_text()
    lines = report.splitlines()
    assertions = sum(line.startswith("PASS:") for line in lines[1:])
    if not lines or lines[0] != "PASS: conversation rails" or assertions < 20 or any(line.startswith("FAIL:") for line in lines):
        raise SystemExit(f"FAIL: {language} conversation rails fixture:\n{report}")
    for name in ("rails-00-workspace", "rails-01-three-panes", "rails-02-conversations-only", "rails-03-plain", "rails-04-plain-at-400",
                 "rails-05-working", "rails-06-after-changes", "rails-07-stoppable", "rails-08-stoppable-compact"):
        if (folder / f"{name}.png").stat().st_size == 0:
            raise SystemExit(f"FAIL: empty {language} conversation rails capture {name}")
    print(f"{language}: {assertions} conversation-rail assertions passed.")
PY
