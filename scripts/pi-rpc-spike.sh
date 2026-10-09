#!/bin/sh
# Probe: Pippa driving the real Pi over `pi --mode rpc`.
# Everything stays in the repo under .build/: a fake HOME (.build/spike-home) with the pinned Pi from the payload
# (PIPPA_PI_PAYLOAD, default .build/pi-payload) and Pi's config folder, work folder, sessions, a test
# trash (PIPPA_TRASH_DIR, so nothing reaches the real Trash) and logs.
# The model files under ~/Library/Caches/pippa-live are only read. ~/.pi and ~/.local stay untouched.
#
#   scripts/pi-rpc-spike.sh setup                      set up Pi in the fake HOME (installer: release, models.json
#                                                      with pippa-local, fixed port and key file), settings.json
#   scripts/pi-rpc-spike.sh llama-start [k2|qwen]     llama-server on 127.0.0.1:<installer port> with the key from
#                                                      the key file (PID in .build/spike-logs)
#   scripts/pi-rpc-spike.sh llama-stop                 stop exactly that llama-server
#   scripts/pi-rpc-spike.sh env                        print the environment for probe runs (eval "$(... env)")
#   scripts/pi-rpc-spike.sh app [manual|wave2d]        Pippa window with PIPPA_PI_RPC=1 (scripted snapshot "pirpc",
#                                                      the wave2d snapshot, or drive it yourself); the app starts llama-server itself
#   scripts/pi-rpc-spike.sh r2 [hbsomiW|all]           shown items, read_document, look up online (PiRPCR2Spike, run swift build first)
#   scripts/pi-rpc-spike.sh r3 [hfbar|all]             calendar, reminder, mail draft (PiRPCR3Spike, stand-in connections)
#   scripts/pi-rpc-spike.sh r7 latency|cold|slot|ans1|sort  acceptance run (PiRPCR2Spike r7, server as in the app)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
logs="$root/.build/spike-logs"
home="$root/.build/spike-home"
agent="$home/.pi/agent"
support="$home/Library/Application Support/Pippa"
payload="${PIPPA_PI_PAYLOAD:-$root/.build/pi-payload}"
work="$root/.build/spike-work"
sessions="$root/.build/spike-sessions"
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
  [ -f "$support/llama-key" ] || { echo "run first: $0 setup"; exit 2; }
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
setup)
  mkdir -p "$work" "$sessions" "$trash"
  # Like the app: detect installer steps, install Pi, write models.json in the fake HOME (PiSetupSpike --install-only).
  PIPPA_PI_PAYLOAD="$payload" "$root/app/.build/debug/PiSetupSpike" --install-only "$home" k2-horizon-7b qwen3.5-4b-q4
  # No project resources, quiet start; the model comes via --provider/--model from PiInstaller.launchSpec.
  cat >"$agent/settings.json" <<EOF
{
  "defaultProjectTrust": "never",
  "quietStartup": true
}
EOF
  echo "Pi in the fake HOME $home"
  ;;
env)
  echo "export PIPPA_PI_HOME='$home'"
  echo "export PIPPA_PI_PAYLOAD='$payload'"
  echo "export PI_CODING_AGENT_DIR='$agent'"
  echo "export PI_OFFLINE=1"
  echo "export PI_SKIP_VERSION_CHECK=1"
  echo "export PI_TELEMETRY=0"
  echo "export PIPPA_SPIKE_WORK='$work'"
  echo "export PIPPA_PI_EXTENSIONS='$tools'"
  echo "export PIPPA_PI_WEB='$web'"
  echo "export PIPPA_SPIKE_SESSIONS='$sessions'"
  echo "export PIPPA_TRASH_DIR='$trash'"
  ;;
