#!/bin/sh
# r7 latency (18 answers: 3 rounds x 3 shown items x short texts on/off) for one variant, on the app's own server path
# (PiRPCR2Spike r7 latency: PiLocalServer.plan starts llama-server as the app does, slot cache included).
# Own fake HOME per variant; models.json/settings.json as variants.mjs writes them (ctx 32768, Qwen sampling per level).
#   PIPPA_MC_LLAMA=<patched llama-server> scripts/quality/model-compare/r7.sh <A|B|C> <log>
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
v="$1"; log="$2"
home="$root/.build/mc-r7-$v"
payload="$root/.build/pi-payload"
node="$payload/bin/node"
rm -rf "$home"; mkdir -p "$home/work" "$home/undo" "$home/sessions" "$home/trash"
key=$("$node" -e "import('$root/scripts/quality/model-compare/variants.mjs').then(m=>console.log(m.VARIANTS['$v'].key))")
file=$("$node" -e "import('$root/scripts/quality/model-compare/variants.mjs').then(m=>console.log(m.VARIANTS['$v'].file))")
HOME="$home" CFFIXED_USER_HOME="$home" PIPPA_PI_PAYLOAD="$payload" "$root/app/.build/debug/PiSetupSpike" --install-only "$home" "$key" >/dev/null
# Keep port and key from the installer, replace the model entry and the settings by the variant's.
"$node" -e "
const fs=require('fs');import('$root/scripts/quality/model-compare/variants.mjs').then(m=>{
const p='$home/.pi/agent/models.json';const j=JSON.parse(fs.readFileSync(p));const v=m.VARIANTS['$v'];
j.providers['pippa-local'].models=[m.modelEntry(v)];fs.writeFileSync(p,JSON.stringify(j,null,1));
fs.writeFileSync('$home/.pi/agent/settings.json',JSON.stringify(m.piSettings(v),null,1));});"
# One llama-server at a time on this Mac, load < 10.
while pgrep -x llama-server >/dev/null || [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -ge 10 ]; do
  echo "waiting: $(pgrep -lx llama-server | tr '\n' ' ') load $(sysctl -n vm.loadavg)"; sleep 60
done
cd "$root"
env HOME="$home" CFFIXED_USER_HOME="$home" PIPPA_PI_HOME="$home" PIPPA_PI_PAYLOAD="$payload" PIPPA_PI_MODEL="$key" \
  PI_CODING_AGENT_DIR="$home/.pi/agent" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 \
  PIPPA_UNDO_DIR="$home/undo" PIPPA_SPIKE_WORK="$home/work" PIPPA_PI_GUARD="$root/runtime/pippa-guard/pippa-guard.ts" \
  PIPPA_PI_TOOLS="$root/runtime/pippa-guard/pippa-tools.ts" PIPPA_SPIKE_SESSIONS="$home/sessions" PIPPA_TRASH_DIR="$home/trash" \
  PIPPA_R7_LOGS="$home/r7-logs" PIPPA_LLAMA_SERVER="$PIPPA_MC_LLAMA" PIPPA_MODEL_FILE="$file" \
  "$root/app/.build/debug/PiRPCR2Spike" r7 latency 3 -AppleLanguages "(de)" 2>&1 | tee "$log"
