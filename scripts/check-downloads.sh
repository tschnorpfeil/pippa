#!/usr/bin/env bash
# Small local HTTP fixtures; no real model download and no external network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
cat > "$WORK/server.py" <<'PY'
import http.server, sys, time
payload = bytes(range(256)) * 2048
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        offset = 0
        ranged = 'Range' in self.headers and 'ignore-range' not in self.path
        if ranged: offset = int(self.headers['Range'].split('=')[1].split('-')[0])
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Length', str(len(payload) - offset))
        if ranged: self.send_header('Content-Range', f'bytes {offset}-{len(payload)-1}/{len(payload)}')
        self.end_headers()
        try:
            for i in range(offset, len(payload), 8192):
                self.wfile.write(payload[i:i+8192]); self.wfile.flush()
                if '/slow/' in self.path: time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as f: f.write(str(server.server_port))
server.serve_forever()
PY
python3 "$WORK/server.py" "$WORK/port" &
SERVER_PID=$!
for ((i=0; i<100; i++)); do
  [[ -s "$WORK/port" ]] && break
  sleep 0.05
done
[[ -s "$WORK/port" ]] || { echo 'HTTP fixture failed to start' >&2; exit 1; }
CHECKS_BIN="${PIPPA_CHECKS_BIN:-$(swift build --package-path "$ROOT/app" --show-bin-path)/PippaChecks}"
[[ -x "$CHECKS_BIN" ]] || { echo 'Build PippaChecks first: cd app && swift build --product PippaChecks' >&2; exit 1; }
PIPPA_HF_ENDPOINT="http://127.0.0.1:$(cat "$WORK/port")" PIPPA_DOWNLOAD_CHECKS=1 "$CHECKS_BIN"
