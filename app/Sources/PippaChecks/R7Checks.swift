import Foundation
import PippaCore

// Prompt cache across unloading when idle. The llama-server for `pippa-local` starts with
// `--slot-save-path <Support>/llama-slots` and `--swa-full`; slot 0 is saved before unloading and restored after the
// next start before the first request. A small Python program plays llama-server (no model).
// Runs with PIPPA_R7_CHECKS=1 and in the full run.

/// Stand-in for llama-server with `/slots/0?action=save|restore`: writes or reads the file in `--slot-save-path` and
/// logs every request (method, path) to $FAKE_R7_LOG.
private let fakeSlotLlama = """
#!/usr/bin/python3
import http.server, json, os, sys, time, urllib.parse
args = sys.argv[1:]
if "--help" in args:
    print("--host --port --alias --jinja --ctx-size --parallel --no-webui --slot-save-path --swa-full")
    sys.exit(0)
port = int(args[args.index("--port") + 1])
slots = args[args.index("--slot-save-path") + 1] if "--slot-save-path" in args else None
key = os.environ.get("LLAMA_API_KEY", "")
log = os.environ["FAKE_R7_LOG"]
def note(s):
    with open(log, "a") as f: f.write(s + "\\n")
note("start " + json.dumps(args))
time.sleep(0.3)
class H(http.server.BaseHTTPRequestHandler):
    def ok(self, body):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + key: self.send_response(401); self.end_headers(); return
        self.ok({"status": "ok"} if self.path == "/health" else [{"id": 0, "is_processing": False}])
    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer " + key: self.send_response(401); self.end_headers(); return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        q = urllib.parse.urlparse(self.path)
        action = urllib.parse.parse_qs(q.query).get("action", [""])[0]
        note("POST " + q.path + " " + action + " " + body.get("filename", ""))
        if slots is None or "/" in body.get("filename", "/"): self.send_response(400); self.end_headers(); return
        path = os.path.join(slots, body["filename"])
        if action == "save":
            with open(path, "wb") as f: f.write(b"x" * 4096)
            self.ok({"id_slot": 0, "filename": body["filename"], "n_saved": 1234})
        elif action == "restore" and os.path.exists(path):
            self.ok({"id_slot": 0, "filename": body["filename"], "n_restored": 1234})
        else:
            self.send_response(400); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"""

func runR7Checks() async {
    print("\n— R7: prompt cache across unloading —")
    let base = dir("r7")
    let binary = base.appendingPathComponent("fake-llama-server")
    write(fakeSlotLlama, binary)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let log = base.appendingPathComponent("requests.log")
    setenv("FAKE_R7_LOG", log.path, 1)
    guard let choice = ModelSelector.named("gemma-4-12b", physicalMemory: 16 << 30) else {
        check("R7: catalog knows gemma-4-12b") { false }; return
    }

    check("R7: with slot folder --slot-save-path and --swa-full; LocalEngine server without both") {
        let slots = URL(fileURLWithPath: "/S/Pippa/llama-slots", isDirectory: true)
        let with = LlamaServer.arguments(choice: choice, model: URL(fileURLWithPath: "/m.gguf"), port: 1, supported: nil, alias: "gemma-4-12b",
                                         slotSavePath: slots, swaFull: true).joined(separator: " ")
        let without = LlamaServer.arguments(choice: choice, model: URL(fileURLWithPath: "/m.gguf"), port: 1, supported: nil).joined(separator: " ")
        let unknown = LlamaServer.arguments(choice: choice, model: URL(fileURLWithPath: "/m.gguf"), port: 1, supported: ["--alias"], alias: "a",
                                            slotSavePath: slots, swaFull: true)
        return with.contains("--slot-save-path /S/Pippa/llama-slots") && with.contains("--swa-full")
            && !without.contains("--slot-save-path") && !without.contains("--swa-full")
            && !unknown.contains("--slot-save-path") && !unknown.contains("--swa-full")   // old llama.cpp without these switches
    }
    check("R7: slot file name per model and context, allowed characters only") {
        let a = LlamaServer.slotFileName(alias: "gemma-4-12b", model: URL(fileURLWithPath: "/x/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"), ctx: 16384)
        let b = LlamaServer.slotFileName(alias: "gemma-4-12b", model: URL(fileURLWithPath: "/x/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"), ctx: 8192)
        let odd = LlamaServer.slotFileName(alias: "a/b c", model: URL(fileURLWithPath: "/x/Mein Modell (neu).gguf"), ctx: 1)
        return a == "pippa-slot-gemma-4-12b-gemma-4-12B-it-qat-UD-Q4_K_XL-c16384.bin" && a != b
            && !odd.contains("/") && !odd.contains(" ") && !odd.contains("(") && odd.hasSuffix(".bin")
    }

    await checkAsync("R7: idle saves slot 0 before unloading (file 0600), next start restores it before the first request; deleting removes it") {
        try? fm.removeItem(at: log)
        let support = dir("r7-server")
        let slots = support.appendingPathComponent("llama-slots", isDirectory: true)
        let port = PiInstaller.stablePort(support: support)
        let key = try PiInstaller.stableKey(support: support)
        let server = LlamaServer(choice: choice, modelPath: URL(fileURLWithPath: "/m/gemma.gguf"), binary: binary, logDirectory: support,
                                 fixedPort: port, fixedKey: key, alias: "gemma-4-12b", idleAfter: 1.0, logName: "llama-server-pi.log",
                                 slotDirectory: slots)
        let lease = try await server.acquireAgentLease()
        let firstRestore = await server.lastSlotRestore            // nothing saved → nothing restored
        await server.releaseAgentLease(lease)
        var unloaded = false
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(150)); if await server.processID == nil { unloaded = true; break } }
        guard let file = await server.slotFile else { return false }
        let saved = await server.lastSlotSave
        let mode = ((try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let dirMode = ((try? fm.attributesOfItem(atPath: slots.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let again = try await server.acquireAgentLease()
        let restored = await server.lastSlotRestore
        await server.releaseAgentLease(again)
        await server.stop()
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let posts = lines.filter { $0.hasPrefix("POST") }
        let startsWithSlots = lines.filter { $0.hasPrefix("start") }.allSatisfy { $0.contains("--slot-save-path") && $0.contains("--swa-full") }
        await server.discardSavedSlot()
        let gone = !fm.fileExists(atPath: file.path)
        return firstRestore == nil && unloaded && saved?.ok == true && saved?.tokens == 1234 && mode == 0o600 && dirMode == 0o700
            && restored?.ok == true && posts.count == 2 && posts[0].contains("/slots/0 save pippa-slot-gemma-4-12b-gemma-c")
            && posts[1].contains("/slots/0 restore") && startsWithSlots && gone
    }

    check("R7: deleting conversation data removes only Pippa's slot files") {
        let support = dir("r7-discard")
        let slots = support.appendingPathComponent("llama-slots", isDirectory: true)
        try fm.createDirectory(at: slots, withIntermediateDirectories: true)
        write("x", slots.appendingPathComponent("pippa-slot-a-b-c1.bin"))
        write("x", slots.appendingPathComponent("fremd.bin"))
        PiLocalServer.discardSavedSlots(support: support)
        return !fm.fileExists(atPath: slots.appendingPathComponent("pippa-slot-a-b-c1.bin").path)
            && fm.fileExists(atPath: slots.appendingPathComponent("fremd.bin").path)
    }
}
