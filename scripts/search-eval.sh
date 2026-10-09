#!/bin/bash
# FTS vs EmbeddingGemma 2 vs hybrid on the synthetic corpus app/Fixtures/search-eval/corpus.json (PippaSearchEval).
# Needs the model file (PIPPA_EMBED_MODEL, default .build/models/embeddinggemma-2-BF16.gguf, from
# ggml-org/embeddinggemma-2-GGUF) and Pippa's llama-server. Starts a loopback embedding server, measures, stops it.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
model="${PIPPA_EMBED_MODEL:-$root/.build/models/embeddinggemma-2-BF16.gguf}"
bin="${PIPPA_LLAMA_SERVER:-$root/dist/Pippa.app/Contents/Helpers/llama-server}"
port="${PIPPA_EMBED_PORT:-53600}"
[ -f "$model" ] || { echo "model missing: $model"; exit 2; }
mkdir -p "$root/.build/spike-logs"
"$bin" -m "$model" --embedding --host 127.0.0.1 --port "$port" -ngl 999 -c 2048 -b 2048 -ub 2048 --parallel 1 --no-webui \
  >"$root/.build/spike-logs/embed.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -s -m 2 "http://127.0.0.1:$port/health" | grep -q ok && break; sleep 1; done
swift build --package-path "$root/app" --product PippaSearchEval >/dev/null
cd "$root"
PIPPA_EMBED_URL="http://127.0.0.1:$port/v1/embeddings" "$root/app/.build/debug/PippaSearchEval"
ps -o rss= -p "$server" | awk '{printf "embedding server RSS %.2f GB\n", $1/1048576}'
