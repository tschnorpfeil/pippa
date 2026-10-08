import Foundation
import PippaCore

// The llama-server for `pippa-local` belongs to the app (fixed port, key file, model from the installer folder),
// unloading when idle, plain mkdir with undo, read receipts, and Pippa's sentence before the first system prompt
// when reading. Stand-ins only: a small Python program plays llama-server (no model), `DemoIntegrations`/`DemoSheetReader`
// play Calendar, Mail and Excel.
// Runs with PIPPA_SETUP_CHECKS=1 and in the full run (via runPiPivotChecks).

/// Stand-in for llama-server: `--help` lists flags, otherwise HTTP on 127.0.0.1:<--port> with `/health` and `/slots`, only
/// with `Authorization: Bearer $LLAMA_API_KEY`. Arguments of each start go to $FAKE_LLAMA_ARGS; if $FAKE_LLAMA_BUSY exists,
/// `/slots` reports a running request. Takes half a second to "load the model".
private let fakeLlama = """
#!/usr/bin/python3
import http.server, json, os, sys, time
args = sys.argv[1:]
if "--help" in args:
    print("--host --port --alias --jinja --ctx-size --parallel --no-webui --reasoning --cache-type-k --cache-type-v --temp")
    sys.exit(0)
with open(os.environ["FAKE_LLAMA_ARGS"], "a") as f: f.write(json.dumps(args) + "\\n")
port = int(args[args.index("--port") + 1])
key = os.environ.get("LLAMA_API_KEY", "")
time.sleep(0.5)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + key:
            self.send_response(401); self.end_headers(); return
        busy = os.path.exists(os.environ.get("FAKE_LLAMA_BUSY", "/nonexistent"))
        body = b'{"status":"ok"}' if self.path == "/health" else json.dumps([{"id": 0, "is_processing": busy}]).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"""

