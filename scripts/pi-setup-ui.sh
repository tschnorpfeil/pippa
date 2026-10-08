#!/bin/sh
# Pi setup UI in the real Pippa window (no technical questions asked).
#
#   scripts/pi-setup-ui.sh shots [de|en] [light|dark]   snapshots of all states (no installer, no network) in
#                                                        .build/setup-ui-shots/<language>-<look>/
#   scripts/pi-setup-ui.sh e2e                           real flow in a fake HOME (.build/setup-ui-home-*):
#                                                        an existing model sits "in LM Studio" (APFS clone from
#                                                        ~/Library/Caches/pippa-live, read only), Pippa adopts it
#                                                        without asking, sets up Pi silently and answers a question.
#   scripts/pi-setup-ui.sh r6                            like e2e, then a question about a shown PDF, the abilities
#                                                        button, the "look up online" card ("Not now"), an event via
#                                                        a stand-in calendar. Guard, work folder and undo folder
#                                                        without environment (default).
#                                                        Corpus: swift scripts/quality/make-ctxsug-corpus.swift .build/quality/ctxsug-corpus
#   scripts/pi-setup-ui.sh r7b                           "Tidy my Downloads" natively (preview, one undo) in
#                                                        a fake HOME with made-up Downloads (corpus as for r6)
#
# Before: swift build --package-path app --product Pippa; payload in .build/pi-payload (bundle-pi-payload.sh --with-node).
# Never: real ~/.pi, ~/.local, ~/models, Application Support/Pippa. The app starts and stops the llama-server.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bin="$root/app/.build/debug"
cache="$HOME/Library/Caches/pippa-live"
stamp=$(date +%Y%m%d-%H%M%S)

# The bare debug binary shows English only: a development bundle with its own identifier (never the real app's).
dev_bundle() {
  app="$root/.build/PippaSetupDev.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$bin/Pippa" "$app/Contents/MacOS/Pippa"
  cp -R "$bin/Sparkle.framework" "$app/Contents/MacOS/"
  cp -R "$bin/"*.bundle "$app/" 2>/dev/null || true
  cp "$root/app/Packaging/Info.plist" "$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string io.github.tschnorpfeil.pippa.setupdev "$app/Contents/Info.plist"
  echo "$app/Contents/MacOS/Pippa"
}

case "${1:-}" in
shots)
  lang="${2:-de}"; look="${3:-light}"
  locale=de_DE; [ "$lang" = en ] && locale=en_US
  out="$root/.build/setup-ui-shots/$lang-$look"
  rm -rf "$out"
  exe=$(dev_bundle)
  PIPPA_DEMO=1 PIPPA_SNAPSHOT="$out" PIPPA_SNAPSHOT_ONLY=setup-all PIPPA_APPEARANCE="$look" \
    "$exe" -AppleLanguages "($lang)" -AppleLocale "$locale" >"$out.log" 2>&1
  cat "$out/setup.txt"
  ;;
e2e)
  payload="${PIPPA_PI_PAYLOAD:-$root/.build/pi-payload}"
  home="$root/.build/setup-ui-home-$stamp"
  shot="$root/.build/setup-ui-e2e-$stamp"
  model="$cache/models/Qwen3.5-4B-Q4_K_M.gguf"
  lms="$home/.lmstudio/models/unsloth/Qwen3.5-4B-GGUF"
  mkdir -p "$lms" "$home/work" "$shot"
  # Existing model "in LM Studio": APFS clone, the source in the cache is only read.
  before=$(stat -f '%z %m %i' "$model")
  cp -c "$model" "$lms/"
  export PIPPA_PI_RPC=1 PIPPA_DEMO=1 PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL=qwen3.5-4b-q4
  export PI_CODING_AGENT_DIR="$home/.pi/agent" PIPPA_UNDO_DIR="$home/undo" PIPPA_PI_WORKDIR="$home/work" PIPPA_TRASH_DIR="$home/trash"
  export PIPPA_PI_GUARD="$root/runtime/pippa-guard/pippa-guard.ts" PIPPA_PI_TOOLS="$root/runtime/pippa-guard/pippa-tools.ts"
  # Binary from the cache (read only); the model comes from the installer's models folder, not from PIPPA_MODEL_FILE.
  export PIPPA_LLAMA_SERVER="${PIPPA_LLAMA_SERVER:-$cache/llama-b11503/llama-server}"
  unset PIPPA_MODEL_FILE || true
  export PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY=setup-e2e PIPPA_LOG_DIR="$shot/logs"
  "$bin/Pippa" -AppleLanguages "(de)" -AppleLocale de_DE >"$shot/app.log" 2>&1 || true
  after=$(stat -f '%z %m %i' "$model")
  {
    echo "Cache source before/after (size, mtime, inode): $before / $after"
    [ "$before" = "$after" ] && echo "PASS: source unchanged" || echo "FAIL: source changed"
    echo "Models folder: $(sed -n 's/.*"modelsFolder" : "\(.*\)".*/\1/p' "$home/Library/Application Support/Pippa/install-state.json")"
    echo "~/models created: $([ -e "$home/models" ] && echo yes || echo no)"
    left=$(pgrep -f "llama-server.*$(basename "$home")" || true)
    echo "llama-server still running afterwards: ${left:-no}"
  } >>"$shot/setup.txt"
  cat "$shot/setup.txt"
  echo "Snapshots: $shot  HOME: $home"
  ;;
