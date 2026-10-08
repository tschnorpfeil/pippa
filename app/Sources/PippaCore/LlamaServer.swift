import Foundation

/// Starts and supervises llama-server as a child process: 127.0.0.1 only, random port and key,
/// unloads after 5 minutes without work or under memory pressure, ends with the app.
///
/// The same code also runs the server for Pi's `pippa-local` provider, then
/// with a fixed port and key (`fixedPort`/`fixedKey`, as in models.json), its own idle time and `--alias`.
/// Without these, everything stays as for `LocalEngine`.
public actor LlamaServer {
    public enum State: Sendable, Equatable { case stopped, starting, ready }

    public let choice: ModelChoice
    public let modelPath: URL
    public let binary: URL
    let logURL: URL
    public static let idleSeconds: Double = 300
    /// After a call (letter), the model stays loaded this long (20 minutes).
    public static let afterCallSeconds: Double = 1200

    public private(set) var state: State = .stopped
    /// Fixed port and key (Pi's `pippa-local`); `nil`: random per start (LocalEngine).
    let fixedPort: Int?
    let fixedKey: String?
    /// Model name the server answers under (`--alias`); Pi sends the id from models.json.
    let alias: String?
    /// After this many seconds without a request the model is unloaded (default `idleSeconds`).
    public let idleAfter: Double
    /// Duration from the last start until `/health` returns 200 (model loaded), for measurements and the diagnostics log.
    public private(set) var lastStartSeconds: Double?
    /// Process of the running server (measurements: memory); `nil` if none runs. Shared: the terminal's server.
    public var processID: Int32? {
        if process?.isRunning == true { return process?.processIdentifier }
        return adoptedPID.flatMap { PiServerLock.isAlive($0) ? $0 : nil }
    }
    private var process: Process?
    /// Already running: a request starts without loading (Thought Line shows "Getting ready" only otherwise).
    public var isWarm: Bool { state == .ready && (process?.isRunning == true || adoptedPID.map(PiServerLock.isAlive) == true) }
    /// Shared lock file with Pippa's terminal extension (runtime/pippa-local-server, `PiServerLock`); only for
    /// `pippa-local` with a fixed port. Without it (LocalEngine, older checks) as before.
    public let lockFile: URL?
    /// If a server started by the terminal extension is already running, the app shares it (no second server).
    /// It never stops it; unloading when idle is done by the extension's watcher.
    private var adoptedPID: Int32?
    public var isAdopted: Bool { adoptedPID != nil }
    private var watchdogPipe: Pipe?
    private var port = 0
    private var apiKey = ""
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var supportedFlags: Set<String>?
    /// Until then, idling does not unload the model (`keepWarm`); memory pressure and `stop()` still apply.
    private var warmUntil: Date = .distantPast

    /// Prompt cache across idle unloading. When set (only Pi's `pippa-local`):
    /// the server starts with `--slot-save-path <folder>`, `stopIfIdle` saves slot 0 before unloading
    /// (`/slots/0?action=save`), and after the next start `ensureRunning` restores it before the first request arrives.
    /// Without a folder, as before.
    public let slotDirectory: URL?
    /// With a slot folder also `--swa-full` (see `arguments`); `PIPPA_LLAMA_SWA_FULL=0` only for measurements.
    let swaFullWithSlots = ProcessInfo.processInfo.environment["PIPPA_LLAMA_SWA_FULL"] != "0"
    /// Does the current server run with `--slot-save-path` (does this llama.cpp know the switch)? Only then save/restore.
    private var slotsActive = false
    /// Last save or restore (measurements, diagnostics log).
    public struct SlotEvent: Sendable, Equatable {
        public var tokens: Int
        public var seconds: Double
        public var bytes: Int
        public var ok: Bool
    }
    public private(set) var lastSlotSave: SlotEvent?
    public private(set) var lastSlotRestore: SlotEvent?

    public init(choice: ModelChoice, modelPath: URL, binary: URL, logDirectory: URL,
                fixedPort: Int? = nil, fixedKey: String? = nil, alias: String? = nil, idleAfter: Double = LlamaServer.idleSeconds,
                logName: String = "llama-server.log", slotDirectory: URL? = nil, lockFile: URL? = nil) {
        self.choice = choice; self.modelPath = modelPath; self.binary = binary
        self.lockFile = lockFile
        self.fixedPort = fixedPort; self.fixedKey = fixedKey; self.alias = alias; self.idleAfter = idleAfter
        self.slotDirectory = slotDirectory
        logURL = logDirectory.appendingPathComponent(logName)
    }

    /// Bundled in Contents/Helpers/llama-server; for development via PIPPA_LLAMA_SERVER.
    public static func binaryURL() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["PIPPA_LLAMA_SERVER"], fm.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server")
        return fm.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    /// Free TCP port on 127.0.0.1.
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8190 + Int.random(in: 0..<500) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 8190 + Int.random(in: 0..<500)
    }

    /// Is something already listening on 127.0.0.1:`port`? (Probe with SO_REUSEADDR like llama-server itself, so a just-
    /// stopped own server in TIME_WAIT does not count as taken.)
    static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    static func randomKey() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Options this build knows (from `--help`), so unknown switches do not prevent the start.
    private func flags() -> Set<String> {
        if let supportedFlags { return supportedFlags }
        let found = Self.supportedFlags(binary: binary)
        supportedFlags = found
        return found
    }

    /// Switches from `<binary> --help` (also for the terminal extension's launch file, `PiLocalServer.launchFile`).
    public static func supportedFlags(binary: URL) -> Set<String> {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--help"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        var found = Set<String>()
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if let re = try? NSRegularExpression(pattern: #"--[a-z0-9][a-z0-9-]*"#) {
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range, in: text) { found.insert(String(text[r])) }
                }
            }
        }
        return found
    }

    /// Start arguments, ported from installer/service.mjs (presets) and the benchmark setup.
    /// The key is not in the arguments (readable by any process via `ps`) but in `environment(apiKey:)`.
    /// `alias`: only for Pi's `pippa-local` (model id from models.json), otherwise none as before.
    public static func arguments(choice: ModelChoice, model: URL, port: Int, supported: Set<String>?, alias: String? = nil,
                                 slotSavePath: URL? = nil, swaFull: Bool = false) -> [String] {
        func ok(_ flag: String) -> Bool { supported.map { $0.isEmpty || $0.contains(flag) } ?? true }
        var args = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                    "--jinja", "--ctx-size", String(choice.ctx), "--parallel", "1"]
        if let alias, ok("--alias") { args += ["--alias", alias] }
        if let slotSavePath, ok("--slot-save-path") { args += ["--slot-save-path", slotSavePath.path] }
        // Sliding-window layers otherwise keep only the last window. After restoring a slot, the intermediate
        // states are missing (checkpoints are not in the file); if the end of the new request differs by even a
        // few tokens, llama-server re-reads everything. With a full SWA cache it can truncate anywhere.
        if swaFull, ok("--swa-full") { args.append("--swa-full") }
        if ok("--no-webui") { args.append("--no-webui") }
        // The fixed JSON flows want no "thinking", whatever the template calls it. Pi's server (with `alias`) leaves it to
        // Pi, which sets the level per request (`chat_template_kwargs`, PiModelTuning).
        if alias == nil, ok("--reasoning") { args += ["--reasoning", "off"] }
        if ok("--cache-type-k") { args += ["--cache-type-k", "q8_0", "--cache-type-v", "q8_0"] }
        for key in choice.sampling.keys.sorted() where ok("--\(key)") {
            args += ["--\(key)", JSONScalar.number(choice.sampling[key]!).description]
        }
        for key in choice.extra.keys.sorted() where ok("--\(key)") {
            args += ["--\(key)", choice.extra[key]!]
        }
        return args
    }

    /// Server environment: inherited, plus the key as LLAMA_API_KEY (equivalent to `--api-key`, llama.cpp b11146 and b11503).
    public static func environment(apiKey: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["LLAMA_API_KEY"] = apiKey
        return env
    }

    /// Is the server running and the model loaded? Starts on demand. Callers that arrive while a start is under way
    /// (a preload when the pill opens, then the first answer) wait for that start instead of beginning another one.
    public func ensureRunning() async throws {
        if let pendingStart { return try await pendingStart.value }
        let start = Task { try await self.startIfNeeded() }
        pendingStart = start
        defer { pendingStart = nil }
        try await start.value
    }

    private var pendingStart: Task<Void, Error>?
    /// While loading: when the process started, what `/health` last said, the size of the weights (cold-start progress).
    private var loadStartedAt: Date?
    private var lastHealth = ColdStart.Health.silent
    private var loadBytes: UInt64 = 0

    /// Progress of a start under way (`nil` when the server is ready or stopped). Memory of the own process; a server
    /// started by the terminal is measured by time only.
    public func coldStartSample() -> ColdStart.Sample? {
        guard state == .starting, let loadStartedAt else { return nil }
        let pid = process?.isRunning == true ? process?.processIdentifier : nil
        return ColdStart.Sample(residentBytes: pid.flatMap(ColdStart.memory(pid:))?.resident, modelBytes: loadBytes, health: lastHealth,
                                elapsed: Date().timeIntervalSince(loadStartedAt), lastLoadSeconds: ColdStart.lastLoadSeconds)
    }

    private func startIfNeeded() async throws {
        installPressureWatch()
        if state == .ready, let process, process.isRunning, await health() == 200 { return }
        if state == .ready, let adoptedPID, PiServerLock.isAlive(adoptedPID), await health() == 200 { touchLock(); return }
        stop()
        state = .starting
        loadStartedAt = Date(); lastHealth = .silent
        if loadBytes == 0 { loadBytes = ColdStart.modelBytes(choice, file: modelPath) }
        port = fixedPort ?? Self.freePort()
        apiKey = fixedKey ?? Self.randomKey()
        // Lock file (shared with the terminal extension): if the terminal is already starting or running the server,
        // the app waits for it and shares it instead of starting a second one.
        if let lockFile, fixedPort != nil {
            if try await claimOrAdopt(lockFile) {
                state = .ready
                lastStartSeconds = nil
                DiagnosticsLog.shared.event("llama-mitbenutzt", ["port": String(port)])
                return
            }
        }
        // Fixed port: if another process is already listening there (a second Pippa, a foreign server), do not
        // start next to it but fail clearly.
        if fixedPort != nil, !Self.portIsFree(port) {
            state = .stopped
            releaseLock()
            DiagnosticsLog.shared.event("llama-port-belegt", ["port": String(port)])
            throw PippaError.modelFailed
        }
        let started = Date()
        let p = Process()
        p.executableURL = binary
        // Folder for the saved slot, readable only by Pippa (the slot is the last conversation as KV cache).
        let slots = slotDirectory.flatMap { dir -> URL? in
            (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil ? dir : nil
        }
        p.arguments = Self.arguments(choice: choice, model: modelPath, port: port, supported: flags(), alias: alias, slotSavePath: slots,
                                     swaFull: slots != nil && swaFullWithSlots)
        p.environment = Self.environment(apiKey: apiKey)
        p.currentDirectoryURL = logURL.deletingLastPathComponent()
        rotateLog()
        // Append instead of overwrite: otherwise every restart after unloading loses the log before it.
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            _ = try? log.seekToEnd()
            p.standardOutput = log; p.standardError = log
        }
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            state = .stopped; releaseLock()
            DiagnosticsLog.shared.event("llama-start-fehlgeschlagen", ["grund": "nicht-startbar"]); throw PippaError.serverMissing
        }
        process = p
        if let lockFile, fixedPort != nil {
            PiServerLock.write(lockFile, PiServerLock(owner: "app", holder: getpid(), pid: p.processIdentifier, port: port))
        }
        startWatchdog(pid: p.processIdentifier)

        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard p.isRunning else { state = .stopped; releaseLock(); DiagnosticsLog.shared.event("llama-beendet", ["phase": "start"]); throw PippaError.modelFailed }
            lastHealth = ColdStart.Health(status: await health())
            if lastHealth == .ready {
                lastStartSeconds = Date().timeIntervalSince(started)
                ColdStart.rememberLoad(seconds: lastStartSeconds ?? 0)
                if fixedPort != nil { DiagnosticsLog.shared.event("llama-bereit", ["dauer-s": String(format: "%.1f", lastStartSeconds ?? 0)]) }
                // Restore the saved slot before the first request arrives (lease and Pi wait for this function).
                slotsActive = p.arguments?.contains("--slot-save-path") == true
                if slotsActive { await restoreSlot() }
                state = .ready
                scheduleIdle(); return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        DiagnosticsLog.shared.event("llama-start-zeitueberschreitung", ["dauer-s": "600"])
        stop()
        throw PippaError.modelFailed
    }

    /// Take the lock (returns `true`: a terminal-extension server is already running, the app shares it) or
    /// fail clearly if another app (a second Pippa) holds the server. An orphaned lock is removed.
    private func claimOrAdopt(_ url: URL) async throws -> Bool {
        let me = getpid()
        let deadline = Date().addingTimeInterval(600)
        for _ in 0..<100_000 {
            if PiServerLock.create(url, PiServerLock(owner: "app", holder: me, pid: nil, port: port)) { return false }
            guard let lock = PiServerLock.read(url) else { PiServerLock.remove(url) { _ in false }; continue }
            if !lock.isLive || lock.holder == me {
                // Orphaned, or our own from earlier (this process runs no server right now: `stop()` ran).
                PiServerLock.remove(url) { $0 == lock }
                continue
            }
            guard lock.owner == "pi", lock.port == port else {
                state = .stopped
                DiagnosticsLog.shared.event("llama-port-belegt", ["port": String(port), "besitzer": lock.owner])
                throw PippaError.modelFailed
            }
            // The terminal's server is loading or running: wait until it responds.
            lastHealth = ColdStart.Health(status: await health())
            if lastHealth == .ready {
                adoptedPID = lock.pid ?? lock.holder
                slotsActive = false
                touchLock()
                return true
            }
            guard Date() < deadline else {
                state = .stopped
                DiagnosticsLog.shared.event("llama-start-zeitueberschreitung", ["dauer-s": "600", "besitzer": "pi"])
                throw PippaError.modelFailed
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        state = .stopped
        throw PippaError.modelFailed
    }

    /// Remove our own lock (never someone else's).
    private func releaseLock() {
        guard let lockFile else { return }
        let me = getpid()
        PiServerLock.remove(lockFile) { $0.holder == me && $0.owner == "app" }
    }

    /// Request via the app: the terminal extension's watcher then does not unload a shared server.
    private func touchLock() {
        if let lockFile { PiServerLock.touch(lockFile) }
    }

    /// A watcher process ends the server as soon as the app is gone (pipe end = EOF).
    private func startWatchdog(pid: Int32) {
        let pipe = Pipe()
        let w = Process()
        w.executableURL = URL(fileURLWithPath: "/bin/sh")
        w.arguments = ["-c", "read _; kill -TERM \(pid) 2>/dev/null; sleep 3; kill -KILL \(pid) 2>/dev/null; exit 0"]
        w.standardInput = pipe
        w.standardOutput = FileHandle.nullDevice; w.standardError = FileHandle.nullDevice
        if (try? w.run()) != nil { watchdogPipe = pipe }
    }

    private func rotateLog() {
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            let old = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old) // own old log
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
    }

    private func health() async -> Int {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/health") else { return 0 }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response = try? await URLSession.shared.data(for: req).1
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Stops the server safely: SIGTERM, wait up to 2 s, then SIGKILL. Also when the app quits.
    public func stop() {
        idleTask?.cancel(); idleTask = nil
        // Shared: just let go. The server belongs to the terminal extension, its watcher unloads it when idle.
        if adoptedPID != nil { adoptedPID = nil; state = .stopped; return }
        let owned = process != nil
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(pid, SIGKILL); process.waitUntilExit() }
        }
        process = nil
        try? watchdogPipe?.fileHandleForWriting.close()
        watchdogPipe = nil
        if owned { releaseLock() }
        state = .stopped
    }

    /// Keeps an already running model loaded for at least `seconds`. Starts nothing; if the idle timer is running,
    /// it restarts with the longer deadline.
    public func keepWarm(for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if until > warmUntil { warmUntil = until }
        if state == .ready, inFlight == 0, idleTask != nil { scheduleIdle() }
    }

    private func scheduleIdle(after minimum: Double? = nil) {
        idleTask?.cancel()
        let delay = max(minimum ?? idleAfter, warmUntil.timeIntervalSinceNow)
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard inFlight == 0 else { return }
        // Fixed port: the terminal Pi also talks to the server directly, bypassing Pippa. If it is computing, wait.
        if fixedPort != nil, await slotsBusy() { if inFlight == 0, state == .ready { scheduleIdle() }; return }
        // The terminal extension reports every request via the lock file: recently used → do not unload yet.
        if let lockFile, adoptedPID == nil,
           let touched = try? FileManager.default.attributesOfItem(atPath: lockFile.path)[.modificationDate] as? Date,
           Date().timeIntervalSince(touched) < idleAfter - 0.5 {
            if inFlight == 0, state == .ready { scheduleIdle(after: idleAfter - Date().timeIntervalSince(touched)) }
            return
        }
        guard inFlight == 0 else { return }
        // Save the prompt cache. If a request arrives meanwhile (lease or terminal Pi), do not unload.
        if slotsActive, state == .ready {
            await saveSlot()
            guard inFlight == 0, state == .ready else { return }
            if fixedPort != nil, await slotsBusy() { if inFlight == 0, state == .ready { scheduleIdle() }; return }
            guard inFlight == 0, state == .ready else { return }
        }
        if fixedPort != nil { DiagnosticsLog.shared.event("llama-entladen", ["leerlauf-s": String(Int(idleAfter))]) }
        stop()
    }

    // MARK: Save / restore slot

    /// File name of the saved slot: one per alias, model file and context (a different model never reads a
    /// foreign cache). Only characters llama-server accepts as file names.
    public static func slotFileName(alias: String?, model: URL, ctx: Int) -> String {
        let raw = "pippa-slot-\(alias ?? "local")-\(model.deletingPathExtension().lastPathComponent)-c\(ctx)"
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(String(raw.map { allowed.contains($0) ? $0 : "_" }).prefix(180)) + ".bin"
    }

    /// Where this server's slot is saved (`nil` without `slotDirectory`).
    public var slotFile: URL? { slotDirectory?.appendingPathComponent(Self.slotFileName(alias: alias, model: modelPath, ctx: choice.ctx)) }

    /// `POST /slots/0?action=save|restore` (llama.cpp; `--parallel 1` → slot 0). Response with `n_saved`/`n_restored`.
    private func slotAction(_ action: String, timeout: Double) async -> (status: Int, tokens: Int) {
        guard port > 0, let file = slotFile, let url = URL(string: "http://127.0.0.1:\(port)/slots/0?action=\(action)") else { return (0, 0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": file.lastPathComponent])
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return (0, 0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, (json?["n_saved"] as? Int) ?? (json?["n_restored"] as? Int) ?? 0)
    }

    /// Before unloading: save slot 0. Errors only cost the cache.
    func saveSlot() async {
        guard let file = slotFile else { return }
        let started = Date()
        let (status, tokens) = await slotAction("save", timeout: 60)
        if status == 200 { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let seconds = Date().timeIntervalSince(started)
        lastSlotSave = SlotEvent(tokens: tokens, seconds: seconds, bytes: bytes, ok: status == 200 && tokens > 0)
        DiagnosticsLog.shared.event("llama-slot-gesichert", ["status": String(status), "tokens": String(tokens), "mb": String(bytes >> 20),
                                                              "dauer-ms": String(Int(seconds * 1000))])
    }

    /// After the start: load this model's saved slot if one exists. If that fails (old file, different
    /// llama.cpp), the answer starts as without a cache.
    func restoreSlot() async {
        guard let file = slotFile, FileManager.default.fileExists(atPath: file.path) else { lastSlotRestore = nil; return }
        let started = Date()
        let (status, tokens) = await slotAction("restore", timeout: 60)
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let seconds = Date().timeIntervalSince(started)
        lastSlotRestore = SlotEvent(tokens: tokens, seconds: seconds, bytes: bytes, ok: status == 200 && tokens > 0)
        DiagnosticsLog.shared.event("llama-slot-geladen", ["status": String(status), "tokens": String(tokens), "dauer-ms": String(Int(seconds * 1000))])
    }

    /// The saved slot is the last conversation as cache. If a conversation is deleted, it disappears with it
    /// (Pippa's own cache file; the running server keeps its memory until unloading).
    public func discardSavedSlot() {
        guard let file = slotFile else { return }
        try? FileManager.default.removeItem(at: file)
        lastSlotSave = nil
    }

    /// Is the server processing a request right now? (`/slots`, llama.cpp; unreadable counts as free.)
    private func slotsBusy() async -> Bool {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/slots") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200,
              let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return slots.contains { $0["is_processing"] as? Bool == true }
    }

    private func installPressureWatch() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            let critical = source.data.contains(.critical)
            Task { await self?.memoryPressure(critical: critical) }
        }
        source.resume()
        pressure = source
    }

    /// Never while starting (otherwise the start fails mid-load); on "warning" only without running work
    /// (an agent lease counts), on "critical" always.
    private func memoryPressure(critical: Bool) {
        guard state != .starting else { return }
        if critical || inFlight == 0 { stop() }
    }

    /// For development: every request with its response as a JSON line in PIPPA_MODEL_TRACE (recordings for checks).
    static func trace(schemaName: String, user: String, status: Int, response: Data, seconds: Double) {
        guard let path = ProcessInfo.processInfo.environment["PIPPA_MODEL_TRACE"], !path.isEmpty else { return }
        let parsed = (try? JSONSerialization.jsonObject(with: response)) ?? String(decoding: response, as: UTF8.self)
        let line: [String: Any] = ["schema": schemaName, "user": user, "status": status, "seconds": seconds, "response": parsed]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
    }

    /// Hold the current server alive for a complete Pi agent run, including tool turns.
    public struct AgentLease: Sendable {
        public let id: UUID
        public let endpoint: URL
        public let apiKey: String
        public let modelID: String
        public let contextWindow: Int
    }
    private var agentLeases = Set<UUID>()
    public func acquireAgentLease() async throws -> AgentLease {
        try await ensureRunning()
        let id = UUID(); agentLeases.insert(id); inFlight += 1
        idleTask?.cancel(); idleTask = nil
        touchLock()
        return AgentLease(id: id, endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!, apiKey: apiKey,
                          modelID: choice.model.key, contextWindow: choice.ctx)
    }
    public func releaseAgentLease(_ lease: AgentLease) {
        guard agentLeases.remove(lease.id) != nil else { return }
        inFlight -= 1; touchLock(); scheduleIdle()
    }

    /// One request with an enforced JSON schema; returns the JSON text of the response.
    public func completeJSON(system: String, user: String, schemaName: String, schema: String, maxTokens: Int = 600) async throws -> Data {
        try await ensureRunning()
        inFlight += 1
        touchLock()
        defer { inFlight -= 1; touchLock(); scheduleIdle() }
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "response_format": ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schemaObject]],
            "max_tokens": maxTokens,
            "temperature": 0.1,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.trace(schemaName: schemaName, user: user, status: status, response: data, seconds: Date().timeIntervalSince(started))
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String else { throw PippaError.modelFailed }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content.replacingOccurrences(of: #"^```(json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        }
        return Data(content.utf8)
    }
}
