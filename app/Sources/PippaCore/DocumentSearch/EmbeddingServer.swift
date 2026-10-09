import Foundation

/// Turns texts into vectors for the document search (`DocumentSearch`). Replaceable in checks.
public protocol TextEmbedding: Sendable {
    /// Model and version of the vectors; vectors of different revisions are never mixed.
    var revision: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// EmbeddingGemma 2 (text part, BF16 GGUF from ggml-org) in Pippa's own llama-server with `--embedding`, started only when a
/// search needs it and stopped after `idleSeconds`. 127.0.0.1 only, random port and key, like LocalEngine's server.
/// Optional: without the model file the search is full text only (DocumentSearch), nothing is computed elsewhere.
///
/// Model card (huggingface.co/google/embeddinggemma-2): prefixes `task: search result | query: …` and
/// `title: … | text: …`, 768 dimensions, L2-normalized; never float16 (BF16 or F32), hence the BF16 file.
public actor EmbeddingServer: TextEmbedding {
    /// Pinned download (ModelDownloader checks size and SHA256; `.ok` marker as for the chat models).
    public static let model = CatalogModel(
        key: "embeddinggemma-2", label: "EmbeddingGemma 2", description: "Text search model", repo: "ggml-org/embeddinggemma-2-GGUF",
        quant: "BF16", approxBytes: 557_950_176, memGiB: 1, ctx: 2048, moe: nil, rank: 0, thinking: nil, pending: nil,
        pinned: .init(revision: "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
                      files: [.init(path: "embeddinggemma-2-BF16.gguf", size: 557_950_176,
                                    sha256: "68bae29d62fb8c7d23e98d21fd4662753ddd636e6b62b8a70dfe059a9844f216")]),
        sampling: nil, extra: nil)
    public static let dimension = 768
    public nonisolated let revision = "embeddinggemma-2@bfcd298/BF16/768"

    public static func modelsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        LocalEngine.modelsDirectory(base: Pippa.supportDirectory, environment: environment)
    }

    /// Installed and verified (size + `.ok` marker)? Development: PIPPA_EMBED_MODEL names a file directly.
    public static func modelFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["PIPPA_EMBED_MODEL"], !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let downloader = ModelDownloader(directory: modelsDirectory(environment: environment))
        guard downloader.isInstalled(model), let file = model.pinned?.files.first else { return nil }
        return downloader.localURL(file)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: EmbeddingServer?

    /// The app's one server, or `nil` if the model or llama-server is missing (then: full text only).
    public static func shared() -> EmbeddingServer? {
        guard let file = modelFile(), let binary = LlamaServer.binaryURL() else { return nil }
        return lock.withLock {
            if let current, current.modelFile == file { return current }
            let server = EmbeddingServer(modelFile: file, binary: binary, logDirectory: DiagnosticsLog.defaultDirectory)
            current = server
            return server
        }
    }

    public nonisolated let modelFile: URL
    let binary: URL
    let logDirectory: URL
    let idleSeconds: Double
    private var process: Process?
    private var port = 0
    private var key = ""
    private var idleTask: Task<Void, Never>?
    private var pendingStart: Task<Void, Error>?
    /// Held open while Pippa runs; when Pippa ends (also by a crash) the pipe closes and the watcher ends the server.
    private var watchdogPipe: Pipe?

    public init(modelFile: URL, binary: URL, logDirectory: URL, idleSeconds: Double = 300) {
        self.modelFile = modelFile; self.binary = binary; self.logDirectory = logDirectory; self.idleSeconds = idleSeconds
    }

    public enum Failure: Error, Equatable { case notStarted, badAnswer }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await ensureRunning()
        idleTask?.cancel()
        defer { scheduleIdle() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": texts])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]], rows.count == texts.count
        else { throw Failure.badAnswer }
        return try rows.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.map { row in
            let values = (row["embedding"] as? [Double] ?? []).map(Float.init)
            guard values.count == Self.dimension, values.allSatisfy(\.isFinite) else { throw Failure.badAnswer }
            return Self.normalized(values)
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public func stop() {
        idleTask?.cancel(); idleTask = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? watchdogPipe?.fileHandleForWriting.close()
        watchdogPipe = nil
    }

    private func ensureRunning() async throws {
        if process?.isRunning == true { return }
        if let pendingStart { return try await pendingStart.value }
        let start = Task { try await self.start() }
        pendingStart = start
        defer { pendingStart = nil }
        try await start.value
    }

    private func start() async throws {
        port = LlamaServer.freePort()
        key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let p = Process()
        p.executableURL = binary
        // Sections are at most ~1,200 characters plus prefix: 2,048 tokens per input suffice and keep memory small.
        p.arguments = ["-m", modelFile.path, "--embedding", "--host", "127.0.0.1", "--port", String(port), "-ngl", "999",
                       "-c", "2048", "-b", "2048", "-ub", "2048", "--parallel", "1", "--no-webui"]
        p.environment = LlamaServer.environment(apiKey: key)
        let log = logDirectory.appendingPathComponent("embedding-server.log")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) { p.standardOutput = handle; p.standardError = handle }
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.notStarted }
        process = p
        // Same watcher as LlamaServer: the server never outlives Pippa.
        let pipe = Pipe(), watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "read _; kill -TERM \(p.processIdentifier) 2>/dev/null; sleep 3; kill -KILL \(p.processIdentifier) 2>/dev/null; exit 0"]
        watcher.standardInput = pipe
        watcher.standardOutput = FileHandle.nullDevice; watcher.standardError = FileHandle.nullDevice
        if (try? watcher.run()) != nil { watchdogPipe = pipe }
        let started = Date()
        while Date().timeIntervalSince(started) < 120 {
            guard p.isRunning else { process = nil; throw Failure.notStarted }
            var health = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!, timeoutInterval: 2)
            health.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: health), (response as? HTTPURLResponse)?.statusCode == 200 {
                DiagnosticsLog.shared.event("embedding-bereit", ["dauer-s": String(format: "%.1f", Date().timeIntervalSince(started))])
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        stop()
        throw Failure.notStarted
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }
}
