import Foundation
import PippaCore

// Tidy speed: how long stage 3 of `proposeSort` (classifying unclear documents) takes per file.
//
//   PIPPA_LIVE=1 swift run PippaLive tidy-speed <corpus> [model]
//
// Works on copies of the corpus (never the corpus itself). Steps:
// 1. Which files stay unclear without a model (`Plan.later`).
// 2. Product path with the system model (Apple Foundation Models), per file from the diagnostics log.
// 3. Local model (llama-server, model file from PIPPA_MODELS_DIR, never downloaded): the old request
//    (6,000 characters, unlimited schema) against the new one (TidyClassifier excerpt, short schema), same server.
enum TidySpeedLive {
    static let oldSchema = #"""
    {"type":"object","properties":{"kategorie":{"type":"string","enum":["rechnung","vertrag","brief","sonstiges"]},
    "absender":{"type":"string"},"art":{"type":"string"},"datum":{"type":"string"},"betreff":{"type":"string"},
    "entwurf":{"type":"boolean"},"entwurf_beleg":{"type":"string"},"beleg":{"type":"string"}},"required":["kategorie","absender","art","datum","betreff","entwurf","entwurf_beleg","beleg"],"additionalProperties":false}
    """#

    static func run(base: URL, arguments: [String]) async throws {
        guard let corpusPath = arguments.first else { print("tidy-speed <corpus> [model]"); exit(2) }
        let corpus = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let fm = FileManager.default
        let work = base.appendingPathComponent("tidy-speed-\(UUID().uuidString.prefix(8))", isDirectory: true)
        func copy(_ name: String) throws -> URL {
            let target = work.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.copyItem(at: corpus, to: target)
            return target
        }

        // 1. Unclear without any model.
        setenv("PIPPA_NO_SYSTEM_MODEL", "1", 1)
        let plain = LocalEngine(baseDirectory: work.appendingPathComponent("support-a"), modelEnabled: false)
        let firstCopy = try copy("a")
        let plan = try await plain.proposeSort(items: nil, scope: firstCopy, limit: PreSort.firstRunLimit) { _ in }
        let unclear = plan.later.map(\.lastPathComponent).sorted()
        print("Unclear without a model: \(unclear.count): \(unclear.joined(separator: ", "))")

        // 2. System model, product path.
        unsetenv("PIPPA_NO_SYSTEM_MODEL")
        print("System model available: \(TidyClassifier.appleAvailable)")
        if TidyClassifier.appleAvailable {
            let log = DiagnosticsLog.shared
            log.flush()
            let mark = (try? String(contentsOf: log.fileURL, encoding: .utf8))?.count ?? 0
            let engine = LocalEngine(baseDirectory: work.appendingPathComponent("support-b"), modelEnabled: false)
            let t = Date()
            let p = try await engine.proposeSort(items: nil, scope: try copy("b"), limit: PreSort.firstRunLimit) { _ in }
            let total = Date().timeIntervalSince(t)
            log.flush()
            let lines = ((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").dropFirst(mark)
                .split(separator: "\n").filter { $0.contains(" einordnen ") }
            let ms = lines.compactMap { line in line.split(separator: " ").first { $0.hasPrefix("ms=") }.flatMap { Double($0.dropFirst(3)) } }
            print("System model: \(lines.count) calls, \(lines.filter { $0.contains("ergebnis=ja") }.count) answered; per file " + stats(ms.map { $0 / 1000 })
                  + String(format: "; whole preview %.1f s; later %lld, moved %lld", total, p.later.count, p.ops.filter { $0.kind != .mkdir }.count))
        }

        // 3. Local model: old against new request, same server.
        let key = arguments.dropFirst().first ?? "gemma-4-12b"
        let memory = ProcessInfo.processInfo.physicalMemory
        guard let choice = ModelSelector.named(key, physicalMemory: memory),
              let file = ModelDownloader(directory: LocalEngine.modelsDirectory(base: base)).primaryFile(choice.model),
              fm.fileExists(atPath: file.path), let binary = LlamaServer.binaryURL() else {
            print("Local model \(key): no model file or llama-server, skipped (nothing is downloaded)."); return
        }
        let server = LlamaServer(choice: choice, modelPath: file, binary: binary, logDirectory: work)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }
        let system = Prompts.system(.classify)
        var before: [Double] = [], after: [Double] = []
        var tokensBefore = 0, tokensAfter = 0
        // Warm-up: the fixed system prompt lands in the cache once, as in the app after the first file.
        if let name = unclear.first {
            let doc = TextReader.read(firstCopy.appendingPathComponent(name))
            _ = try? await ask(server, system: system, user: TidyClassifier.prompt(name: name, doc: doc), schema: Prompts.classifySchema)
        }
        for name in unclear {
            let doc = TextReader.read(firstCopy.appendingPathComponent(name))
            let old = "Dateiname: \(name)\n\n\(doc.capped())"
            let new = TidyClassifier.prompt(name: name, doc: doc)
            tokensBefore += Prompts.estimateTokens(old); tokensAfter += Prompts.estimateTokens(new)
            let a = try await ask(server, system: system, user: old, schema: oldSchema)
            let b = try await ask(server, system: system, user: new, schema: Prompts.classifySchema)
            before.append(a); after.append(b)
            print(String(format: "  %@: before %.1f s (~%lld tokens), after %.1f s (~%lld tokens)", name, a, Prompts.estimateTokens(old), b, Prompts.estimateTokens(new)))
        }
        print("Local model \(key): before " + stats(before) + ", after " + stats(after)
              + "; user tokens before ~\(tokensBefore), after ~\(tokensAfter), system ~\(Prompts.estimateTokens(system))")
        await server.stop()
    }

    static func ask(_ server: LlamaServer, system: String, user: String, schema: String) async throws -> Double {
        let lease = try await server.acquireAgentLease()
        let t = Date()
        _ = try? await LocalModelJSON.request(lease, system: system, user: user, schema: schema, name: "einordnung")
        let seconds = Date().timeIntervalSince(t)
        await server.releaseAgentLease(lease)
        return seconds
    }

    static func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "–" }
        let sorted = values.sorted()
        return String(format: "p50 %.2f s, max %.2f s, mean %.2f s (n=%lld)", sorted[sorted.count / 2], sorted.last!, values.reduce(0, +) / Double(values.count), values.count)
    }
}
