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
import hashlib, http.server, json, sys, threading, time
payload = bytes(range(256)) * 2048
# Mirror checks (routes mx-*): bytes without a period, so a piece fetched from the wrong offset can never match.
mixed = b''.join(hashlib.sha256(i.to_bytes(4, 'big')).digest() for i in range(16384))
log, lock = {}, threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def send_body(self, body, offset, slow=False, stop=None):
        """200 for the whole body, 206 from `offset`; `stop`: end the connection after that many bytes of the body."""
        ranged = offset is not None
        start = offset or 0
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Length', str(len(body) - start))
        if ranged: self.send_header('Content-Range', f'bytes {start}-{len(body)-1}/{len(body)}')
        self.end_headers()
        end = len(body) if stop is None else min(len(body), stop)
        try:
            for i in range(start, end, 8192):
                self.wfile.write(body[i:min(i + 8192, end)]); self.wfile.flush()
                if slow: time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass

    def do_GET(self):
        parts = self.path.strip('/').split('/')
        offset = int(self.headers['Range'].split('=')[1].split('-')[0]) if 'Range' in self.headers else None
        if parts[0] == 'log':  # /log/<route>: every request of that route so far
            with lock: body = json.dumps(log.get(parts[1], [])).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body); return
        if parts[0] == 'mirror':  # /mirror/<route>/<partSize>/<name>[.part-<i>]
            route, size, name = parts[1], int(parts[2]), parts[3]
            with lock: log.setdefault(route, []).append({'source': 'mirror', 'name': name, 'range': offset})
            base, _, index = name.partition('.part-')
            if base != 'weights--model.gguf':
                self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
            body = mixed[int(index) * size:(int(index) + 1) * size] if index else mixed
            if route == 'mx-bad' and index == '1':
                body = body[:100] + bytes([body[100] ^ 1]) + body[101:]
            # mx-mdrop: part 1 ends halfway with the connection, the way a broken download does.
            stop = len(body) // 2 if route == 'mx-mdrop' and index == '1' else None
            self.send_body(body, offset, slow=route == 'mx-slow', stop=stop); return
        route = parts[1] if len(parts) > 1 else ''
        if route.startswith('mx-'):
            with lock:
                seen = log.setdefault(route, [])
                first = not any(r['source'] == 'hf' for r in seen)
                seen.append({'source': 'hf', 'name': parts[-1], 'range': offset})
            if route in ('mx-403', 'mx-bad', 'mx-slow'):
                self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers(); return
            if route == 'mx-drop':
                return  # no answer: the connection just closes
            if route == 'mx-40' and offset is None:
                self.send_body(mixed, None, stop=len(mixed) * 4 // 10); return
            if route == 'mx-mdrop' and first:
                self.send_response(503); self.send_header('Content-Length', '0'); self.end_headers(); return
            self.send_body(mixed, offset); return
        if 'ignore-range' in self.path: offset = None
        self.send_body(payload, offset, slow='/slow/' in self.path)

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
