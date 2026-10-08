import Foundation
import PippaCore

// Developer tool, not part of the checks: all flows against a real llama-server with a real model.
// Runs only with PIPPA_LIVE=1. Needs PIPPA_LLAMA_SERVER (path to llama-server) and a support folder
// outside the repo (PIPPA_LIVE_BASE), models in PIPPA_MODELS_DIR (otherwise <base>/models).
//
//   PIPPA_LIVE=1 swift run PippaLive download [model]   Load a model through the app's own downloader (resumable, SHA256)
//   PIPPA_LIVE=1 swift run PippaLive run <corpus> [model]   all flows, timings and checks
//   PIPPA_LIVE=1 swift run PippaLive decide   decision spike (no llama-server needed, see DecisionSpike.swift)
//   PIPPA_LIVE=1 swift run PippaLive tidy-speed <corpus> [model]   seconds per unclear document while tidying (TidySpeedLive.swift)
//
// Model: catalog key; if omitted, the choice by memory.

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
guard env["PIPPA_LIVE"] == "1" else {
    print("PippaLive runs only with PIPPA_LIVE=1 (needs llama-server and a loaded model).")
    exit(0)
}
let args = Array(CommandLine.arguments.dropFirst())
let base = URL(fileURLWithPath: env["PIPPA_LIVE_BASE"] ?? (NSTemporaryDirectory() + "pippa-live"), isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

func engine(model: String?) async throws -> LocalEngine {
    // Without a model: the one the table picks by memory (the app has no model choice, only measurements).
    LocalEngine(baseDirectory: base, integrations: DemoIntegrations(), measuredModel: model)
}

switch args.first {
case "p0-answers":
    // ANS-1 now runs only on the Pi path: scripts/pi-rpc-spike.sh r7 ans1 (PiRPCR2Spike, R7.swift).
    print("p0-answers no longer exists; ANS-1 on the Pi path: scripts/pi-rpc-spike.sh r7 ans1"); exit(2)
case "p0-suggestions":
    try await P0SuggestionLive.run(useAppleFM: args.contains("--apple-fm"))
case "tidy-speed":
    try await TidySpeedLive.run(base: base, arguments: Array(args.dropFirst()))
case "ctxsug-suggestions":
    try await CtxSugLive.run(arguments: Array(args.dropFirst()))
case "download":
    let e = try await engine(model: args.dropFirst().first)
    let started = Date()
    let watcher = Task {
        while !Task.isCancelled {
            if case .downloading(let p, let r) = await e.modelStatus {
                print(String(format: "  %.1f %%  Remaining %@", p * 100, r.map { String(format: "%.0f s", $0) } ?? "?"))
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
    try await e.prepareModel()
    watcher.cancel()
    print(String(format: "done in %.1f s, status: %@", Date().timeIntervalSince(started), "\(await e.modelStatus)"))
case "corpus":
    guard args.count >= 2 else { print("corpus <folder>"); exit(2) }
    try Corpus.build(at: URL(fileURLWithPath: args[1], isDirectory: true))
    print("Corpus created: \(args[1])")
case "read":
    for path in args.dropFirst() {
        let t = Date()
        let doc = TextReader.read(URL(fileURLWithPath: path))
        print("== \(path) (\(String(format: "%.2f", Date().timeIntervalSince(t))) s, OCR \(doc.usedOCR), \(doc.problem))")
        for (i, p) in doc.pages.enumerated() { print("-- Page \(i + 1)\n\(p)") }
    }
case "cold":
    // Measure cold start: start the server until /health = 200, three times.
    let memory = ProcessInfo.processInfo.physicalMemory
    let c = try args.dropFirst().first.flatMap { ModelSelector.named($0, physicalMemory: memory) } ?? ModelSelector.choose(physicalMemory: memory).get()
    guard let file = env["PIPPA_MODEL_FILE"].map({ URL(fileURLWithPath: $0) }) ?? ModelDownloader(directory: LocalEngine.modelsDirectory(base: base)).primaryFile(c.model),
          let bin = LlamaServer.binaryURL() else { print("no model / no llama-server"); exit(1) }
    for i in 1...3 {
        let s = LlamaServer(choice: c, modelPath: file, binary: bin, logDirectory: base)
        let t = Date()
        try await s.ensureRunning()
        print("Start \(i): \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        await s.stop()
    }
case "coldprogress":
    // Which memory figure grows while llama-server loads (ColdStart.swift): resident set vs. physical footprint
    // against the model size, every 250 ms until /health = 200. Model file read only: PIPPA_MODEL_FILE.
    let memory = ProcessInfo.processInfo.physicalMemory
    let c = try args.dropFirst().first.flatMap { ModelSelector.named($0, physicalMemory: memory) } ?? ModelSelector.choose(physicalMemory: memory).get()
    guard let file = env["PIPPA_MODEL_FILE"].map({ URL(fileURLWithPath: $0) }), let bin = LlamaServer.binaryURL() else {
        print("PIPPA_MODEL_FILE and PIPPA_LLAMA_SERVER needed"); exit(1)
    }
    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print("Model \(file.lastPathComponent): \(size >> 20) MiB, ctx \(c.ctx)")
    for run in 1...2 {
        let s = LlamaServer(choice: c, modelPath: file, binary: bin, logDirectory: base)
        let t = Date()
        let start = Task { try await s.ensureRunning() }
        var tracker = ColdStart.Tracker()
        while true {
            let sample = await s.coldStartSample()
            if let pid = await s.processID, let m = ColdStart.memory(pid: pid) {
                if let sample { tracker.update(sample) }
                print(String(format: "run %d  %5.2f s  rss %6d MiB (%3.0f %%)  footprint %6d MiB (%3.0f %%)  health %@  shown %@", run,
                             Date().timeIntervalSince(t), m.resident >> 20, Double(m.resident) / Double(max(size, 1)) * 100,
                             m.footprint >> 20, Double(m.footprint) / Double(max(size, 1)) * 100,
                             sample.map { "\($0.health)" } ?? "ready", "\(tracker.stage.map { "\($0)" } ?? "-")"))
            }
            if sample == nil, await s.state == .ready { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await start.value
        print(String(format: "run %d: ready after %.2f s", run, Date().timeIntervalSince(t)))
        await s.stop()
    }
case "dltest":
    // Downloader against a local stand-in (PIPPA_HF_ENDPOINT): dltest <file> <size> <sha256>
    guard args.count >= 4, let size = Int64(args[2]) else { print("dltest <file> <size> <sha256>"); exit(2) }
    let json = #"{"key":"test","label":"Test","repo":"test/tiny","quant":"F32","memGiB":1,"ctx":4096,"rank":0,"pinned":{"revision":"r1","files":[{"path":"\#(args[1])","size":\#(size),"sha256":"\#(args[3])"}]}}"#
    let model = try JSONDecoder().decode(CatalogModel.self, from: Data(json.utf8))
    let d = ModelDownloader(directory: LocalEngine.modelsDirectory(base: base))
    let t = Date()
    do {
        try await d.download(model) { p, r in print(String(format: "  %.0f %%  Remaining %@", p * 100, r.map { String(format: "%.0f s", $0) } ?? "?")) }
        print(String(format: "done in %.1f s, installed: %@", Date().timeIntervalSince(t), d.isInstalled(model) ? "yes" : "no"))
    } catch { print("Error: \(error)") }
case "ocrwarm":
    // Measure the first text recognition with and without warm-up (freshly built program = cold Vision cache).
    guard args.count >= 2 else { print("ocrwarm <image> [without]"); exit(2) }
    let e = LocalEngine(baseDirectory: base, modelEnabled: false, integrations: DemoIntegrations())
    if args.count >= 3 && args[2] == "parallel" {
        // Drop during warm-up: 2 s after start.
        await e.warmUp()
        try await Task.sleep(for: .seconds(2))
        let t = Date()
        _ = TextReader.read(URL(fileURLWithPath: args[1]))
        print(String(format: "Text recognition during warmUp: %.2f s", Date().timeIntervalSince(t)))
        exit(0)
    }
    if args.count < 3 {
        let t = Date()
        await e.warmUp(); await e.waitForWarmUp()
        print(String(format: "warmUp: %.2f s", Date().timeIntervalSince(t)))
    }
    for i in 1...2 {
        let t = Date()
        let doc = TextReader.read(URL(fileURLWithPath: args[1]))
        print(String(format: "Text recognition %d: %.2f s, %d characters", i, Date().timeIntervalSince(t), doc.fullText.count))
    }
case "ocr-bench":
    // FLOW-5: classic vs document text recognition on synthetic scans (OCRBench.swift).
    OCRBench.run(Array(args.dropFirst()))
case "decide":
    // Measurement spike for the decision model: Apple FM, NaturalLanguage, BM25 (see DecisionSpike.swift).
    try await DecisionSpike.run()
case "run":
    guard args.count >= 2 else { print("run <corpus> [model]"); exit(2) }
    let corpus = URL(fileURLWithPath: args[1], isDirectory: true)
    let model = args.count > 2 ? args[2] : nil
    let e = try await engine(model: model)
    try await LiveRun(engine: e, corpus: corpus, base: base, model: model).all()
default:
    print("download [model] | corpus <folder> | run <corpus> [model]")
}