r2)
  # Corpus: .build/quality/ctxsug-corpus (swift scripts/quality/make-ctxsug-corpus.swift).
  # Web (case W): runtime/pippa-web with its node_modules (npm ci there first); goes to the network.
  shift
  export PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="${PIPPA_PI_MODEL:-k2-horizon-7b}"
  export PI_CODING_AGENT_DIR="$agent" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
  export PIPPA_SPIKE_WORK="$work" PIPPA_PI_EXTENSIONS="$tools" PIPPA_PI_WEB="$web"
  export PIPPA_SPIKE_SESSIONS="$sessions" PIPPA_TRASH_DIR="$trash" PIPPA_SPIKE_PORT="$port"
  (cd "$root" && "$root/app/.build/debug/PiRPCR2Spike" rpc "${1:-all}" -AppleLanguages "(de)") 2>&1 | tee "$logs/r2-${1:-all}.log"
  ;;
r7)
  # Acceptance run on the standard path. The llama-server comes from PiLocalServer.plan as in the app (port, key,
  # slot folder in the fake HOME); do not start one with llama-start beforehand.
  shift
  export PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="${PIPPA_PI_MODEL:-k2-horizon-7b}"
  export PI_CODING_AGENT_DIR="$agent" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
  export PIPPA_SPIKE_WORK="$work" PIPPA_PI_EXTENSIONS="$tools"
  export PIPPA_SPIKE_SESSIONS="$sessions" PIPPA_TRASH_DIR="$trash" PIPPA_R7_LOGS="$logs/r7"
  export PIPPA_LLAMA_SERVER="$( [ -x "$root/dist/Pippa.app/Contents/Helpers/llama-server" ] && echo "$root/dist/Pippa.app/Contents/Helpers/llama-server" || echo "$cache/llama-b11503/llama-server")"
  case "$PIPPA_PI_MODEL" in
    qwen*) export PIPPA_MODEL_FILE="$cache/models/Qwen3.5-4B-Q4_K_M.gguf" ;;
    *) export PIPPA_MODEL_FILE="$cache/models/K2-Horizon-7B-Q4_K_M.gguf" ;;
  esac
  name=$(echo "$*" | tr ' ' '-')
  (cd "$root" && "$root/app/.build/debug/PiRPCR2Spike" r7 "$@" -AppleLanguages "(de)") 2>&1 | tee "$logs/r7-${name:-latency}-$(date +%H%M%S).log"
  ;;
r3)
  # Calendar, reminder, mail draft only with stand-in connections (never real Mail/Calendar).
  shift
  export PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="${PIPPA_PI_MODEL:-k2-horizon-7b}"
  export PI_CODING_AGENT_DIR="$agent" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
  export PIPPA_SPIKE_WORK="$work" PIPPA_PI_EXTENSIONS="$tools"
  export PIPPA_SPIKE_SESSIONS="$sessions" PIPPA_TRASH_DIR="$trash" PIPPA_SPIKE_PORT="$port"
  (cd "$root" && "$root/app/.build/debug/PiRPCR3Spike" "${1:-all}" -AppleLanguages "(de)") 2>&1 | tee "$logs/r3-${PIPPA_PI_MODEL}-${1:-all}.log"
  ;;
app)
  # Real Pippa window (debug build) against the real Pi: snapshot PIPPA_SNAPSHOT_ONLY=pirpc, quits by itself.
  # With "app manual" the app starts with the switch only, no snapshot (then type and click yourself).
  # PI_CODING_AGENT_DIR only here, so ~/.pi stays untouched; the app itself never sets it (PippaPiLaunch).
  # Sessions end up in the snapshot's support folder (PIPPA_SNAPSHOT/support/pi-sessions).
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
    # PIPPA_APP_SCENARIO=pirpc-r2 (shown items, look up online; corpus .build/quality/ctxsug-corpus, network).
    scenario="${PIPPA_APP_SCENARIO:-pirpc}"
    export PIPPA_SNAPSHOT="$shot" PIPPA_SNAPSHOT_ONLY="$scenario" PIPPA_R2_CORPUS="$root/.build/quality/ctxsug-corpus"
    "$root/app/.build/debug/Pippa" >"$logs/app.log" 2>&1
    echo "Report: $shot/$scenario.txt"
  fi
  ;;
*)
  sed -n '2,20p' "$0"; exit 2 ;;
esac
