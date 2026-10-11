#!/bin/sh
# Pippa driving the real Pi over `pi --mode rpc`.
# Everything stays in the repo under .build/: a fake HOME (.build/spike-home) with the pinned Pi from the payload
# (PIPPA_PI_PAYLOAD, default .build/pi-payload) and Pi's config folder, work folder, a test
# trash (PIPPA_TRASH_DIR, so nothing reaches the real Trash) and logs.
# The model files under ~/Library/Caches/pippa-live are only read. ~/.pi and ~/.local stay untouched.
#
#   scripts/pi-rpc-spike.sh app [manual|wave2d]        Pippa window with PIPPA_PI_RPC=1 (scripted snapshot "pirpc",
#                                                      the wave2d snapshot, or drive it yourself); on the first start the
#                                                      app sets up Pi in the fake HOME itself and starts llama-server
#   scripts/pi-rpc-spike.sh llama-start [k2|qwen]     llama-server on 127.0.0.1:<installer port> with the key from
#                                                      the key file (PID in .build/spike-logs)
#   scripts/pi-rpc-spike.sh llama-stop                 stop exactly that llama-server
#   scripts/pi-rpc-spike.sh env                        print the environment for manual runs (eval "$(... env)")
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
logs="$root/.build/spike-logs"
home="$root/.build/spike-home"
agent="$home/.pi/agent"
support="$home/Library/Application Support/Pippa"
payload="${PIPPA_PI_PAYLOAD:-$root/.build/pi-payload}"
work="$root/.build/spike-work"
trash="$root/.build/spike-trash"
tools="$root/runtime/pippa-tools"
web="$root/runtime/pippa-web/index.ts"
cache="$HOME/Library/Caches/pippa-live"
mkdir -p "$logs"
# Port from Pippa's settings.json in the fake HOME (PiInstaller.stablePort), otherwise 18080.
port=$(sed -n -e 's/.*"llamaPort":\([0-9]*\).*/\1/p' -- "$support/settings.json" 2>/dev/null || true)
port="${PIPPA_SPIKE_PORT:-${port:-18080}}"

case "${1:-}" in
llama-start)
  case "${2:-k2}" in
    qwen) model="$cache/models/Qwen3.5-4B-Q4_K_M.gguf"; alias=qwen3.5-4b ;;
    *) model="$cache/models/K2-Horizon-7B-Q4_K_M.gguf"; alias=k2-horizon-7b; sampling="--temp 0.6 --top-p 0.95 --top-k 0 --min-p 0" ;;
  esac
  [ -f "$support/llama-key" ] || { echo "run first: $0 app manual (the app sets up Pi and the key file)"; exit 2; }
  # As the app starts Pi's server: no --reasoning off (Pi sets the level per request), the bundled (patched) build if
  # there is one, else the cached release.
  bin="${PIPPA_LLAMA_SERVER:-$root/dist/Pippa.app/Contents/Helpers/llama-server}"
  [ -x "$bin" ] || bin="$cache/llama-b11503/llama-server"
  LLAMA_API_KEY=$(cat -- "$support/llama-key") nohup "$bin" -m "$model" --jinja --host 127.0.0.1 --port "$port" \
    -ngl 999 -c 16384 --parallel 1 --no-webui --cache-type-k q8_0 --cache-type-v q8_0 \
    ${sampling:-} --alias "$alias" >"$logs/llama-server.log" 2>&1 &
  echo $! >"$logs/llama-server.pid"
  echo "llama-server PID $(cat "$logs/llama-server.pid") ($alias) on port $port"
  ;;
llama-stop)
  if [ -f "$logs/llama-server.pid" ]; then
    kill "$(cat "$logs/llama-server.pid")" 2>/dev/null || true
    rm -f "$logs/llama-server.pid"
  fi
  ;;
env)
  echo "export PIPPA_PI_HOME='$home'"
  echo "export PIPPA_PI_PAYLOAD='$payload'"
  echo "export PI_CODING_AGENT_DIR='$agent'"
  echo "export PI_OFFLINE=1"
  echo "export PI_SKIP_VERSION_CHECK=1"
  echo "export PI_TELEMETRY=0"
  echo "export PIPPA_PI_WORKDIR='$work'"
  echo "export PIPPA_PI_EXTENSIONS='$tools'"
  echo "export PIPPA_PI_WEB='$web'"
  echo "export PIPPA_TRASH_DIR='$trash'"
  ;;
app)
  # Real Pippa window (debug build) against the real Pi: snapshot PIPPA_SNAPSHOT_ONLY=pirpc, quits by itself.
  # With "app manual" the app starts with the switch only, no snapshot (then type and click yourself).
  # PI_CODING_AGENT_DIR only here, so ~/.pi stays untouched; the app itself never sets it (PippaPiLaunch).
  # Sessions end up in the snapshot's support folder (PIPPA_SNAPSHOT/support/pi-sessions).
  mkdir -p "$work" "$trash"
  export PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="${PIPPA_PI_MODEL:-k2-horizon-7b}"
  export PI_CODING_AGENT_DIR="$agent" PIPPA_PI_WORKDIR="$work" PIPPA_TRASH_DIR="$trash"
  export PIPPA_PI_EXTENSIONS="$tools" PIPPA_PI_WEB="$web" PIPPA_PI_RPC=1 PIPPA_DEMO=1
  # The app starts the llama-server for pippa-local itself (fixed port + key from the fake HOME).
  # Binary and model from the cache are only read. If one is already running (llama-start), set PIPPA_PI_OWN_LLAMA=0.
  export PIPPA_LLAMA_SERVER="${PIPPA_LLAMA_SERVER:-$( [ -x "$root/dist/Pippa.app/Contents/Helpers/llama-server" ] && echo "$root/dist/Pippa.app/Contents/Helpers/llama-server" || echo "$cache/llama-b11503/llama-server")}"
  export PIPPA_MODEL_FILE="${PIPPA_MODEL_FILE:-$cache/models/K2-Horizon-7B-Q4_K_M.gguf}"
  [ "${2:-}" = wave2d ] && export PIPPA_PIRPC_SCENARIO=wave2d
  shot="$root/.build/spike-app-$(date +%Y%m%d-%H%M%S)"
  export PIPPA_LOG_DIR="$shot/logs"
  if [ "${2:-}" = manual ]; then
    export PIPPA_SNAPSHOT="$shot"
    "$root/app/.build/debug/Pippa"
  else
    export PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY=pirpc
    "$root/app/.build/debug/Pippa" >"$logs/app.log" 2>&1
    echo "Report: $shot/pirpc.txt"
  fi
  ;;
*)
  sed -n '2,15p' "$0"; exit 2 ;;
esac
