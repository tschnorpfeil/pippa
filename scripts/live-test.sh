#!/usr/bin/env bash
# All of Pippa's flows against a real model: llama-server from the pinned llama.cpp release,
# model from the catalog (own downloader, resumable, SHA256), test corpus, timings and checks.
#
#   scripts/live-test.sh [model]         default: qwen3-4b-q4 (smallest catalog entry, approx. 2.5 GB)
#   scripts/live-test.sh auto            model chosen by memory, as in the app
#
# Environment:
#   PIPPA_LIVE_DIR   work folder (default ~/Library/Caches/pippa-live): models, test corpus, logs
#   PIPPA_CACHE      download cache for llama.cpp (default ~/Library/Caches/pippa-build, like build-app.sh)
#
# None of this ends up in the repo. Needs network access to github.com and huggingface.co.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PIPPA_LIVE_DIR:-$HOME/Library/Caches/pippa-live}"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}"
MODEL="${1:-qwen3-4b-q4}"
[[ "$MODEL" == auto ]] && MODEL=""

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "only on a Mac with Apple silicon"
for tool in swift curl shasum tar python3; do command -v "$tool" >/dev/null || die "$tool missing"; done
mkdir -p "$WORK" "$CACHE"

# --- llama-server (pinned, checksum-verified; same cache as build-app.sh) ---
read -r TAG ASSET SHA < <(python3 - "$ROOT/app/Packaging/llama-release.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
name = f"llama-{r['tag']}-bin-macos-arm64.tar.gz"
print(r["tag"], name, r["assets"][name]["sha256"])
PY
)
ARCHIVE="$CACHE/$ASSET"
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
if [[ -f "$ARCHIVE" && "$(sha_of "$ARCHIVE")" != "$SHA" ]]; then rm -f "$ARCHIVE"; fi
if [[ ! -f "$ARCHIVE" ]]; then
  say "Downloading llama.cpp $TAG"
  curl -fL --retry 3 --progress-bar -o "$ARCHIVE.part" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$ASSET"
  [[ "$(sha_of "$ARCHIVE.part")" == "$SHA" ]] || { rm -f "$ARCHIVE.part"; die "SHA256 of $ASSET does not match"; }
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
LLAMA="$WORK/llama-$TAG"
if [[ ! -x "$LLAMA/llama-server" ]]; then
  rm -rf "$LLAMA"; mkdir -p "$LLAMA"
  tar -xzf "$ARCHIVE" -C "$LLAMA" --strip-components=1
fi
say "llama.cpp $TAG verified"

# --- Environment for PippaLive ---
export PIPPA_LIVE=1
export PIPPA_LLAMA_SERVER="$LLAMA/llama-server"
export PIPPA_LIVE_BASE="$WORK/support"
export PIPPA_MODELS_DIR="$WORK/models"
STAMP="$(date +%Y%m%d-%H%M%S)"
export PIPPA_MODEL_TRACE="$WORK/trace-$STAMP.jsonl"   # every model request with its response, as a template for checks

# No llama-server may be left behind, even on abort.
cleanup() { pkill -f "$LLAMA/llama-server" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

cd "$ROOT/app"
say "Building PippaLive"
if ! out="$(swift build --product PippaLive 2>&1)"; then echo "$out"; die "build failed"; fi

say "Downloading model (${MODEL:-by memory}); interrupting is fine, it resumes where it stopped"
swift run PippaLive download ${MODEL:+"$MODEL"}

say "All flows (log: $WORK/live-$STAMP.log)"
swift run PippaLive run "$WORK/corpus" ${MODEL:+"$MODEL"} | tee "$WORK/live-$STAMP.log"

say "Done. Model responses: $PIPPA_MODEL_TRACE"
