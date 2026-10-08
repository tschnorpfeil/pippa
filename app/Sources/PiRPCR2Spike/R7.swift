import Foundation
import PiRPC
@_spi(Evaluation) import PippaCore

// R7: acceptance on the standard path. As in the app: the llama-server comes from
// `PiLocalServer.plan` (fixed port, key, flags, idle timeout, slot folder in the fake HOME's support folder),
// Pi restarts per conversation (`PiRPCChat.ready`), shown items via `PiShownContext`, review via `PiAnswerReview`.
// Synthetic files only (ctxsug corpus, ANS-1 fixtures, an invented Downloads folder in the fake HOME).
//
//   scripts/pi-rpc-spike.sh r7 latency|cold|slot|ans1|sort [Argument]
//
// latency [rounds]  warm, per case "short texts" off and on, order alternating per round
// cold              one "app start": server off, slot cache off, first question (case b) up to the first word
// slot [runs]       idle unload with and without slot save/restore, alternating
// ans1 off|on       ANS-1 fixtures over the Pi path, JSONL under .build/quality/r7/
// sort              "Räum meine Downloads auf" on an invented folder, questions, receipts, undo

struct R7Answer {
    var text = ""
    var reviewed = ""
    var findings: [String] = []
    /// Which files Pi read for the answer ("name:complete|partial", PiReadLedger).
    var piRead: [String] = []
    /// Comparison: findings and text of the review against Pippa's own read state (the earlier behavior).
    var ownSnapshotFindings: [String] = []
    var ownSnapshotReviewed = ""
    var tools: [String] = []
    var toolErrors = 0
    var asked: [String] = []
    /// ms from the start (lease + Pi start + request) to the first word; components listed individually.
    var firstWord = -1
    var total = 0
    var leaseMS = 0
    var piStartMS = 0
    var promptFirstWord = -1
    var tokensIn: Any = "?"
    var cacheRead: Any = "?"
    var tokensOut: Any = "?"
    var receipt: [PiActionRecord] = []
}

final class R7 {
    let env = ProcessInfo.processInfo.environment
    let launcher: PippaPiLaunch.Launcher
    let paths: PippaPiLaunch.Paths
    let workDir: URL
    let guardDir: URL
    let piEnv: [String: String]
    let roots: PiInstallRoots
    let agent: URL
    let model: String
    let mcp: PippaMCPServer
    var server: LlamaServer?

