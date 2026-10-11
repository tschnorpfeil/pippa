#!/bin/sh
# Pi setup UI in the real Pippa window (no technical questions asked).
#
#   scripts/pi-setup-ui.sh shots [de|en] [light|dark]   snapshots of all states (no installer, no network) in
#                                                        .build/setup-ui-shots/<language>-<look>/
#   scripts/pi-setup-ui.sh e2e                           real flow in a fake HOME (.build/setup-ui-home-*):
#                                                        an existing model sits "in LM Studio" (APFS clone from
#                                                        ~/Library/Caches/pippa-live, read only), Pippa adopts it
#                                                        without asking, sets up Pi silently and answers a question.
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
  export PI_CODING_AGENT_DIR="$home/.pi/agent" PIPPA_PI_WORKDIR="$home/work" PIPPA_TRASH_DIR="$home/trash"
  export PIPPA_PI_EXTENSIONS="$root/runtime/pippa-tools" PIPPA_PI_WEB="$root/runtime/pippa-web/index.ts"
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
*)
  sed -n '2,12p' "$0"; exit 2 ;;
esac
