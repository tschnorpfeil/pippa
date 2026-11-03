import Foundation

/// The oMLX server for Pi's provider `pippa-local`: one process on a fixed port, shared by the app and Pi in the terminal
/// (lock file `PiServerLock`, the same rules as runtime/pippa-local-server/common.mjs).
///
/// - `ensureRunning`: a server already answering on the port is used as it is (the terminal's, or one left from an
///   earlier app run). Otherwise the app takes the lock and starts one, or waits while someone else is starting one.
/// - oMLX unloads the model by itself after `idle_timeout` (settings.json); the process stays and costs little.
/// - `stop`: only a server this app started; a shared one keeps running for the terminal.
public actor OMLXServer {
    public let plan: PiLocalServer.Plan
    let logURL: URL
    private var process: Process?
    private var starting: Task<Void, Error>?
    private var warming: Task<Void, Error>?
    /// Seconds until `/health` answered at the last start, for the diagnostics log.
    public private(set) var lastStartSeconds: Double?

    public init(plan: PiLocalServer.Plan, logDirectory: URL) {
        self.plan = plan
        logURL = logDirectory.appendingPathComponent(PiLocalServer.logName)
    }

    /// The server process this app started; `nil` when none runs or the server is shared.
    public var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    public func ensureRunning() async throws {
        if await health() { return }
        if let starting { return try await withTaskCancellationHandler { try await starting.value } onCancel: { starting.cancel() } }
        let task = Task { try await start() }
        starting = task
        defer { starting = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Loads weights into RAM without a chat request or conversation. A healthy server may have unloaded them.
    /// Concurrent callers share the load; a later call checks with oMLX again after an idle unload.
    public func prewarm() async throws {
        if let warming { return try await warming.value }
        let task = Task {
            try await ensureRunning()
            try Task.checkCancellation()
            let url = URL(string: "http://127.0.0.1:\(plan.port)")!
                .appendingPathComponent("v1/models").appendingPathComponent(plan.modelID).appendingPathComponent("load")
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("Bearer \(plan.key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw PippaError.modelFailed
            }
        }
        warming = task
        defer { warming = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func start() async throws {
        let began = Date()
        let me = getpid()
        let lock = plan.lockFile
        // Someone else holds the lock and is alive: wait for their server instead of starting a second one.
        if let held = PiServerLock.read(lock), held.holder != me, held.isLive {
            if try await waitForHealth(timeout: 180, while: { PiServerLock.read(lock)?.isLive == true }) { return }
        }
        _ = PiServerLock.remove(lock) { !$0.isLive }
        guard PiServerLock.read(lock)?.isLive != true else { throw PippaError.modelFailed }
        guard PiServerLock.create(lock, PiServerLock(owner: "app", holder: me, pid: nil, port: plan.port)) else {
            // Lost the race to the terminal: use theirs.
            if try await waitForHealth(timeout: 180, while: { true }) { return }
            throw PippaError.modelFailed
        }
        do {
            try PiLocalServer.writeServerSettings(plan)
            let p = Process()
            p.executableURL = plan.python
            p.arguments = plan.arguments
            p.environment = PiLocalServer.environment(plan)
            p.currentDirectoryURL = plan.baseDirectory
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let log = try FileHandle(forWritingTo: logURL)
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
            p.standardInput = FileHandle.nullDevice
            try p.run()
            process = p
            PiServerLock.write(lock, PiServerLock(owner: "app", holder: me, pid: p.processIdentifier, port: plan.port))
            guard try await waitForHealth(timeout: 120, while: { p.isRunning }) else {
                throw PippaError.modelFailed
            }
            lastStartSeconds = Date().timeIntervalSince(began)
            DiagnosticsLog.shared.event("server-start", ["sekunden": String(format: "%.1f", lastStartSeconds ?? 0)])
        } catch {
            await stop()
            throw error
        }
    }

    /// Polls `/health` until it answers 200, `alive` turns false or the time is up.
    private func waitForHealth(timeout: Double, while alive: @Sendable () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, alive() {
            try Task.checkCancellation()
            if await health() { return true }
            try await Task.sleep(for: .milliseconds(300))
        }
        return await health()
    }

    private func health() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(plan.port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer \(plan.key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Stops the server this app started (SIGTERM, then SIGKILL after 3 s) and gives back the lock.
    public func stop() async {
        warming?.cancel()
        starting?.cancel()
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
        let me = getpid()
        _ = PiServerLock.remove(plan.lockFile) { $0.holder == me }
    }
}
