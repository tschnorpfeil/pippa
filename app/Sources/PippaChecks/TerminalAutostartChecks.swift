import Foundation
import PippaCore

// `pi` in the terminal starts Pippa's oMLX server itself (runtime/pippa-local-server). This is the Swift side: the shared
// lock file (`PiServerLock`, same format as common.mjs), the plan and the launch file for the extension
// (`PiLocalServer.plan`, `publishLaunchFile`), oMLX's settings.json (`writeServerSettings`), the app starting and
// stopping its own server (`OMLXServer`, with a stand-in python that only answers /health) and installing the
// extension (`PiInstaller.installTerminalExtension`). Fake HOME; the extension itself is tested by
// runtime/pippa-local-server/test/*.test.mjs. Runs with PIPPA_SETUP_CHECKS=1 and in the full run.

/// An unpacked runtime as in development (`PIPPA_MLX_RUNTIME_DIR`): only an executable `bin/python3`.
/// `script`: its content; by default it does nothing.
func fakeRuntimeDirectory(in base: URL, script: String = "#!/bin/sh\nexit 0\n") -> URL {
    let runtime = base.appendingPathComponent("mlx-runtime-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let python = runtime.appendingPathComponent("bin/python3")
    try? fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    write(script, python)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    return runtime
}

func fakeRuntimeManifest(size: Int64, sha256: String, url: String = "https://example.invalid/runtime.tar.gz") -> MLXRuntime.Manifest {
    let json = #"{"version": "9.9.9-1", "omlx": "9.9.9", "file": "pippa-mlx-runtime-check.tar.gz", "size": \#(size), "sha256": "\#(sha256)", "url": "\#(url)"}"#
    return try! JSONDecoder().decode(MLXRuntime.Manifest.self, from: Data(json.utf8))
}

/// A runtime archive like scripts/build-mlx-runtime.sh makes: one top folder with `bin/python3`.
/// `padding`: bytes of incompressible filler, for a download check (a tiny body is not delivered until the connection ends).
func fakeRuntimeArchive(in base: URL, padding: Int = 0) throws -> URL {
    let source = base.appendingPathComponent("runtime-src", isDirectory: true)
    let python = source.appendingPathComponent("pippa-mlx-runtime/bin/python3")
    try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    if padding > 0 { try Data((0..<padding).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("pippa-mlx-runtime/filler.bin")) }
    write("#!/bin/sh\nexit 0\n", python)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let archive = base.appendingPathComponent("pippa-mlx-runtime-check.tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", archive.path, "-C", source.path, "pippa-mlx-runtime"]
    tar.environment = ["COPYFILE_DISABLE": "1"]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else { throw PippaError.writeFailed("tar \(tar.terminationStatus)") }
    return archive
}

/// The bundled model's files in `<Support>/omlx/models/<key>/`, marked verified. Sparse files of the pinned sizes:
/// nothing is read, so no real weights are needed.
func installFakeBundledModel(support: URL) throws -> CatalogModel {
    guard let model = ModelCatalog.bundled().models.first, let files = model.pinned?.files else { throw PippaError.modelUnavailable }
    let folder = PiLocalServer.baseDirectory(support: support).appendingPathComponent("models/\(model.key)", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in files {
        let url = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.size))
        try handle.close()
        try file.sha256.write(to: url.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
    }
    return model
}

/// Stand-in for oMLX: reads the port from `<base-path>/settings.json` and answers 200 on every GET.
private let fakeOMLX = #"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
base = sys.argv[sys.argv.index("--base-path") + 1]
port = json.load(open(base + "/settings.json"))["server"]["port"]
class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *args): pass
HTTPServer(("127.0.0.1", port), Health).serve_forever()
"""#

func runTerminalAutostartChecks() async {
    let ornith = ModelCatalog.bundled().models.first?.key ?? "-"

    /// Fake HOME with payload (metadata.json + extension), port, key, models.json, runtime and the model in place.
    func setup(_ name: String, contextWindow: Int = 16384, runtimeScript: String = "#!/bin/sh\nexit 0\n")
        throws -> (roots: PiInstallRoots, environment: [String: String]) {
        let home = dir(name)
        let payload = home.appendingPathComponent("payload", isDirectory: true)
        let release = payload.appendingPathComponent("release", isDirectory: true)
        try fm.createDirectory(at: release, withIntermediateDirectories: true)
        write(#"{"version":"1.1.0"}"#, release.appendingPathComponent("metadata.json"))
        let ext = payload.appendingPathComponent("extensions/pippa-local-server", isDirectory: true)
        try fm.createDirectory(at: ext, withIntermediateDirectories: true)
        for file in ["index.ts", "common.mjs", "ensure.mjs", "supervisor.mjs"] { write("// \(file)\n", ext.appendingPathComponent(file)) }
        let roots = PiInstallRoots(home: home, payload: try PiPayload(release: release, node: URL(fileURLWithPath: "/usr/bin/false")), searchPath: [])
        let port = PiInstaller.stablePort(support: roots.support)
        let entry = PiInstaller.providerEntry(models: [PiProviderModel(id: ornith, name: "Ornith", contextWindow: contextWindow)],
                                              port: port, keyFile: PiInstaller.keyFile(support: roots.support))
        try fm.createDirectory(at: roots.agentDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["providers": [PiInstaller.providerKey: entry]]).write(to: roots.modelsJSON)
        _ = try installFakeBundledModel(support: roots.support)
        let runtime = fakeRuntimeDirectory(in: home, script: runtimeScript)
        return (roots, ["PIPPA_MLX_RUNTIME_DIR": runtime.path])
    }

    check("Lock file: <Support>/local-server.lock, created exclusively only, same format as common.mjs, live according to server or holder, removes only its own") {
        let support = dir("ta-lock")
        let url = PiServerLock.url(support: support)
        let me = getpid()
        let first = try PiServerLock.create(url, PiServerLock(owner: "app", holder: me, pid: nil, port: 1234))
        let second = try PiServerLock.create(url, PiServerLock(owner: "pi", holder: 1, pid: nil, port: 1234))
        let read = PiServerLock.read(url)
        let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let notOurs = !PiServerLock.remove(url) { $0.owner == "pi" }
        // This is how supervisor.mjs writes it (JSON.stringify): pid null at startup, then the server's.
        write(#"{"owner":"pi","holder":999999,"pid":null,"port":1234,"startedAt":"2026-10-08T00:00:00.000Z"}"#, url)
        let jsStarting = PiServerLock.read(url)
        write(#"{"owner":"pi","holder":\#(me),"pid":999998,"port":1234,"startedAt":"x"}"#, url)
        let deadServer = PiServerLock.read(url)
        let removed = PiServerLock.remove(url) { $0.owner == "pi" }
        return url.lastPathComponent == "local-server.lock" && url.deletingLastPathComponent().path == support.path
            && first && !second && read?.owner == "app" && read?.holder == me && read?.pid == nil && read?.isLive == true && mode == 0o600
            && notOurs && jsStarting?.pid == nil && jsStarting?.isLive == false
            && deadServer?.isLive == false   // Server dead: orphaned, even if the holder is still alive
            && removed && !fm.fileExists(atPath: url.path)
    }
    check("Lock file: a write error is an error, not a lock someone else holds") {
        let url = PiServerLock.url(support: dir("ta-lock-missing").appendingPathComponent("gone"))
        do { _ = try PiServerLock.create(url, PiServerLock(owner: "app", holder: getpid(), pid: nil, port: 1234)); return false }
        catch { return !fm.fileExists(atPath: url.path) }
    }

    check("Local server plan: runtime python, <Support>/omlx, stable port and key; context from memory, never above models.json") {
        let (roots, env) = try setup("ta-plan")
        let plan = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 16 << 30, environment: env)
        let base = roots.support.appendingPathComponent("omlx", isDirectory: true)
        let key = try PiInstaller.stableKey(support: roots.support)
        let planOK = plan.python.path == URL(fileURLWithPath: env["PIPPA_MLX_RUNTIME_DIR"]!).appendingPathComponent("bin/python3").path
            && plan.baseDirectory.path == base.path && plan.modelsDirectory.path == base.appendingPathComponent("models").path
            && plan.settingsFile.path == base.appendingPathComponent("settings.json").path
            && plan.port == PiInstaller.stablePort(support: roots.support) && plan.key == key
            && plan.modelID == ornith && plan.choice.model.key == ornith && plan.choice.ctx == 16384
            && plan.lockFile == PiServerLock.url(support: roots.support) && plan.keyFile == PiInstaller.keyFile(support: roots.support)
        // 24 GB gets 32K; a stale 32K entry cannot enlarge the 16 GB context; a 16K entry bounds a 24 GB Mac.
        let (wide, wideEnv) = try setup("ta-plan-32k", contextWindow: 32768)
        let on24 = try PiLocalServer.plan(roots: wide, modelID: ornith, physicalMemory: 24 << 30, environment: wideEnv).choice.ctx
        let on16 = try PiLocalServer.plan(roots: wide, modelID: ornith, physicalMemory: 16 << 30, environment: wideEnv).choice.ctx
        let bounded = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 24 << 30, environment: env).choice.ctx
        if !planOK { print("   ", plan) }
        return planOK && on24 == 32768 && on16 == 16384 && bounded == 16384
    }

    check("Local server plan: clear failures for a missing runtime, an unknown or missing model and a port that moved") {
        let (roots, env) = try setup("ta-plan-fail")
        func failure(_ body: () throws -> Any) -> PiLocalServer.Failure? {
            do { _ = try body(); return nil } catch { return error as? PiLocalServer.Failure }
        }
        let noRuntime = failure { try PiLocalServer.plan(roots: roots, modelID: ornith, environment: ["PIPPA_MLX_RUNTIME_DIR": dir("ta-empty-runtime").path]) }
        let unknown = failure { try PiLocalServer.plan(roots: roots, modelID: "qwen3.5-9b-q4", environment: env) }
        try fm.removeItem(at: roots.support.appendingPathComponent("omlx/models/\(ornith)/model.safetensors.ok"))
        let missing = failure { try PiLocalServer.plan(roots: roots, modelID: ornith, environment: env) }
        let port = PiInstaller.stablePort(support: roots.support)
        let entry = PiInstaller.providerEntry(models: [PiProviderModel(id: ornith, name: "Ornith", contextWindow: 16384)],
                                              port: port + 1, keyFile: PiInstaller.keyFile(support: roots.support))
        try JSONSerialization.data(withJSONObject: ["providers": [PiInstaller.providerKey: entry]]).write(to: roots.modelsJSON)
        let moved = failure { try PiLocalServer.plan(roots: roots, modelID: ornith, environment: env) }
        return noRuntime == .runtimeMissing && unknown == .unknownModel("qwen3.5-9b-q4") && missing == .modelMissing(ornith)
            && moved == .portMismatch(modelsJSON: port + 1, settings: port)
    }

    check("Launch file v2 for the terminal extension: runtime python, oMLX serve arguments, no key in it, 0600, unchanged → not rewritten") {
        let (roots, env) = try setup("ta-launch")
        let plan = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 16 << 30, environment: env)
        let wrote = try PiLocalServer.publishLaunchFile(plan, support: roots.support)
        let again = try PiLocalServer.publishLaunchFile(plan, support: roots.support)
        let url = PiLocalServer.launchFile(support: roots.support)
        let text = try String(contentsOf: url, encoding: .utf8)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let args = json["arguments"] as? [String] ?? []
        let environment = json["environment"] as? [String: String] ?? [:]
        let serve = args.firstIndex(of: "serve").map { Array(args[$0...]) }
        return wrote && !again && mode == 0o600 && url.lastPathComponent == "pippa-local-server.json"
            && json["schemaVersion"] as? Int == 2 && json["provider"] as? String == "pippa-local"
            && json["port"] as? Int == plan.port && json["binary"] as? String == plan.python.path && json["modelID"] as? String == ornith
            && args == plan.arguments && serve == ["serve", "--base-path", plan.baseDirectory.path, "--headless"]
            && json["keyFile"] as? String == PiInstaller.keyFile(support: roots.support).path
            && json["logFile"] as? String == roots.support.appendingPathComponent("local-server.log").path
            && environment["HF_HUB_OFFLINE"] == "1"
            && environment["HOME"] == plan.baseDirectory.appendingPathComponent("home").path   // never the person's ~/.omlx
            && !text.contains(plan.key) && fm.fileExists(atPath: plan.settingsFile.path)
    }

    check("oMLX settings.json: port, key, model folder and sampling written (0600), the person's and oMLX's other keys stay") {
        let (roots, env) = try setup("ta-settings")
        let plan = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 16 << 30, environment: env)
        try fm.createDirectory(at: plan.baseDirectory, withIntermediateDirectories: true)
        write(#"{"server": {"port": 1, "custom": "x"}, "auth": {"api_key": "old"}, "sampling": {"temperature": 1.0, "repetition_penalty": 1.1}, "version": 3}"#, plan.settingsFile)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plan.settingsFile.path)
        try PiLocalServer.writeServerSettings(plan)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: plan.settingsFile)) as? [String: Any] ?? [:]
        let server = doc["server"] as? [String: Any], auth = doc["auth"] as? [String: Any], model = doc["model"] as? [String: Any]
        let mode = ((try? fm.attributesOfItem(atPath: plan.settingsFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        return server?["port"] as? Int == plan.port && server?["host"] as? String == "127.0.0.1" && server?["custom"] as? String == "x"
            && auth?["api_key"] as? String == plan.key && auth?["allow_unauthenticated_inference"] as? Bool == false
            && model?["model_dirs"] as? [String] == [plan.modelsDirectory.path]
            && (doc["idle_timeout"] as? [String: Any])?["idle_timeout_seconds"] as? Int == PiLocalServer.idleUnloadSeconds
            && (doc["sampling"] as? [String: Any])?["temperature"] as? Double == 0.6 && (doc["sampling"] as? [String: Any])?["top_k"] as? Int == 20
            && (doc["sampling"] as? [String: Any])?["repetition_penalty"] as? Double == 1.1 && doc["version"] as? Int == 3
            && mode == 0o600
    }

    await checkAsync("Prewarming: healthy server still loads weights, concurrent callers share a load, failure retries and later calls reload") {
        let script = dir("ta-warm-script").appendingPathComponent("fake-omlx.py")
        write(#"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
base = sys.argv[sys.argv.index("--base-path") + 1]
settings = json.load(open(base + "/settings.json"))
loads = 0
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_POST(self):
        global loads
        loads += 1
        authenticated = self.headers.get("Authorization") == "Bearer " + settings["auth"]["api_key"]
        with open(base + "/requests.jsonl", "a") as log:
            log.write(json.dumps({"path": self.path, "authenticated": authenticated,
                                  "body_length": int(self.headers.get("Content-Length", "0"))}) + "\n")
        time.sleep(0.15)
        self.send_response(503 if loads == 1 else 200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *args): pass
HTTPServer(("127.0.0.1", settings["server"]["port"]), Handler).serve_forever()
"""#, script)
        let (roots, env) = try setup("ta-warm", runtimeScript: "#!/bin/sh\nexec /usr/bin/python3 '\(script.path)' \"$@\"\n")
        let plan = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 16 << 30, environment: env)
        let server = PiLocalServer.server(plan, logDirectory: roots.support)
        do {
            try await server.ensureRunning()
            var failed = false
            do { try await server.prewarm() } catch { failed = true }
            async let first: Void = server.prewarm()
            async let second: Void = server.prewarm()
            _ = try await (first, second)
            // A later edit must consult oMLX again: the model could have been idle-unloaded meanwhile.
            try await server.prewarm()
            let log = try String(contentsOf: plan.baseDirectory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            let requests = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            await server.stop()
            return failed && requests.count == 3 && requests.allSatisfy {
                $0["path"] as? String == "/v1/models/\(ornith)/load" && $0["authenticated"] as? Bool == true && $0["body_length"] as? Int == 0
            }
        } catch { await server.stop(); throw error }
    }

    await checkAsync("App starts its own server: an orphaned lock is replaced, lock \"app\" with the server's PID, gone after stop") {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else { print("    no /usr/bin/python3, skipped"); return true }
        let script = dir("ta-own-script").appendingPathComponent("fake-omlx.py")
        write(fakeOMLX, script)
        let (roots, env) = try setup("ta-own", runtimeScript: "#!/bin/sh\nexec /usr/bin/python3 '\(script.path)' \"$@\"\n")
        let plan = try PiLocalServer.plan(roots: roots, modelID: ornith, physicalMemory: 16 << 30, environment: env)
        let lock = PiServerLock.url(support: roots.support)
        write(#"{"owner":"pi","holder":999999,"pid":999998,"port":\#(plan.port),"startedAt":"x"}"#, lock)
        let server = PiLocalServer.server(plan, logDirectory: roots.support)
        try await server.ensureRunning()
        let held = PiServerLock.read(lock)
        let pid = await server.processID
        await server.stop()
        let gone = await server.processID == nil && !fm.fileExists(atPath: lock.path)
        let alive = pid.map { kill($0, 0) == 0 } ?? true
        return held?.owner == "app" && held?.holder == getpid() && held?.pid == pid && pid != nil && gone && !alive
    }

    check("Installer: terminal extension to ~/.pi/agent/extensions/pippa-local-server, same → unchanged, new payload → replaced, foreign folder stays") {
        let (roots, _) = try setup("ta-install")
        let installer = PiInstaller(roots: roots)
        let dest = roots.extensionsDirectory.appendingPathComponent("pippa-local-server", isDirectory: true)
        let first = installer.installTerminalExtension()
        let index = (try? String(contentsOf: dest.appendingPathComponent("index.ts"), encoding: .utf8)) ?? ""
        let marked = fm.fileExists(atPath: dest.appendingPathComponent(PiInstaller.terminalExtensionMarker).path)
        let second = installer.installTerminalExtension()
        guard let source = roots.payload.terminalExtension else { return false }
        write("// new\n", source.appendingPathComponent("index.ts"))
        let third = installer.installTerminalExtension()
        let updated = (try? String(contentsOf: dest.appendingPathComponent("index.ts"), encoding: .utf8)) == "// new\n"
        let leftovers = ((try? fm.contentsOfDirectory(atPath: roots.agentDirectory.path)) ?? []).filter { $0.hasPrefix(".pippa-extension") }
        // A folder of the same name that someone else created.
        let (other, _) = try setup("ta-foreign")
        let foreign = other.extensionsDirectory.appendingPathComponent("pippa-local-server", isDirectory: true)
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        write("// mine\n", foreign.appendingPathComponent("index.ts"))
        let kept = PiInstaller(roots: other).installTerminalExtension()
        let mine = (try? String(contentsOf: foreign.appendingPathComponent("index.ts"), encoding: .utf8)) == "// mine\n"
        return first == .installed && index == "// index.ts\n" && marked && second == .unchanged && third == .updated && updated
            && leftovers.isEmpty && kept == .foreign && mine && PiInstallState.load(from: roots.stateFile).didCreate(dest)
    }

    check("Installer step \"models.json\" also installs the terminal extension; without an extension in the payload the step still succeeds") {
        let (roots, _) = try setup("ta-step")
        let options = PiInstallOptions(model: nil, providerModels: [PiProviderModel(id: ornith, name: "Ornith", contextWindow: 16384)],
                                       port: PiInstaller.stablePort(support: roots.support))
        let done = PiInstaller(roots: roots).perform(.provider, options).isDone
        let installed = fm.fileExists(atPath: roots.extensionsDirectory.appendingPathComponent("pippa-local-server/index.ts").path)
        try fm.removeItem(at: roots.payload.release.deletingLastPathComponent().appendingPathComponent("extensions"))
        let withoutExtension = PiInstaller(roots: roots).installTerminalExtension()
        return done && installed && withoutExtension == .unavailable
    }
}