r6)
  if pgrep -x llama-server >/dev/null; then echo "A llama-server is already running:"; pgrep -lx llama-server | cut -c1-160; exit 3; fi
  payload="${PIPPA_PI_PAYLOAD:-$root/.build/pi-payload}"
  home="$root/.build/r6-home-$stamp"
  shot="$root/.build/r6-run-$stamp"
  model="$cache/models/Qwen3.5-4B-Q4_K_M.gguf"
  lms="$home/.lmstudio/models/unsloth/Qwen3.5-4B-GGUF"
  mkdir -p "$lms" "$shot"
  before=$(stat -f '%z %m %i' "$model")
  cp -c "$model" "$lms/"
  # Pi path: explicit in debug snapshots (PIPPA_PI_RPC=1); in release builds it is on without the switch.
  export PIPPA_PI_RPC=1 PIPPA_DEMO=1 PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="${PIPPA_PI_MODEL:-qwen3.5-4b-q4}"
  export PI_CODING_AGENT_DIR="$home/.pi/agent" PIPPA_TRASH_DIR="$home/trash"
  unset PIPPA_PI_GUARD PIPPA_PI_TOOLS PIPPA_PI_WORKDIR PIPPA_UNDO_DIR PIPPA_MODEL_FILE || true
  export PIPPA_LLAMA_SERVER="${PIPPA_LLAMA_SERVER:-$cache/llama-b11503/llama-server}"
  export PIPPA_R2_CORPUS="$root/.build/quality/ctxsug-corpus"
  export PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY=r6 PIPPA_LOG_DIR="$shot/logs"
  "$bin/Pippa" -AppleLanguages "(de)" -AppleLocale de_DE >"$shot/app.log" 2>&1 || true
  after=$(stat -f '%z %m %i' "$model")
  {
    [ "$before" = "$after" ] && echo "PASS: model in cache unchanged" || echo "FAIL: model in cache changed"
    left=$(pgrep -f "llama-server.*$(basename "$home")" || true)
    echo "llama-server still running after quit: ${left:-no}"
    echo "Work folder (default): $(ls -d "$shot/support/pi-work" 2>/dev/null || echo missing)"
  } >>"$shot/r6.txt"
  cat "$shot/r6.txt"
  echo "Snapshots: $shot  HOME: $home"
  ;;
r7b)
  # "Tidy my Downloads" in the real window on the Pi path, natively with preview and one undo. Made-up Downloads
  # folder in the fake HOME under .build; no model and no payload needed (setup does not finish, tidying does not
  # need it). Corpus as for r6.
  corpus="$root/.build/quality/ctxsug-corpus"
  [ -d "$corpus" ] || { echo "run first: swift scripts/quality/make-ctxsug-corpus.swift $corpus"; exit 2; }
  home="$root/.build/r7b-home-$stamp"
  shot="$root/.build/r7b-run-$stamp"
  dl="$home/Downloads"
  mkdir -p "$dl" "$shot"
  while IFS='|' read -r from to; do cp "$corpus/$from" "$dl/$to"; done <<'LIST'
rechnung-1.pdf|Rechnung_2026-09_Stadtwerke.pdf
rechnung-2.pdf|invoice-10233.pdf
rechnung-heizung.pdf|Heizung Wartung Rechnung.pdf
brief-finanzamt.pdf|Steuerbescheid 2025.pdf
mietvertrag-12-seiten.pdf|Mietvertrag_Musterstrasse.pdf
urlaub-strand.jpg|IMG_4711.jpg
garten-1.jpg|IMG_4712.jpg
bildschirmfoto-fehlermeldung.png|Bildschirmfoto 2026-10-01 um 09.12.33.png
haushaltsbuch-2026.csv|haushaltsbuch-2026.csv
kuendigung-entwurf.docx|Kuendigung_Fitnessstudio.docx
garten-video.mov|garten.mov
nachricht-nachbar.txt|notiz.txt
rechnung-1.pdf|Rechnung_2026-09_Stadtwerke (1).pdf
LIST
  printf 'PK\003\004' >"$dl/Fotos_Export(1).zip"
  head -c 2048 /dev/zero >"$dl/Pippa-Installer.dmg"
  export PIPPA_PI_RPC=1 PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$home/no-payload"
  export PI_CODING_AGENT_DIR="$home/.pi/agent" PIPPA_TRASH_DIR="$home/trash"
  unset PIPPA_PI_GUARD PIPPA_PI_TOOLS PIPPA_PI_WORKDIR PIPPA_UNDO_DIR PIPPA_MODEL_FILE PIPPA_DEMO || true
  export PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY=r7b PIPPA_LOG_DIR="$shot/logs"
  (cd "$root" && "$bin/Pippa" -AppleLanguages "(de)" -AppleLocale de_DE >"$shot/app.log" 2>&1) || true
  cat "$shot/r7b.txt"
  echo "Snapshots: $shot  HOME: $home"
  ;;
*)
  sed -n '2,18p' "$0"; exit 2 ;;
esac
