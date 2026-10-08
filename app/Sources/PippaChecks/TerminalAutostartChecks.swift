import Foundation
import PippaCore

// `pi` in the terminal starts Pippa's llama-server itself (runtime/pippa-local-server). This is the Swift side: the shared
// lock file (`PiServerLock`, same format as common.mjs), the launch file for the extension
// (`PiLocalServer.publishLaunchFile`), the app sharing a terminal-started server (`LlamaServer`, `lockFile`)
// and installing the extension (`PiInstaller.installTerminalExtension`). Fake HOME, stand-in llama-server from
// Wave2dChecks; the extension itself is tested by runtime/pippa-local-server/test/*.test.mjs.
// Runs with PIPPA_SETUP_CHECKS=1 and in the full run (via runWave2dChecks).

func runTerminalAutostartChecks(binary: URL, argsLog: URL) async {
    func starts() -> Int { ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").count }

    /// Fake HOME with payload (metadata.json + extension), port, key, models.json and a developer model file.
    func setup(_ name: String) throws -> (roots: PiInstallRoots, plan: PiLocalServer.Plan) {
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
        let entry = PiInstaller.providerEntry(models: [PiProviderModel(id: "qwen3.5-9b-q4", name: "Qwen", contextWindow: 16384)],
                                              port: port, keyFile: roots.llamaKeyFile)
        try fm.createDirectory(at: roots.agentDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["providers": [PiInstaller.providerKey: entry]]).write(to: roots.modelsJSON)
        let model = home.appendingPathComponent("dev.gguf"); write("x", model)
        let plan = try PiLocalServer.plan(roots: roots, modelID: "qwen3.5-9b-q4", legacySupport: home.appendingPathComponent("legacy"),
                                          physicalMemory: 16 << 30, binary: binary, environment: ["PIPPA_MODEL_FILE": model.path])
        return (roots, plan)
    }

    /// A live process that only waits (holder of a foreign lock).
    func sleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
        try p.run()
        return p
    }

    check("Lock file: created exclusively only, same format as common.mjs, live according to server or holder, removes only its own") {
        let url = dir("ta-lock").appendingPathComponent(PiServerLock.fileName)
        let me = getpid()
        let first = PiServerLock.create(url, PiServerLock(owner: "app", holder: me, pid: nil, port: 1234))
        let second = PiServerLock.create(url, PiServerLock(owner: "pi", holder: 1, pid: nil, port: 1234))
        let read = PiServerLock.read(url)
        let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let notOurs = !PiServerLock.remove(url) { $0.owner == "pi" }
        // This is how supervisor.mjs writes it (JSON.stringify): pid null at startup, then the server's.
        write(#"{"owner":"pi","holder":999999,"pid":null,"port":1234,"startedAt":"2026-10-08T00:00:00.000Z"}"#, url)
        let jsStarting = PiServerLock.read(url)
        write(#"{"owner":"pi","holder":\#(me),"pid":999998,"port":1234,"startedAt":"x"}"#, url)
        let deadServer = PiServerLock.read(url)
        let removed = PiServerLock.remove(url) { $0.owner == "pi" }
        return first && !second && read?.owner == "app" && read?.holder == me && read?.pid == nil && read?.isLive == true && mode == 0o600
            && notOurs && jsStarting?.pid == nil && jsStarting?.isLive == false
            && deadServer?.isLive == false   // Server dead: orphaned, even if the holder is still alive
            && removed && !fm.fileExists(atPath: url.path)
    }

    check("Launch file for the terminal extension: program in Pippa.app, same arguments as the app, key only as a file, 0600, unchanged → not rewritten") {
        let (roots, base) = try setup("ta-launch")
        var plan = base
        let app = roots.home.appendingPathComponent("Applications/Pippa.app/Contents/Helpers/llama-server")
        plan.binary = app
        let flags: Set<String> = ["--host", "--port", "--alias", "--jinja", "--ctx-size", "--parallel", "--slot-save-path", "--no-webui"]
        let wrote = try PiLocalServer.publishLaunchFile(plan, support: roots.support, supported: flags)
        let again = try PiLocalServer.publishLaunchFile(plan, support: roots.support, supported: flags)
        let url = PiLocalServer.launchFile(support: roots.support)
        let text = try String(contentsOf: url, encoding: .utf8)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let expected = LlamaServer.arguments(choice: plan.choice, model: plan.modelFile, port: plan.port, supported: flags, alias: plan.modelID,
                                             slotSavePath: plan.slotDirectory)
        let args = json["arguments"] as? [String] ?? []
        return wrote && !again && mode == 0o600 && json["schemaVersion"] as? Int == 1 && json["provider"] as? String == "pippa-local"
            && json["port"] as? Int == plan.port && json["binary"] as? String == app.path
            && json["app"] as? String == roots.home.appendingPathComponent("Applications/Pippa.app").path
            && json["keyFile"] as? String == roots.llamaKeyFile.path && json["idleSeconds"] as? Int == 600
            && json["logFile"] as? String == roots.support.appendingPathComponent("llama-server-pi.log").path
            && args == expected && args.contains("--slot-save-path") && args.joined(separator: " ").contains("--host 127.0.0.1 --port \(plan.port)")
            && !text.contains(plan.key)
            && plan.lockFile == PiServerLock.url(support: roots.support)
    }

    await checkAsync("App starts itself: lock \"app\" with the server's PID, gone on exit; a second app with a lock → clear error, orphaned lock is replaced") {
        let (roots, plan) = try setup("ta-own")
        let lock = PiServerLock.url(support: roots.support)
        // Orphaned (processes gone): gets replaced.
        write(#"{"owner":"pi","holder":999999,"pid":999998,"port":\#(plan.port),"startedAt":"x"}"#, lock)
        let server = PiLocalServer.server(plan, logDirectory: roots.support)
        let lease = try await server.acquireAgentLease()
        let held = PiServerLock.read(lock)
        let pid = await server.processID
        await server.releaseAgentLease(lease)
        await server.stop()
        let removed = !fm.fileExists(atPath: lock.path)
        // Another app holds the lock (live holder, still starting): don't start alongside.
        let other = try sleeper()
        defer { other.terminate() }
        _ = PiServerLock.create(lock, PiServerLock(owner: "app", holder: other.processIdentifier, pid: nil, port: plan.port))
        var refused = false
        do { _ = try await PiLocalServer.server(plan, logDirectory: roots.support).acquireAgentLease() } catch { refused = true }
        let untouched = PiServerLock.read(lock)?.holder == other.processIdentifier
        try? fm.removeItem(at: lock)
        return held?.owner == "app" && held?.holder == getpid() && held?.pid == pid && pid != nil && removed && refused && untouched
    }

    await checkAsync("App server: if the terminal Pi uses it (lock file touched), the app unloads it only after the idle time that follows") {
        let (roots, base) = try setup("ta-idle")
        var plan = base
        plan.idleSeconds = 1.0
        let lock = PiServerLock.url(support: roots.support)
        let server = PiLocalServer.server(plan, logDirectory: roots.support)
        await server.releaseAgentLease(try await server.acquireAgentLease())
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(400)); PiServerLock.touch(lock) }   // Terminal keeps asking
        let stayed = await server.processID != nil
        var unloaded = false
        for _ in 0..<40 where !unloaded { try await Task.sleep(for: .milliseconds(100)); unloaded = await server.processID == nil }
        await server.stop()
        return stayed && unloaded && !fm.fileExists(atPath: lock.path)
    }

    await checkAsync("Terminal server is running: the app shares it (no second start), reports requests via the lock and never stops it") {
        let (roots, plan) = try setup("ta-adopt")
        let lock = PiServerLock.url(support: roots.support)
        // "Terminal": the stand-in server started directly, lock as written by the extension's supervisor.
        let initial = starts()
        let terminal = Process()
        terminal.executableURL = binary
        terminal.arguments = LlamaServer.arguments(choice: plan.choice, model: plan.modelFile, port: plan.port, supported: nil, alias: plan.modelID)
        terminal.environment = LlamaServer.environment(apiKey: plan.key)
        terminal.standardOutput = FileHandle.nullDevice; terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        defer { if terminal.isRunning { terminal.terminate() } }
        _ = PiServerLock.create(lock, PiServerLock(owner: "pi", holder: terminal.processIdentifier, pid: terminal.processIdentifier, port: plan.port))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: lock.path)
        for _ in 0..<50 where starts() == initial { try await Task.sleep(for: .milliseconds(100)) }   // start of the terminal server logged
        let before = starts()
        let server = PiLocalServer.server(plan, logDirectory: roots.support)
        let lease = try await server.acquireAgentLease()   // waits until the terminal server reports /health 200
        let adopted = await server.isAdopted
        let warm = await server.isWarm
        let pid = await server.processID
        let touched = ((try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date) ?? .distantPast).timeIntervalSinceNow > -5
        await server.releaseAgentLease(lease)
        await server.stop()
        try await Task.sleep(for: .milliseconds(200))
        let stillRunning = terminal.isRunning
        let lockKept = PiServerLock.read(lock)?.owner == "pi"
        terminal.terminate()
        try? fm.removeItem(at: lock)
        return adopted && warm && pid == terminal.processIdentifier && starts() == before && touched && lease.endpoint.port == plan.port
            && stillRunning && lockKept
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
        let options = PiInstallOptions(model: nil, providerModels: [PiProviderModel(id: "qwen3.5-9b-q4", name: "Qwen", contextWindow: 16384)],
                                       port: PiInstaller.stablePort(support: roots.support))
        let done = PiInstaller(roots: roots).perform(.provider, options).isDone
        let installed = fm.fileExists(atPath: roots.extensionsDirectory.appendingPathComponent("pippa-local-server/index.ts").path)
        try fm.removeItem(at: roots.payload.release.deletingLastPathComponent().appendingPathComponent("extensions"))
        let withoutExtension = PiInstaller(roots: roots).installTerminalExtension()
        return done && installed && withoutExtension == .unavailable
    }
}
