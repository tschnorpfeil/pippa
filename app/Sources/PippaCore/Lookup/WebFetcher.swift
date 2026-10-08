import Foundation

/// Fetches pages for an already checked request (QueryGuard). Replaceable for checks.
public protocol WebFetching: Sendable {
    func lookup(_ query: String, language: String) async throws -> [WebSource]
    /// Exactly one page that WebAccessGate has already allowed and the person has approved. `nil`: nothing readable.
    func page(_ url: URL, language: String) async throws -> WebSource?
}

extension WebFetching {
    public func page(_ url: URL, language: String) async throws -> WebSource? { throw WebFetchError.unavailable }
}

/// Why a fetch returned nothing. For code and log only; the UI says one calm sentence.
public enum WebFetchError: Error, Sendable, Equatable {
    /// Node or the fetch part are missing in this package.
    case unavailable
    case busy
    case invalidRequest
    case timedOut
    case stopped
    /// Process ended or answer unusable.
    case failed
}

/// The own fetch process (runtime/pippa-web/src/fetcher.mjs, pi-web-access; in the bundle Contents/Resources/pippa-web).
/// Only the app starts it, for `web_search`/`read_web_page` from Pippa's MCP server (PippaMCPTurn) after approval in
/// WebAccessGate and for "Check online" (LookupHost); Pi and the model have no network of their own.
/// Protocol: JSON lines, see the header of fetcher.mjs. One request at a time, 30 s limit, ended after 120 s idle.
/// Reading happens on the pipe's read queue, the result arrives as a finished value at the actor; nothing here ever waits
/// blocking on the cooperative pool (no waitUntilExit).
/// Latency: search plus up to three pages, limited to 25 s in the process.
public actor WebFetcher: WebFetching {
    public static let timeout: Duration = .seconds(30)
    public static let idleLimit: Duration = .seconds(120)
    /// This much of the end of the error output stays in memory, only for debugging, never on screen.
    static let diagnosticsLimit = 4 * 1024
    static let maxPages = 3
    static let textLimit = 40_000

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var generation = 0
    private var pending: (id: String, continuation: CheckedContinuation<FetcherReply, Error>)?
    private var timeoutTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var stderrTail: FetcherBuffer?

    public init() {}

    /// Node and fetch part: PIPPA_NODE_BINARY / PIPPA_WEB_RUNTIME or in the app package (Helpers/node, Resources/pippa-web).
    static func locations() -> (node: URL, entry: URL)? {
        let env = ProcessInfo.processInfo.environment
        let bundle = Bundle.main.bundleURL
        let node = URL(fileURLWithPath: env["PIPPA_NODE_BINARY"] ?? bundle.appendingPathComponent("Contents/Helpers/node").path)
        let root = URL(fileURLWithPath: env["PIPPA_WEB_RUNTIME"] ?? bundle.appendingPathComponent("Contents/Resources/pippa-web").path)
        let entry = root.appendingPathComponent("src/fetcher.mjs")
        let generated = root.appendingPathComponent("src/generated/extract.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: entry.path),
              FileManager.default.fileExists(atPath: generated.path) else { return nil }
        return (node, entry)
    }

    public static var isAvailable: Bool { locations() != nil }

    /// Pages for the query. No hits -> empty list. The ids (`id`) are assigned only by LookupHost.
    public func lookup(_ query: String, language: String) async throws -> [WebSource] {
        try Task.checkCancellation()
        guard pending == nil else { throw WebFetchError.busy }
        idleTask?.cancel(); idleTask = nil
        if process?.isRunning != true { try launch() }
        return try Self.sources(from: await send(["type": "lookup", "query": query, "language": language, "maxPages": Self.maxPages]))
    }

    /// A single page (command `page` in fetcher.mjs). Which addresses are allowed is decided by WebAccessGate.
    public func page(_ url: URL, language: String) async throws -> WebSource? {
        try Task.checkCancellation()
        guard pending == nil else { throw WebFetchError.busy }
        idleTask?.cancel(); idleTask = nil
        if process?.isRunning != true { try launch() }
        return try Self.sources(from: await send(["type": "page", "url": url.absoluteString, "language": language])).first
    }

    private func send(_ payload: [String: Any]) async throws -> FetcherReply {
        let id = UUID().uuidString
        var command = payload; command["id"] = id
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(10)
        defer { scheduleIdleShutdown() }
        let reply: FetcherReply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FetcherReply, Error>) in
                self.start(id: id, data: data, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        return reply
    }

    /// Ends the process. The next fetch starts it again.
    public func shutdown() {
        generation += 1
        idleTask?.cancel(); idleTask = nil
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; errors = nil
        finish(throwing: WebFetchError.stopped)
    }

    /// Last error output of the fetch process, only for debugging (never on screen, never in the log).
    var diagnostics: String { stderrTail?.text ?? "" }

    // MARK: - Flow

    private func start(id: String, data: Data, continuation: CheckedContinuation<FetcherReply, Error>) {
        guard let input, process?.isRunning == true else {
            continuation.resume(throwing: WebFetchError.unavailable); return
        }
        pending = (id, continuation)
        do { try input.write(contentsOf: data) } catch { finish(throwing: WebFetchError.failed); return }
        let generation = self.generation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: WebFetcher.timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut(id: id, generation: generation)
        }
    }

    private func timedOut(id: String, generation: Int) {
        guard generation == self.generation, pending?.id == id else { return }
        DiagnosticsLog.shared.event("abruf-zeitueberschreitung")
        // A hanging process does not stay: end it, the next fetch starts anew.
        finish(throwing: WebFetchError.timedOut)
        shutdown()
    }

    private func cancel(id: String) {
        guard pending?.id == id else { return }
        finish(throwing: CancellationError())
        // Otherwise the process keeps working and would still be busy at the next fetch.
        shutdown()
    }

    private func deliver(_ replies: [FetcherReply], generation: Int) {
        guard generation == self.generation else { return }
        for reply in replies {
            guard let pending, reply.id == pending.id else { continue }
            self.pending = nil
            timeoutTask?.cancel(); timeoutTask = nil
            pending.continuation.resume(returning: reply)
        }
    }

    private func terminated(generation: Int) {
        guard generation == self.generation else { return }
        DiagnosticsLog.shared.event("abruf-beendet", ["ausgabe-zeichen": String(diagnostics.count)])
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process = nil; input = nil; output = nil; errors = nil
        self.generation += 1
        finish(throwing: WebFetchError.failed)
    }

    private func finish(throwing error: Error) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(throwing: error)
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let generation = self.generation
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: WebFetcher.idleLimit)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(generation: generation)
        }
    }

    private func idleExpired(generation: Int) {
        guard generation == self.generation, pending == nil else { return }
        shutdown()
    }

    private func launch() throws {
        guard let paths = Self.locations() else { throw WebFetchError.unavailable }
        generation += 1
        let generation = self.generation
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = paths.node
        child.arguments = [paths.entry.path]
        child.currentDirectoryURL = paths.entry.deletingLastPathComponent().deletingLastPathComponent()
        // Only the bare minimum: no credentials, no Node hooks, no proxies from the app's environment.
        let inherited = ProcessInfo.processInfo.environment
        child.environment = Dictionary(uniqueKeysWithValues: ["PATH", "HOME", "TMPDIR", "LANG"].compactMap { key in
            inherited[key].map { (key, $0) }
        })
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        // Split lines and read JSON on the read queue; the actor only gets finished values.
        let lines = FetcherBuffer(limit: 0)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let replies = lines.lines(appending: data).compactMap(FetcherReply.parse)
            guard !replies.isEmpty, let self else { return }
            Task { await self.deliver(replies, generation: generation) }
        }
        let tail = FetcherBuffer(limit: Self.diagnosticsLimit)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        child.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.terminated(generation: generation) }
        }
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        stderrTail = tail
    }

    // MARK: - Read the answer

    static func sources(from reply: FetcherReply) throws -> [WebSource] {
        guard reply.ok else {
            switch reply.code {
            case "no_results": return []
            case "busy": throw WebFetchError.busy
            case "invalid_request": throw WebFetchError.invalidRequest
            default: throw WebFetchError.failed
            }
        }
        let now = Date()
        return reply.sources.compactMap { raw in
            guard let url = URL(string: raw.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let text = String(raw.text.prefix(textLimit))
            guard !text.isEmpty else { return nil }
            let host = url.host?.lowercased() ?? ""
            let site = raw.site.isEmpty ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) : raw.site
            return WebSource(id: "", url: url, site: site, title: raw.title, asOf: raw.asOf.flatMap(isoDay), fetchedAt: now,
                             text: text)
        }
    }

    /// "2026-01-01" -> DayDate.
    static func isoDay(_ text: String) -> DayDate? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return DayDate(year: year, month: month, day: day)
    }
}

/// One answer line of the fetch process, already read on the read queue.
struct FetcherReply: Sendable {
    struct Source: Sendable {
        var url: String
        var site: String
        var title: String
        var asOf: String?
        var text: String
    }
    var id: String?
    var ok: Bool
    var code: String?
    var sources: [Source]

    static func parse(_ line: Data) -> FetcherReply? {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let ok = value["ok"] as? Bool ?? false
        let list = value["sources"] as? [[String: Any]] ?? []
        let sources = list.compactMap { item -> Source? in
            guard let url = item["url"] as? String, let text = item["text"] as? String else { return nil }
            let site = item["site"] as? String ?? ""
            let title = item["title"] as? String ?? ""
            let asOf = item["asOf"] as? String
            return Source(url: url, site: site, title: title, asOf: asOf, text: text)
        }
        return FetcherReply(id: value["id"] as? String, ok: ok, code: value["code"] as? String, sources: sources)
    }
}

/// Buffer for the pipes' read queues: split lines (stdout) or keep only the end (stderr).
final class FetcherBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func lines(appending chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var result: [Data] = []
        while let end = data.firstIndex(of: 10) {
            result.append(Data(data[data.startIndex..<end]))
            data.removeSubrange(data.startIndex...end)
        }
        return result
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
