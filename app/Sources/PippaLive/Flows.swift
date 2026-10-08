import Foundation
import PippaCore

/// All flows against the real model, with timings, memory and checks against `Corpus`.
struct LiveRun {
    let engine: LocalEngine
    let corpus: URL
    let base: URL
    /// Measured catalog model (`nil`: the one the table picks by memory).
    var model: String? = nil

    final class Table: @unchecked Sendable {
        var rows: [(flow: String, result: String, ok: Bool?, seconds: Double)] = []
        func add(_ flow: String, _ result: String, _ ok: Bool?, _ seconds: Double) {
            rows.append((flow, result, ok, seconds))
            let mark = ok.map { $0 ? "OK " : "XX " } ?? "-- "
            print(mark + flow.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: " %6.1f s  ", seconds) + result)
        }
    }

    /// Largest RSS of all llama-server processes (ps), every 0.5 s.
    final class RAMWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var peakKB = 0
        private var task: Task<Void, Never>?
        var peakGB: Double { lock.withLock { Double(peakKB) / 1_048_576 } }
        func start() {
            task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    let kb = RAMWatch.serverRSS()
                    if let self { self.lock.withLock { self.peakKB = max(self.peakKB, kb) } }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        func stop() { task?.cancel() }
        static func serverRSS() -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axo", "rss=,comm="]
            let out = Pipe(); p.standardOutput = out
            guard (try? p.run()) != nil else { return 0 }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.split(separator: "\n").filter { $0.hasSuffix("llama-server") }
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }.reduce(0, +)
        }
    }

    func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let t = Date()
        let r = try await body()
        return (r, Date().timeIntervalSince(t))
    }

    func all() async throws {
        let t = Table()
        let ram = RAMWatch(); ram.start()
        defer { ram.stop() }
        try Corpus.build(at: corpus)
        print("Corpus: \(corpus.path)")
        print("Model: \(await engine.modelStatus)")

        // Cold start: own server, load only until /health = 200, then a small request.
        let memory = ProcessInfo.processInfo.physicalMemory
        let choice = try model.flatMap { ModelSelector.named($0, physicalMemory: memory) }
            ?? ModelSelector.choose(physicalMemory: memory).get()
        if let file = modelFile(choice), let bin = LlamaServer.binaryURL() {
            let s = LlamaServer(choice: choice, modelPath: file, binary: bin, logDirectory: base)
            let (_, cold) = try await timed { try await s.ensureRunning() }
            t.add("Cold start (load)", "\(choice.model.key) · \(file.lastPathComponent) · ctx \(choice.ctx)", true, cold)
            do {
                let (warm, w) = try await timed {
                    try await s.completeJSON(system: "Antworte nur mit JSON.", user: "Sag hallo.", schemaName: "x",
                                             schema: #"{"type":"object","properties":{"gruss":{"type":"string"}},"required":["gruss"],"additionalProperties":false}"#)
                }
                t.add("First request", String(String(decoding: warm, as: UTF8.self).prefix(80)), nil, w)
            } catch { t.add("First request", "Error: \(error)", false, 0) }
            await s.stop()
        } else {
            t.add("Cold start", "no model or no llama-server", false, 0)
        }

        // Like the app shortly after launch: warm up text recognition (after a new build the first scan otherwise takes about 30 s).
        let (_, sw) = await timed { await engine.warmUp(); await engine.waitForWarmUp() }
        t.add("OCR warm-up", "expensive once per program version", nil, sw)

        // 1. Folder overview (no model)
        let (ov, s1) = try await timed { try await engine.overview(of: .files([corpus])) }
        let cats = ov.categories.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
        // Subtitle and category names follow the system language (tables "Core" and "Analysis").
        let filesOK = ov.subtitle == L("%lld files", table: "Core", 14)
        let catsOK = cats.contains("\(DocCategory.photo.label) 4") && cats.contains("\(DocCategory.other.label) 10")
        t.add("Folder overview", "\(ov.subtitle): \(cats)", filesOK && catsOK && s1 < 15, s1)

        // 2. Letter overview: deadline with quote
        let (ovl, s2) = try await timed { try await engine.overview(of: .files([corpus.appendingPathComponent(Corpus.letter)])) }
        let pay = ovl.deadlines.first { $0.kind == .payment }
        t.add("Letter overview", "\(ovl.title) · \(ovl.deadlines.map(\.title)) · “\(pay?.quote.prefix(70) ?? "")”",
              pay?.date == DayDate(year: 2026, month: 10, day: 31) && pay?.quote.contains("31.10.2026") == true, s2)

        // 3. Sorting as in the app: first without a model (instant), then read documents, model only for unclear cases
        let first = FirstPreview()
        let (plan, s3) = try await timed {
            try await engine.proposeSort(items: nil, scope: corpus, limit: PreSort.firstRunLimit) { first.note($0) }
        }
        t.add("  first preview", "\(first.moves) files placed, \(first.pending) still open", nil, first.seconds)
        let moves = plan.ops.filter { $0.kind != .mkdir }
        let files = moves.count + plan.skipped.count
        print("   Plan:")
        for op in plan.ops {
            let rel = op.target.path.replacingOccurrences(of: corpus.path + "/", with: "")
            print("     \(op.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(op.source?.lastPathComponent ?? "")  →  \(rel)  [\(op.certainty.rawValue)] \(op.reason)")
        }
        for s in plan.skipped { print("     skip   \(s.url.lastPathComponent): \(s.why)") }
        // Pi determines the evidenced subject; quality is checked on assignment and evidenced key facts,
        // not on an earlier name variant dictated by a Swift keyword.
        let invoiceNameOK = moves.contains { $0.source?.lastPathComponent == "Rechnung_2026_08.pdf"
            && $0.target.path.precomposedStringWithCanonicalMapping.contains("Rechnungen/2026/2026-08 Stadtwerke Lindau Rechnung") }
        let contractNameOK = moves.contains { $0.source?.lastPathComponent == Corpus.lease
            && $0.target.path.precomposedStringWithCanonicalMapping.contains("Verträge/Mietvertrag") && $0.target.lastPathComponent.contains("2021") }
        let noFakeDraft = moves.allSatisfy { !$0.target.lastPathComponent.contains("(Entwurf)") }
        t.add("Sort (preview)", "\(moves.count) steps, \(plan.skipped.count) skipped; invoice \(invoiceNameOK), lease \(contractNameOK), no invented draft \(noFakeDraft)",
              files == 14 && invoiceNameOK && contractNameOK && noFakeDraft, s3)
        t.add("  per file", "", nil, s3 / Double(max(files, 1)))

        // 4. Apply and undo
        let before = snapshot(corpus)
        let (receipt, s4) = try await timed { try await engine.apply(plan, excluding: []) }
        let after = snapshot(corpus)
        t.add("Apply", "\(receipt.summary) · \(receipt.detail)", after != before, s4)
        let (_, s5) = try await timed { try await engine.undo(receipt) }
        let restored = snapshot(corpus)
        t.add("Undo", restored == before ? "everything back in its old place" : "Difference: \(restored.symmetricDifference(before).sorted())",
              restored == before, s5)

        // Invoices and deadlines are Pi conversations with skills now (rechnung-auslesen, fristen-erkennen):
        // measure them on the Pi path (scripts/pi-rpc-spike.sh), not here.

        await engine.shutdown()
        try? await Task.sleep(for: .seconds(1))
        t.add("Peak RAM llama-server", String(format: "%.2f GB", ram.peakGB), nil, 0)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        t.add("Peak RAM PippaLive", String(format: "%.2f GB", Double(usage.ru_maxrss) / 1_073_741_824), nil, 0)
        let ok = t.rows.filter { $0.ok == true }.count, bad = t.rows.filter { $0.ok == false }.count
        print("\n\(ok) correct, \(bad) wrong")
    }

    func modelFile(_ c: ModelChoice) -> URL? {
        if let p = ProcessInfo.processInfo.environment["PIPPA_MODEL_FILE"] { return URL(fileURLWithPath: p) }
        let d = ModelDownloader(directory: LocalEngine.modelsDirectory(base: base))
        return d.isInstalled(c.model) ? d.primaryFile(c.model) : nil
    }

    /// Relative paths of all files (for apply/undo).
    func snapshot(_ dir: URL) -> Set<String> {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        var out = Set<String>()
        while let u = e?.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.insert(u.path.replacingOccurrences(of: dir.path + "/", with: ""))
        }
        return out
    }
}

/// First preview while sorting: when it arrived and how much of it already had a place.
final class FirstPreview: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private(set) var seconds = 0.0, moves = 0, pending = 0
    private var seen = false
    func note(_ plan: Plan) {
        lock.withLock {
            guard !seen else { return }
            seen = true
            seconds = Date().timeIntervalSince(start)
            moves = plan.ops.filter { $0.kind != .mkdir }.count
            pending = plan.pending.count
        }
    }
}