/// Puts a catalog model in `folder` as "verified": files as empty sparse files of full size (no disk space), plus `.ok`.
private func fakeInstalled(_ model: CatalogModel, in folder: URL) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in model.pinned?.files ?? [] {
        let url = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.size)); try handle.close()
        try file.sha256.write(to: url.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

func runWave2dChecks() async {
    let base = dir("wave2d")
    let binary = base.appendingPathComponent("fake-llama-server")
    write(fakeLlama, binary)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let argsLog = base.appendingPathComponent("llama-args.jsonl")
    setenv("FAKE_LLAMA_ARGS", argsLog.path, 1)
    let busyFlag = base.appendingPathComponent("busy")
    setenv("FAKE_LLAMA_BUSY", busyFlag.path, 1)
    let catalog = ModelCatalog.bundled()
    guard let model9b = catalog.model("qwen3.5-9b-q4") else { check("Catalog knows qwen3.5-9b-q4") { false }; return }

    /// Fake HOME with installer state: payload (metadata.json only), support folder with port and key, models.json.
    func installed(_ name: String, contextWindow: Int = 16384, modelsJSONPort: Int? = nil) throws -> (roots: PiInstallRoots, port: Int) {
        let home = dir(name)
        let release = home.appendingPathComponent("payload/release", isDirectory: true)
        try fm.createDirectory(at: release, withIntermediateDirectories: true)
        write(#"{"version":"1.0.4"}"#, release.appendingPathComponent("metadata.json"))
        let roots = PiInstallRoots(home: home, payload: try PiPayload(release: release, node: URL(fileURLWithPath: "/usr/bin/false")), searchPath: [])
        let port = PiInstaller.stablePort(support: roots.support)
        let entry = PiInstaller.providerEntry(models: [PiProviderModel(id: "qwen3.5-9b-q4", name: "Qwen", contextWindow: contextWindow)],
                                              port: modelsJSONPort ?? port, keyFile: roots.llamaKeyFile)
        try fm.createDirectory(at: roots.agentDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["providers": [PiInstaller.providerKey: entry]]).write(to: roots.modelsJSON)
        return (roots, port)
    }

    // MARK: 1. Plan for the `pippa-local` server

    check("pippa-local: port from settings.json (= models.json), key from the 0600 file, model from the installer folder, context from models.json, idle 10 min") {
        let (roots, port) = try installed("w2d-plan", contextWindow: 8192)
        var state = PiInstallState()
        state.modelsFolder = roots.sharedModels.path
        try state.save(to: roots.stateFile)
        try fakeInstalled(model9b, in: roots.sharedModels)
        let plan = try PiLocalServer.plan(roots: roots, modelID: "qwen3.5-9b-q4", legacySupport: base.appendingPathComponent("leer"),
                                          physicalMemory: 16 << 30, binary: binary, environment: [:])
        let key = try String(contentsOf: roots.llamaKeyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = ((try? fm.attributesOfItem(atPath: roots.llamaKeyFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let args = LlamaServer.arguments(choice: plan.choice, model: plan.modelFile, port: plan.port, supported: nil, alias: plan.modelID)
        let joined = args.joined(separator: " ")
        return plan.port == port && plan.key == key && mode == 0o600 && plan.source == "installer"
            && plan.modelFile.deletingLastPathComponent().standardizedFileURL == roots.sharedModels.standardizedFileURL
            && plan.choice.ctx == 8192 && plan.idleSeconds == 600 && plan.modelID == "qwen3.5-9b-q4"
            && plan.slotDirectory == roots.support.appendingPathComponent("llama-slots", isDirectory: true)
            && joined.contains("--host 127.0.0.1 --port \(port)") && joined.contains("--alias qwen3.5-9b-q4") && joined.contains("--ctx-size 8192")
            && !joined.contains(key)   // key only in the environment, never in the arguments (ps)
    }

    check("pippa-local: developer file before installer folder, else current model folder; if everything is missing or the port does not match → clear error") {
        let (roots, _) = try installed("w2d-fallback")
        let legacy = base.appendingPathComponent("w2d-legacy-support", isDirectory: true)
        func plan(_ env: [String: String], legacy: URL) throws -> PiLocalServer.Plan {
            try PiLocalServer.plan(roots: roots, modelID: "qwen3.5-9b-q4", legacySupport: legacy, physicalMemory: 16 << 30, binary: binary, environment: env)
        }
        var missing = false
        do { _ = try plan([:], legacy: legacy) } catch PiLocalServer.Failure.modelMissing("qwen3.5-9b-q4") { missing = true }
        try fakeInstalled(model9b, in: legacy.appendingPathComponent("models", isDirectory: true))
        let old = try plan([:], legacy: legacy)
        let devFile = base.appendingPathComponent("dev.gguf"); write("x", devFile)
        let dev = try plan(["PIPPA_MODEL_FILE": devFile.path, "PIPPA_LLAMA_IDLE_SECONDS": "30", "PIPPA_LLAMA_SLOT_CACHE": "0"], legacy: legacy)
        var settings = PippaSettings.load(from: roots.support); settings.llamaIdleMinutes = 3; try settings.save(to: roots.support)
        let minutes = try plan([:], legacy: legacy)
        let (other, port) = try installed("w2d-mismatch", modelsJSONPort: 1)
        var mismatch = false
        do { _ = try PiLocalServer.plan(roots: other, modelID: "qwen3.5-9b-q4", legacySupport: legacy, binary: binary, environment: [:]) }
        catch PiLocalServer.Failure.portMismatch(modelsJSON: 1, settings: port) { mismatch = true }
        var unknown = false
        do { _ = try PiLocalServer.plan(roots: roots, modelID: "gibt-es-nicht", legacySupport: legacy, binary: binary, environment: [:]) }
        catch PiLocalServer.Failure.unknownModel { unknown = true }
        var noBinary = false
        do { _ = try PiLocalServer.plan(roots: roots, modelID: "qwen3.5-9b-q4", legacySupport: legacy, binary: nil, environment: [:]) }
        catch PiLocalServer.Failure.binaryMissing { noBinary = true }
        return missing && old.source == "pippa" && dev.source == "dev" && dev.modelFile == devFile && dev.idleSeconds == 30 && dev.slotDirectory == nil
            && minutes.idleSeconds == 180 && mismatch && unknown && noBinary
    }

    check("LocalEngine server unchanged: without alias the same arguments as before (no --alias)") {
        guard let choice = ModelSelector.named("qwen3.5-9b-q4", physicalMemory: 16 << 30) else { return false }
        let args = LlamaServer.arguments(choice: choice, model: URL(fileURLWithPath: "/m.gguf"), port: 1234, supported: nil)
        return !args.contains("--alias") && Array(args.prefix(6)) == ["-m", "/m.gguf", "--host", "127.0.0.1", "--port", "1234"]
    }

    // MARK: 2. Fixed port, idle, restart

    await checkAsync("pippa-local server: fixed port and key, ready only after /health; idle unloads, next request reloads (same port); occupied port → error") {
        try? fm.removeItem(at: argsLog)
        let support = dir("w2d-server")
        let port = PiInstaller.stablePort(support: support)
        let key = try PiInstaller.stableKey(support: support)
        guard let choice = ModelSelector.named("qwen3.5-9b-q4", physicalMemory: 16 << 30) else { return false }
        let server = LlamaServer(choice: choice, modelPath: URL(fileURLWithPath: "/m.gguf"), binary: binary, logDirectory: support,
                                 fixedPort: port, fixedKey: key, alias: "qwen3.5-9b-q4", idleAfter: 1.0, logName: "llama-server-pi.log")
        let coldBefore = await server.isWarm
        let lease = try await server.acquireAgentLease()
        let firstPID = await server.processID
        let started = await server.lastStartSeconds ?? 0
        // A second server on the same port does not start alongside.
        let rival = LlamaServer(choice: choice, modelPath: URL(fileURLWithPath: "/m.gguf"), binary: binary, logDirectory: support,
                                fixedPort: port, fixedKey: key, idleAfter: 1.0, logName: "rival.log")
        var rivalFailed = false
        do { _ = try await rival.acquireAgentLease() } catch { rivalFailed = true }
        try await Task.sleep(for: .seconds(1.5))
        let heldDuringLease = await server.processID != nil      // a running answer holds the server
        await server.releaseAgentLease(lease)
        var unloaded = false
        for _ in 0..<40 where !unloaded { try await Task.sleep(for: .milliseconds(100)); unloaded = await server.processID == nil }
        let warmAfterUnload = await server.isWarm
        let again = try await server.acquireAgentLease()
        let secondPID = await server.processID
        await server.releaseAgentLease(again)
        await server.stop()
        let starts = (try? String(contentsOf: argsLog, encoding: .utf8))?.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        } ?? []
        let sameArgs = starts.count == 2 && starts[0] == starts[1] && starts[0].contains("--alias")
            && starts[0].joined(separator: " ").contains("--host 127.0.0.1 --port \(port)")
        print("   Start to /health (stand-in, 0.5 s loading): \(String(format: "%.2f", started)) s")
        return !coldBefore && firstPID != nil && started >= 0.4 && rivalFailed && heldDuringLease && unloaded && !warmAfterUnload
            && secondPID != nil && secondPID != firstPID && again.endpoint.port == port && again.apiKey == key && sameArgs
    }

    await checkAsync("pippa-local server: if it is currently computing for someone else (terminal Pi, /slots), it stays loaded") {
        let support = dir("w2d-busy")
        let port = PiInstaller.stablePort(support: support)
        let key = try PiInstaller.stableKey(support: support)
        guard let choice = ModelSelector.named("qwen3.5-9b-q4", physicalMemory: 16 << 30) else { return false }
        let server = LlamaServer(choice: choice, modelPath: URL(fileURLWithPath: "/m.gguf"), binary: binary, logDirectory: support,
                                 fixedPort: port, fixedKey: key, idleAfter: 0.8, logName: "busy.log")
        write("", busyFlag)
        await server.releaseAgentLease(try await server.acquireAgentLease())
        try await Task.sleep(for: .seconds(2.0))
        let stayed = await server.processID != nil
        try? fm.removeItem(at: busyFlag)
        var unloaded = false
        for _ in 0..<40 where !unloaded { try await Task.sleep(for: .milliseconds(100)); unloaded = await server.processID == nil }
        await server.stop()
        return stayed && unloaded
    }

    // MARK: 2b. `pi` in the terminal starts the server itself (lock file, start file, sharing, installer)

    await runTerminalAutostartChecks(binary: binary, argsLog: argsLog)

    // MARK: 3. mkdir with undo (Swift like restore.mjs)

    /// A mkdir entry as written by the guard (`mkdir -p Belege/2026 Leer`).
    func mkdirFixture(_ name: String) throws -> (root: URL, work: URL, entry: URL) {
        let base = dir(name)
        let work = base.appendingPathComponent("work", isDirectory: true), root = base.appendingPathComponent("undo", isDirectory: true)
        let entry = root.appendingPathComponent("1-mkdir", isDirectory: true)
        for folder in ["Belege/2026", "Leer", "Voll"] { try fm.createDirectory(at: work.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        write("", work.appendingPathComponent("Belege/.DS_Store"))
        write("Brief\n", work.appendingPathComponent("Voll/Brief.txt"))
        let p = { (s: String) in work.appendingPathComponent(s).path }
        let manifest: [String: Any] = ["version": 1, "tool": "bash", "command": "mkdir -p Belege/2026 Leer Voll", "restorable": true,
                                       "folders": [p("Belege"), p("Leer"), p("Voll"), p("Weg")],
                                       "created": [p("Belege"), p("Belege/2026"), p("Leer"), p("Voll"), p("Weg")]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: entry.appendingPathComponent("manifest.json"))
        return (root, work, entry)
    }

    check("Undo mkdir (native): new empty folders to the trash, folder with content stays (partial result), lines in words") {
        let f = try mkdirFixture("w2d-mkdir")
        let trash = f.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
        let result = PiUndo.restore(f.entry, root: f.root) { url in
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)); return nil
        }
        let left = try fm.contentsOfDirectory(atPath: f.work.path).sorted()
        let item = ActionReceipt.Item(action: "createFolder", outcome: "done", name: "Belege", undoEntry: f.entry.path, restorable: true)
        let existed = ActionReceipt.Item(action: "createFolder", outcome: "done", name: "Belege", restorable: false)
        let declined = ActionReceipt.Item(action: "createFolder", outcome: "declined", name: "Neu")
        let done = ActionReceipt.Item(action: PiUndo.receipt(for: item, result).action, outcome: "done", name: "Belege")
        return result.status == .partial && result.failures.map(\.reason) == ["notEmpty"] && left == ["Voll"]
            && (try? fm.contentsOfDirectory(atPath: trash.path).sorted()) == ["Belege", "Leer"]
            && item.line(language: "de") == "Ordner angelegt: Belege · rückgängig machbar" && item.canUndo
            && existed.line(language: "de") == "Ordner war schon da: Belege" && !existed.canUndo
            && declined.line(language: "de") == "Ordner nicht angelegt: Neu (du hast abgelehnt)"
            && done.line(language: "de") == "Rückgängig: Belege in den Papierkorb gelegt"
            && PiUndo.receipt(for: item, result).line(language: "de") == "Nicht rückgängig gemacht: Belege (im Ordner liegt inzwischen etwas)"
    }

    let node = [ProcessInfo.processInfo.environment["PIPPA_PI_PAYLOAD"].map { $0 + "/bin/node" }, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        .compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    if let node {
        check("Undo mkdir: Swift and restore.mjs leave the same folders behind") {
            let a = try mkdirFixture("w2d-mkdir-swift"), b = try mkdirFixture("w2d-mkdir-node")
            let trashB = b.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
            _ = PiUndo.restore(a.entry, root: a.root) { url in
                let trash = a.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)); return nil
            }
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("runtime/pippa-guard/restore.mjs").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script, b.entry.path]
            process.environment = ["PATH": "/usr/bin:/bin", "PIPPA_TRASH_DIR": trashB.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            func tree(_ url: URL) -> [String] {
                let prefix = url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                return ((fm.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
                    .map { $0.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }.sorted()
            }
            return process.terminationStatus == 1 && tree(a.work) == tree(b.work) && tree(a.work) == ["Voll", "Voll/Brief.txt"]
                && !PiUndo.isRestored(a.entry) && !PiUndo.isRestored(b.entry)
        }
    }

    // MARK: 4./5. Read receipts and Pippa's sentence before the system prompt (stand-in readers only)

    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let now = berlin.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
    func host(granted: Bool, ask: Bool = true, notes: Box<PippaMCPReadNote>, asked: Box<String>? = nil, answer: Bool = true) -> (PippaMCPTools, DemoIntegrations, DemoSheetReader) {
        let demo = DemoIntegrations(granted: granted)
        let sheets = DemoSheetReader(granted: granted)
        var explain: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)?
        if let box = asked {
            explain = { @Sendable (subject: PippaMCPAccessSubject, sentence: String) async -> Bool in
                // At the time of the sentence the Mac has not asked yet.
                var before = IntegrationAccess.granted
                if case .integration(let i) = subject { before = await demo.access(i) } else { before = await sheets.sheetAccess() }
                box.append("\(subject.appName)|\(before == .notDetermined)|\(sentence)")
                return answer
            }
        }
        let host = PippaMCPHost(integrations: demo, sheets: sheets, hostData: DemoHostData(integrations: demo, now: now), askForAccess: ask,
                                now: { now }, calendar: berlin, explainAccess: explain, onRead: { notes.append($0) })
        return (PippaMCPTools(host: host), demo, sheets)
    }
    func call(_ tools: PippaMCPTools, _ name: String, _ arguments: [String: Any] = [:]) async -> Bool {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let reply = await tools.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (reply?["result"] as? [String: Any])?["isError"] as? Bool == false
    }

    await checkAsync("Read receipt: one neutral line per reader from Pippa's own result (period, subject, hits), without permission 'Nicht gelesen'") {
        let notes = Box<PippaMCPReadNote>()
        let (tools, demo, _) = host(granted: true, notes: notes)
        let ok = [await call(tools, "calendar_read", ["period": "today"]), await call(tools, "calendar_read", ["period": "next_days", "days": 3]),
                  await call(tools, "reminders_read"), await call(tools, "reminders_read", ["days": 1]),
                  await call(tools, "mail_selected"), await call(tools, "mail_search", ["query": "Berger"]), await call(tools, "excel_selection")]
        demo.set(.calendar, .denied)
        let denied = await call(tools, "calendar_read", ["period": "today"])
        let bad = await call(tools, "reminders_read", ["days": 99])
        let lines = notes.all.map(\.line)
        let expected = [
            L("Read Calendar: %@", table: "MCP", L("today", table: "MCP")),
            L("Read Calendar: %@", table: "MCP", L("next %lld days", table: "MCP", 3)),
            L("Read Reminders: open ones", table: "MCP"), L("Read Reminders: due today", table: "MCP"),
            L("Read Mail: “%@”", table: "MCP", "Nebenkostenabrechnung 2025"),
            L("Searched Mail for “%@”: %lld found", table: "MCP", "Berger", 1),
            L("Read Excel: active sheet", table: "MCP"),
            L("Not read: %@", table: "MCP", Integration.calendar.appName), L("Not read: %@", table: "MCP", Integration.reminders.appName),
        ]
        if lines != expected { print("   ", lines) }
        let item = ActionReceipt.Item(action: "read", outcome: "done", name: lines[0], restorable: false)
        let de = ActionReceipt.Item(action: "read", outcome: "done", name: nil).line(language: "de")
        return ok.allSatisfy { $0 } && !denied && !bad && lines == expected && notes.all.map(\.read) == [true, true, true, true, true, true, true, false, false]
            && item.line == lines[0] && !item.canUndo && de == "Etwas gelesen"
    }

    await checkAsync("Before the first system prompt when reading: Pippa's sentence first (Mac has not asked yet), then the Mac asks; 'Später' → nothing asked, nothing read") {
        let notes = Box<PippaMCPReadNote>(), asked = Box<String>()
        let (tools, demo, sheets) = host(granted: false, notes: notes, asked: asked)
        let calendar = await call(tools, "calendar_read", ["period": "today"])
        let again = await call(tools, "calendar_read", ["period": "tomorrow"])     // already allowed: no second sentence
        let mail = await call(tools, "mail_selected")
        let excel = await call(tools, "excel_selection")
        let laterAsked = Box<String>()
        let (later, laterDemo, laterSheets) = host(granted: false, notes: Box<PippaMCPReadNote>(), asked: laterAsked, answer: false)
        let laterReminders = await call(later, "reminders_read")
        let laterExcel = await call(later, "excel_selection")
        let (silent, silentDemo, _) = host(granted: false, ask: false, notes: Box<PippaMCPReadNote>(), asked: laterAsked)
        let silentCalendar = await call(silent, "calendar_read", ["period": "today"])
        let entries = asked.all
        let granted = (await demo.access(.calendar), await sheets.sheetAccess())
        let notAsked = (await laterDemo.access(.reminders), await laterSheets.sheetAccess(), await silentDemo.access(.calendar))
        return calendar && again && mail && excel
            && entries == ["\(Integration.calendar.appName)|true|\(CalendarConversation.accessBenefit)",
                           "\(Integration.mail.appName)|true|\(PippaMCPTools.accessExplanation(.integration(.mail)))",
                           "\(ExcelScript.appName)|true|\(PippaMCPTools.accessExplanation(.excel))"]
            && granted == (.granted, .granted)
            && !laterReminders && !laterExcel && !silentCalendar && laterAsked.all.count == 2
            && notAsked == (.notDetermined, .notDetermined, .notDetermined)
    }
}