    init() async throws {
        guard let home = env["PIPPA_PI_HOME"], let payload = PiPayload.locate(environment: env), let guardPath = env["PIPPA_PI_GUARD"],
              let work = env["PIPPA_SPIKE_WORK"], let agentPath = env["PI_CODING_AGENT_DIR"] else {
            print("First run: scripts/pi-rpc-spike.sh setup"); exit(2)
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        roots = PiInstallRoots(home: homeURL, payload: payload, searchPath: [homeURL.appendingPathComponent(".local/bin")])
        agent = URL(fileURLWithPath: agentPath, isDirectory: true)
        model = env["PIPPA_PI_MODEL"] ?? "k2-horizon-7b"
        guard let spec = PiInstaller(roots: roots).launchSpec(modelID: model) else { print("Pi missing in the fake HOME (setup)"); exit(2) }
        launcher = PippaPiLaunch.Launcher(executable: spec.executable, launcherArguments: spec.launcherArguments, piArguments: spec.piArguments, environment: spec.environment)
        guardDir = URL(fileURLWithPath: guardPath).deletingLastPathComponent()
        workDir = URL(fileURLWithPath: work, isDirectory: true)
        paths = PippaPiLaunch.Paths(guardExtension: URL(fileURLWithPath: guardPath), toolsExtension: guardDir.appendingPathComponent("pippa-tools.ts"),
                                    sessionDirectory: URL(fileURLWithPath: env["PIPPA_SPIKE_SESSIONS"] ?? work + "-sessions", isDirectory: true))
        piEnv = ["PI_CODING_AGENT_DIR": agentPath, "PIPPA_UNDO_DIR": env["PIPPA_UNDO_DIR"] ?? work + "-undo", "PIPPA_TRASH_DIR": env["PIPPA_TRASH_DIR"] ?? work + "-trash"]
        var host = PippaMCPHost.demo()
        host.askForAccess = false
        mcp = try PippaMCPServer(host: host)
        try await mcp.start()
    }

    /// The server as in the app (`PiRPCChat.localModelServer`). `slots: false` = without slot folder (state before slot caching).
    func makeServer(slots: Bool, idleSeconds: Double? = nil) throws -> LlamaServer {
        var e = env
        if let idleSeconds { e["PIPPA_LLAMA_IDLE_SECONDS"] = String(idleSeconds) }
        if !slots { e["PIPPA_LLAMA_SLOT_CACHE"] = "0" }
        let plan = try PiLocalServer.plan(roots: roots, agentDirectory: agent, modelID: model, legacySupport: roots.support, environment: e)
        let logs = URL(fileURLWithPath: env["PIPPA_R7_LOGS"] ?? workDir.path + "-r7-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return PiLocalServer.server(plan, logDirectory: logs)
    }

    func newClient(uiHandler: @escaping PiUIHandler) async throws -> PiRPCClient {
        let configuration = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: workDir, paths: paths, sessionID: nil, language: "de",
                                                        environment: piEnv, mcp: (.init(url: mcp.url, token: mcp.token), guardDir.appendingPathComponent("pippa-mcp.ts")))
        let client = PiRPCClient(configuration: configuration)
        await client.setUIHandler(uiHandler)
        try await client.start()
        return client
    }

    static func approveAll(_ log: Box<[String]>) -> PiUIHandler {
        { request in
            log.set { $0.append(oneLine(request.title + " | " + request.message)) }
            return request.method == "select" ? .value(request.options.first ?? "") : .confirmed(true)
        }
    }

    /// An answer as in the app: lease (starts the server on demand, restores the slot), Pi (new or continued),
    /// message, stream, review. `client == nil`: new conversation (new Pi process, like `PiRPCChat.ready`).
    func ask(_ prompt: String, question: String, files: [URL], client given: PiRPCClient? = nil, keepClient: Bool = false,
             uiHandler: PiUIHandler? = nil, quiet: Bool = false) async throws -> (R7Answer, PiRPCClient?) {
        guard let server else { throw R7Failure("no server") }
        var a = R7Answer()
        let asked = Box<[String]>([])
        let t0 = clock.now
        let lease = try await server.acquireAgentLease()
        defer { Task { await server.releaseAgentLease(lease) } }
        a.leaseMS = ms(clock.now - t0)
        let t1 = clock.now
        let client: PiRPCClient
        if let given { client = given } else { client = try await newClient(uiHandler: uiHandler ?? Self.approveAll(asked)) }
        a.piStartMS = ms(clock.now - t1)
        let turn = PippaMCPTurn(web: nil, onWork: nil)
        PippaMCPTurns.shared.begin(turn)
        defer { PippaMCPTurns.shared.end(turn) }
        let t2 = clock.now
        var receipt = PiTurnReceipt()
        var readArguments: [String: String] = [:]
        for try await event in try await client.prompt(prompt) {
            receipt.observe(event)
            switch event {
            case .textDelta(let d):
                if a.firstWord < 0 { a.firstWord = ms(clock.now - t0); a.promptFirstWord = ms(clock.now - t2) }
                a.text += d
            case .toolStarted(let id, let name, let arguments):
                if name == "read" { readArguments[id] = arguments }
                a.tools.append(name)
                if !quiet { print("    [\(ms(clock.now - t0)) ms] TOOL \(name) \(arguments.prefix(220))") }
            case .toolEnded(let id, let name, let isError, let result):
                if isError { a.toolErrors += 1 }
                if name == "read", !isError, let arguments = readArguments.removeValue(forKey: id) {
                    await turn.notePiRead(arguments: arguments, result: result)
                }
                if !quiet { print("    [\(ms(clock.now - t0)) ms] DONE \(name)\(isError ? " ERROR" : "") \(oneLine(String(result.prefix(200))))") }
            default: break
            }
        }
        a.total = ms(clock.now - t0)
        a.receipt = receipt.records
        let stats = (try? await client.command(["type": "get_session_stats"])).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let tokens = stats?["tokens"] as? [String: Any]
        a.tokensIn = tokens?["input"] ?? "?"; a.cacheRead = tokens?["cacheRead"] ?? "?"; a.tokensOut = tokens?["output"] ?? "?"
        a.asked = asked.get
        a.text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
        a.reviewed = a.text
        if !files.isEmpty {
            let snapshots = (try? await LocalEngine.snapshots(for: ChatContext(files: files))) ?? []
            // Review against what Pi read, as the app does (R7_OWN_SNAPSHOT=1: old behavior, for comparison only).
            let reads: PiReadLedger? = env["R7_OWN_SNAPSHOT"] == "1" ? nil : await turn.ledger
            a.piRead = reads?.paths.map { "\(URL(fileURLWithPath: $0).lastPathComponent):\(reads?.readCompletely($0) == true ? "complete" : "partial")" } ?? []
            // Comparison: what the review (Pippa's own read state) would have made of the same answer.
            let own = PiAnswerReview.review(answer: a.text, question: question, snapshots: snapshots, fileCount: files.count, webPages: [])
            a.ownSnapshotFindings = own?.findings.map { String(describing: $0) } ?? []
            a.ownSnapshotReviewed = own?.text ?? a.text
            if let r = PiAnswerReview.review(answer: a.text, question: question, snapshots: snapshots, fileCount: files.count, webPages: [],
                                             reads: reads, files: files) {
                a.reviewed = r.text
                a.findings = r.findings.map { String(describing: $0) }
            }
        }
        if keepClient { return (a, client) }
        if given == nil { await client.shutdown() }
        return (a, nil)
    }

    static func load() -> String {
        var info = utsname(); uname(&info)
        let pipe = Pipe(); let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/uptime"); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.components(separatedBy: "load averages:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    static func rssMB(_ pid: Int32) -> Int {
        let pipe = Pipe(); let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", String(pid)]; p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return (Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }

    /// Waits until the load (1-min average) is below `limit` (default: wait if > 8).
    static func waitQuiet(limit: Double = 8) async {
        while true {
            let one = Double(load().split(separator: " ").first.map(String.init)?.replacingOccurrences(of: ",", with: ".") ?? "") ?? 0
            if one <= limit { return }
            print("  (load \(load()) > \(limit), waiting 30 s)")
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func line(_ label: String, _ a: R7Answer) {
        print("  < \(oneLine(a.text).prefix(400))")
        if !a.findings.isEmpty { print("  Review: \(a.findings.joined(separator: "; "))") }
        print("  = \(label): first word \(a.firstWord) ms (lease \(a.leaseMS), Pi start \(a.piStartMS), request→word \(a.promptFirstWord)), total \(a.total) ms, tools \(a.tools), tokens in \(a.tokensIn) + cache \(a.cacheRead), out \(a.tokensOut), load \(Self.load())")
    }

    // MARK: Latency

    struct LatencyCase { let id: String; let file: URL; let question: String }

    func latencyCases() -> [LatencyCase] {
        [LatencyCase(id: "b", file: corpus.appendingPathComponent("brief-finanzamt.pdf"), question: "Wie viel muss ich zahlen und bis wann?"),
         LatencyCase(id: "k", file: corpus.appendingPathComponent("brief-krankenkasse.pdf"), question: "Was will die Krankenkasse von mir?"),
         LatencyCase(id: "n", file: corpus.appendingPathComponent("nachricht-nachbar.txt"), question: "Was will der Nachbar?")]
    }

    func prompt(_ c: LatencyCase, inline: Bool) -> String {
        PiShownContext.prompt(.init(question: c.question, files: [c.file], newFiles: [c.file], language: "de", inlineShortText: inline))
    }

    func runLatency(rounds: Int) async throws {
        server = try makeServer(slots: true)
        await Self.waitQuiet()
        print("Warm-up (server start + \"Sag nur: Hallo.\"), load \(Self.load())")
        let (warm, _) = try await ask("Sag nur: Hallo.", question: "", files: [], quiet: true)
        line("Warm-up", warm)
        for c in latencyCases() { print("  Case \(c.id): short enough to send inline: \(PiShownContext.shortInline(c.file).map { "yes, \($0.count) characters" } ?? "no")") }
        for round in 1...rounds {
            for (index, c) in latencyCases().enumerated() {
                let order = (round + index) % 2 == 0 ? [false, true] : [true, false]
                for inline in order {
                    await Self.waitQuiet()
                    print("\n## Round \(round) · case \(c.id) · short texts \(inline ? "ON" : "OFF")")
                    let (a, _) = try await ask(prompt(c, inline: inline), question: c.question, files: [c.file], quiet: true)
                    line("R7LAT \(c.id) \(inline ? "on" : "off") r\(round)", a)
                }
            }
        }
        await server?.stop()
    }

    func runCold() async throws {
        // Like an app start without a saved slot: new server, new Pi, first question with a shown item.
        server = try makeServer(slots: false)
        await Self.waitQuiet()
        let c = latencyCases()[0]
        print("Cold: case \(c.id), load \(Self.load())")
        let inline = env["R7_INLINE"] == "1"
        let (a, _) = try await ask(prompt(c, inline: inline), question: c.question, files: [c.file], quiet: true)
        line("R7COLD \(c.id) \(inline ? "on" : "off")", a)
        print("  Server start until /health: \(await server?.lastStartSeconds ?? -1) s")
        await server?.stop()
    }

    // MARK: Slot across unloading

    func waitUnloaded(_ s: LlamaServer, limit: Double = 240) async -> Double {
        let t = clock.now
        while ms(clock.now - t) < Int(limit * 1000) {
            if await s.processID == nil { return Double(ms(clock.now - t)) / 1000 }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return -1
    }

    func runSlot(runs: Int, idle: Double) async throws {
        let b = latencyCases()[0]
        for run in 1...runs {
            let withSlot = run % 2 == 1
            if let old = server { await old.stop() }
            PiLocalServer.discardSavedSlots(support: roots.support)
            let s = try makeServer(slots: withSlot, idleSeconds: idle)
            server = s
            await Self.waitQuiet()
            print("\n## Run \(run) · slot save/restore \(withSlot ? "ON" : "OFF") · idle \(Int(idle)) s")
            // Conversation S: letter, then a warm follow-up (reference), then unload, then the follow-up after the restart.
            let (q1, client) = try await ask(prompt(b, inline: false), question: b.question, files: [b.file], keepClient: true, quiet: true)
            line("Q1", q1)
            guard let client else { continue }
            let (q2, _) = try await ask("Wofür ist der Betrag genau?", question: "", files: [], client: client, keepClient: true, quiet: true)
            line("R7SLOT warm-follow-up \(withSlot ? "on" : "off") l\(run)", q2)
            if let pid = await s.processID { print("  llama-server RSS \(Self.rssMB(pid)) MB") }
            print("  unloaded after \(await waitUnloaded(s)) s; saved: \(String(describing: await s.lastSlotSave))")
            await Self.waitQuiet()
            let (q3, _) = try await ask("Und was passiert, wenn ich zu spät zahle?", question: "", files: [], client: client, keepClient: true, quiet: true)
            line("R7SLOT after-unload-same-conversation \(withSlot ? "on" : "off") l\(run)", q3)
            print("  Start until /health \(await s.lastStartSeconds ?? -1) s; restored: \(String(describing: await s.lastSlotRestore))")
            await client.shutdown()
            // New conversation after unloading (only system prompt + tools are shared).
            print("  unloaded after \(await waitUnloaded(s)) s; saved: \(String(describing: await s.lastSlotSave))")
            await Self.waitQuiet()
            let k = latencyCases()[2]
            let (q4, _) = try await ask(prompt(k, inline: false), question: k.question, files: [k.file], quiet: true)
            line("R7SLOT after-unload-new-conversation \(withSlot ? "on" : "off") l\(run)", q4)
            print("  Start until /health \(await s.lastStartSeconds ?? -1) s; restored: \(String(describing: await s.lastSlotRestore))")
        }
        if let s = server, let file = await s.slotFile {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("\nSlot file \(file.lastPathComponent): \(size >> 20) MB")
        }
        await server?.stop()
        PiLocalServer.discardSavedSlots(support: roots.support)
    }

    // MARK: ANS-1

    struct Fixture: Codable { let id: String; let purpose: String; let turns: [Turn]; let expectations: [String] }
    struct Turn: Codable { let topic: String; let question: String; let sources: [Source] }
    struct Source: Codable { let path: String; let text: String?; let readability: String }

    func runANS1(inline: Bool, only: String?) async throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: repo.appendingPathComponent("app/Fixtures/p0-answers.json")))
        let out = repo.appendingPathComponent(".build/quality/r7", isDirectory: true)
        let runID = String(UUID().uuidString.prefix(8))
        let inputs = out.appendingPathComponent("ans1-inputs-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let results = out.appendingPathComponent("ans1-\(inline ? "inline-on" : "inline-off")-\(runID).jsonl")
        FileManager.default.createFile(atPath: results.path, contents: nil)
        let handle = try FileHandle(forWritingTo: results)
        defer { try? handle.close() }
        server = try makeServer(slots: true)
        let (warm, _) = try await ask("Sag nur: Hallo.", question: "", files: [], quiet: true)
        line("Warm-up", warm)
        print("ANS-1 via Pi, short texts \(inline ? "on" : "off"): \(results.path)")
        for fixture in fixtures where only == nil || fixture.id == only {
            for (index, turn) in fixture.turns.enumerated() {
                var urls: [URL] = []
                for source in turn.sources {
                    let url = inputs.appendingPathComponent("\(fixture.id)/\(turn.topic)/\(source.path)")
                    if let text = source.text {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(text.utf8).write(to: url)
                    }
                    urls.append(url)
                }
                await Self.waitQuiet()
                print("\n## \(fixture.id) \(index + 1): \(turn.question)")
                let text = PiShownContext.prompt(.init(question: turn.question, files: urls, newFiles: urls, language: "de", inlineShortText: inline))
                var a = R7Answer(), failure = ""
                do { (a, _) = try await ask(text, question: turn.question, files: urls) } catch { failure = String(describing: error) }
                print("  < \(oneLine(a.text))")
                if a.reviewed != a.text { print("  reviewed < \(oneLine(a.reviewed))") }
                print("  Pi read: \(a.piRead.joined(separator: ", ")) · findings: \(a.findings) · own-snapshot review: \(a.ownSnapshotFindings)")
                line("R7ANS \(fixture.id)-\(index + 1) \(inline ? "on" : "off")", a)
                let row: [String: Any] = ["caseID": fixture.id, "turn": index + 1, "question": turn.question, "expectations": fixture.expectations,
                                          "modelAnswer": a.text, "answer": a.reviewed, "sourceReview": a.findings, "piRead": a.piRead, "ownSnapshotReview": a.ownSnapshotFindings,
                                          "ownSnapshotAnswer": a.ownSnapshotReviewed, "tools": a.tools,
                                          "toolErrors": a.toolErrors, "firstWordMS": a.firstWord, "totalMS": a.total, "error": failure,
                                          "inline": inline, "prompt": text, "load": Self.load()]
                try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
            }
        }
        await server?.stop()
    }

    // MARK: Tidy up (stand-in for the sort plan)

    func runSort() async throws {
        let home = roots.home
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: downloads.path) {
            // Only our own invented folder in the fake HOME under .build: move aside, never delete.
            try fm.moveItem(at: downloads, to: home.appendingPathComponent("Downloads-alt-\(UUID().uuidString.prefix(6))"))
        }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let pick: [(String, String)] = [
            ("rechnung-1.pdf", "Rechnung_2026-09_Stadtwerke.pdf"), ("rechnung-2.pdf", "invoice-10233.pdf"), ("rechnung-heizung.pdf", "Heizung Wartung Rechnung.pdf"),
            ("brief-finanzamt.pdf", "Steuerbescheid 2025.pdf"), ("mietvertrag-12-seiten.pdf", "Mietvertrag_Musterstrasse.pdf"),
            ("urlaub-strand.jpg", "IMG_4711.jpg"), ("garten-1.jpg", "IMG_4712.jpg"), ("bildschirmfoto-fehlermeldung.png", "Bildschirmfoto 2026-10-01 um 09.12.33.png"),
            ("haushaltsbuch-2026.csv", "haushaltsbuch-2026.csv"), ("kuendigung-entwurf.docx", "Kuendigung_Fitnessstudio.docx"),
            ("garten-video.mov", "garten.mov"), ("nachricht-nachbar.txt", "notiz.txt"),
        ]
        for (from, to) in pick { try fm.copyItem(at: corpus.appendingPathComponent(from), to: downloads.appendingPathComponent(to)) }
        try Data("PK\u{3}\u{4}".utf8).write(to: downloads.appendingPathComponent("Fotos_Export(1).zip"))
        try Data(repeating: 0, count: 2048).write(to: downloads.appendingPathComponent("Pippa-Installer.dmg"))
        try fm.copyItem(at: corpus.appendingPathComponent("rechnung-1.pdf"), to: downloads.appendingPathComponent("Rechnung_2026-09_Stadtwerke (1).pdf"))
        let before = tree(downloads)
        print("Before (\(before.count)):\n" + before.map { "  " + $0 }.joined(separator: "\n"))

        server = try makeServer(slots: true)
        let questions = Box<[String]>([])
        let homePath = home.standardizedFileURL.path
        // Guard questions: yes only if every path in the question lies in the fake HOME (the run must touch nothing else).
        let handler: PiUIHandler = { request in
            let text = request.title + " | " + request.message
            questions.set { $0.append(oneLine(text)) }
            let paths = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "„" || $0 == "“" || $0 == "\"" }).filter { $0.hasPrefix("/") }
            let inside = paths.allSatisfy { $0.hasPrefix(homePath) }
            return request.method == "select" ? .value(inside ? (request.options.first ?? "") : (request.options.last ?? "")) : .confirmed(inside)
        }
        var turns: [R7Answer] = []
        var (a, client) = try await ask("Räum meine Downloads auf.", question: "", files: [], keepClient: true, uiHandler: handler)
        turns.append(a); line("R7SORT 1", a)
        // If Pi asks in the text ("Soll ich …?"), the person answers yes once (counts as a question).
        var textQuestions = 0
        // If Pi asks for the location, the person answers like a human ("the normal Downloads folder"), otherwise yes.
        for _ in 0..<3 where a.receipt.filter({ $0.outcome == .done }).isEmpty {
            guard let c = client else { break }
            let lower = a.text.lowercased()
            let reply: String
            if lower.contains("pfad") || lower.contains("nicht finden") || lower.contains("wo ") { reply = "Der ganz normale Downloads-Ordner in meinem Benutzerordner." }
            else if a.text.contains("?") { reply = "Ja, mach das bitte so." }
            else { break }
            textQuestions += 1
            print("  > Person: \(reply)")
            (a, client) = try await ask(reply, question: "", files: [], client: c, keepClient: true, uiHandler: handler)
            turns.append(a); line("R7SORT \(turns.count)", a)
        }
        await client?.shutdown()
        let after = tree(downloads)
        print("\nAfter (\(after.count)):\n" + after.map { "  " + $0 }.joined(separator: "\n"))
        let records = turns.flatMap(\.receipt)
        print("\nReceipt (\(records.count) lines):")
        for r in records { print("  \(r.action) \(r.outcome.rawValue) \(r.name ?? "") → \(r.toName ?? "")\(r.restorable ? " · undoable" : "")\(r.asked ? " · asked" : "")") }
        print("Questions: guard \(questions.get.count) \(questions.get), in text \(textQuestions)")
        // Undo: every line from bottom to top, like clicks on "Undo".
        let undoRoot = URL(fileURLWithPath: piEnv["PIPPA_UNDO_DIR"]!, isDirectory: true)
        var undone = 0, failed: [String] = []
        for r in records.reversed() where r.outcome == .done && r.restorable {
            guard let entry = r.undoEntry else { continue }
            let result = PiUndo.restore(URL(fileURLWithPath: entry, isDirectory: true), root: undoRoot)
            if result.status == .restored { undone += 1 } else { failed.append("\(r.name ?? "?"): \(result.status.rawValue) \(result.failures.map(\.reason))") }
        }
        let restored = tree(downloads)
        print("\nAfter undo (\(restored.count)), \(undone) restored, errors \(failed):\n" + restored.map { "  " + $0 }.joined(separator: "\n"))
        print("R7SORT same as before: \(Set(restored) == Set(before))")
        await server?.stop()
    }

    func tree(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.path + "/"
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.standardizedFileURL.path.replacingOccurrences(of: base, with: "") }.filter { !$0.hasSuffix(".DS_Store") }.sorted()
    }
}

struct R7Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

func runR7(_ all: [String]) async throws {
    let args = Array(all.prefix { $0 != "-AppleLanguages" })
    let r7 = try await R7()
    defer { r7.mcp.stop() }
    let sub = args.first ?? "latency"
    let arg = args.dropFirst().first
    print("R7 \(sub) · model \(r7.model) · load \(R7.load())")
    switch sub {
    case "latency": try await r7.runLatency(rounds: Int(arg ?? "3") ?? 3)
    case "cold": try await r7.runCold()
    case "slot": try await r7.runSlot(runs: Int(arg ?? "6") ?? 6, idle: Double(ProcessInfo.processInfo.environment["R7_IDLE"] ?? "25") ?? 25)
    case "ans1": try await r7.runANS1(inline: arg == "on", only: args.dropFirst(2).first)
    case "sort": try await r7.runSort()
    default: print("r7 latency|cold|slot|ans1|sort")
    }
}
