import Foundation

// Pippa drives the real Pi via `pi --mode rpc`. Protocol: JSONL on stdin/stdout,
// see the Pi docs rpc.md, rpc-commands.md, rpc-extension-ui.md.
// Deliberately no dependency on PippaCore, so the probe program builds fast.

/// Errors the app must distinguish. User-facing texts come from the app, not this client.
public enum PiRPCError: Error, LocalizedError, Equatable, Sendable {
    /// No executable `pi` at the path.
    case notInstalled(path: String)
    /// `pi --version` reports a version outside the tested range.
    case versionMismatch(found: String, supported: String)
    /// `pi --version` returned nothing readable (or did not run).
    case versionUnreadable(output: String)
    case notRunning
    /// A response is already running; use `steer`/`followUp` or `abort` first.
    case busy
    /// Pi rejected a command (`success: false`).
    case commandFailed(command: String, message: String)
    /// The Pi process ended. `diagnostics`: end of stderr, for debugging only.
    case processExited(status: Int32, diagnostics: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path): "Pi is not installed at \(path)."
        case .versionMismatch(let found, let supported): "Pi \(found) is not a tested version (tested: \(supported))."
        case .versionUnreadable(let output): "Could not read the Pi version: \(output.prefix(200))"
        case .notRunning: "Pi is not running."
        case .busy: "Pi is still answering."
        case .commandFailed(let command, let message): "Pi rejected \(command): \(message)"
        case .processExited(let status, _): "Pi stopped unexpectedly (exit status \(status))."
        }
    }
}

public struct PiRPCConfiguration: Sendable {
    /// The `pi` executable (e.g. ~/.local/bin/pi).
    public var executable: URL
    /// Pi's working directory: write/edit/bash create relative paths there.
    public var workingDirectory: URL
    /// Additional environment (e.g. PI_CODING_AGENT_DIR, PIPPA_UNDO_DIR). PATH gets Homebrew added because `pi` is a
    /// Node script and an app launched from Finder only knows /usr/bin:/bin.
    public var environment: [String: String]
    /// Loaded with `--extension` (the Pippa guard).
    public var extensions: [URL]
    /// Further Pi options, e.g. `--no-session`, `--tools read,write`, `--append-system-prompt …`.
    public var arguments: [String]
    /// Installer (`PiLaunchSpec`): arguments directly after `executable`, before all Pi options, e.g. the path to the
    /// CLI of the pinned release when `executable` is Pippa's Node. Also applies to `--version`.
    public var launcherArguments: [String] = []
    public init(executable: URL, workingDirectory: URL, environment: [String: String] = [:], extensions: [URL] = [], arguments: [String] = ["--no-session"]) {
        self.executable = executable; self.workingDirectory = workingDirectory; self.environment = environment
        self.extensions = extensions; self.arguments = arguments
    }
}

/// What happens during a response, in order.
public enum PiRPCEvent: Sendable, Equatable {
    /// A piece of response text.
    case textDelta(String)
    /// Pi calls a tool (arrives before the guard's confirmation request). `arguments`: JSON, truncated.
    case toolStarted(id: String, name: String, arguments: String)
    case toolEnded(id: String, name: String, isError: Bool, result: String)
    /// Pi picked up another message from the person (delivered via `steer` or `followUp`).
    case userMessage(String)
    /// A model response is done. `stopReason`: "stop", "toolUse", "aborted", "error", …
    case assistantEnded(text: String, stopReason: String, error: String?)
    /// `ctx.ui.notify` of an extension.
    case notice(String, kind: String)
    /// `pippa-receipt` entry of the Pippa guard (rejected, blocked, done, failed); basis of the receipt.
    case guardOutcome(PiGuardOutcome)
    /// Pi does not continue on its own (`agent_settled`). The stream ends afterwards.
    case settled
}

/// A confirmation request from an extension (`extension_ui_request` with `confirm`, `select`, `input` or `editor`).
public struct PiUIRequest: Sendable, Equatable {
    public let id: String
    public let method: String
    public let title: String
    public let message: String
    public let options: [String]
    public let placeholder: String?
    public let prefill: String?
    public let timeout: Int?

    public init(id: String, method: String, title: String, message: String, options: [String] = [],
                placeholder: String? = nil, prefill: String? = nil, timeout: Int? = nil) {
        self.id = id; self.method = method; self.title = title; self.message = message; self.options = options
        self.placeholder = placeholder; self.prefill = prefill; self.timeout = timeout
    }
}

public enum PiUIResponse: Sendable, Equatable {
    case confirmed(Bool)
    case value(String)
    case cancelled
}

public typealias PiUIHandler = @Sendable (PiUIRequest) async -> PiUIResponse

/// Drives a `pi --mode rpc` process. One response at a time; deliver more via `steer`/`followUp`.
public actor PiRPCClient {
    /// Tested range: the pinned minor version (app/Packaging/pi-release, currently Pi 1.1.x). `start()` rejects other versions
    /// with `.versionMismatch`. scripts/bump-pi.sh aborts if that does not match the new pin.
    public static let supportedVersionPrefix = "1.1."
    public nonisolated let configuration: PiRPCConfiguration
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [String: CheckedContinuation<Response, Error>] = [:]
    private var events: AsyncThrowingStream<PiRPCEvent, Error>.Continuation?
    private var uiHandler: PiUIHandler?
    private let stderrTail = Buffer(limit: 16 * 1024)
    /// The version `start()` found.
    public private(set) var version: String?
    private var nextID = 0
    /// How many user messages have arrived in the current run: the first is the prompt itself, each further one delivered later.
    private var userMessagesInRun = 0

    struct Response: Sendable { let success: Bool; let error: String?; let data: Data? }

    public init(configuration: PiRPCConfiguration) { self.configuration = configuration }

    public func setUIHandler(_ handler: PiUIHandler?) { uiHandler = handler }
    public var isRunning: Bool { process?.isRunning == true }
    public var isAnswering: Bool { events != nil }

    // MARK: Version

    /// Read `pi --version` and check it against the tested range.
    public static func checkVersion(executable: URL, launcherArguments: [String] = [], environment: [String: String] = [:]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PiRPCError.notInstalled(path: executable.path) }
        let child = Process(), out = Pipe()
        child.executableURL = executable
        child.arguments = launcherArguments + ["--version"]
        child.environment = processEnvironment(environment)
        child.standardOutput = out; child.standardError = out
        do { try child.run() } catch { throw PiRPCError.versionUnreadable(output: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return try checkVersion(output: String(decoding: data, as: UTF8.self))
    }

    /// Only the check, for tests with made-up output.
    public static func checkVersion(output: String) throws -> String {
        let pattern = try! NSRegularExpression(pattern: #"\b(\d+)\.(\d+)\.(\d+)\b"#)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { throw PiRPCError.versionUnreadable(output: text) }
        let found = String(text[range])
        guard found.hasPrefix(supportedVersionPrefix) else { throw PiRPCError.versionMismatch(found: found, supported: supportedVersionPrefix + "x") }
        return found
    }

    static func processEnvironment(_ extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = Dictionary(uniqueKeysWithValues: ["HOME", "TMPDIR", "LANG", "USER", "LOGNAME"].compactMap { key in inherited[key].map { (key, $0) } })
        let path = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) } + [path]).joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }

    // MARK: Process

    /// Check the version and start Pi. Calling it repeatedly is harmless.
    public func start() async throws {
        if process?.isRunning == true { return }
        version = try Self.checkVersion(executable: configuration.executable, launcherArguments: configuration.launcherArguments,
                                        environment: configuration.environment)
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = configuration.executable
        child.arguments = configuration.launcherArguments + ["--mode", "rpc"] + configuration.extensions.flatMap { ["--extension", $0.path] } + configuration.arguments
        child.currentDirectoryURL = configuration.workingDirectory
        child.environment = Self.processEnvironment(configuration.environment)
        child.standardInput = input; child.standardOutput = output; child.standardError = errors

        // An ordered sequence of lines and process end; a single reader in the actor works through it.
        let (lines, sink) = AsyncStream<Incoming>.makeStream()
        let splitter = Buffer(limit: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Split on LF only (rpc.md "Framing"): U+2028 in JSON strings is not a line ending.
            for line in splitter.lines(appending: data) { sink.yield(.line(line)) }
        }
        let tail = stderrTail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        child.terminationHandler = { process in
            // Wait briefly so the last stdout lines arrive before the end.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                sink.yield(.exited(process.terminationStatus)); sink.finish()
            }
        }
        try child.run()
        process = child; stdin = input.fileHandleForWriting
        Task { [weak self] in for await item in lines { await self?.handle(item) } }
    }

    /// Close stdin (orderly shutdown per rpc.md), kill hard after two seconds.
    public func shutdown() async {
        guard let child = process else { return }
        try? stdin?.close()
        for _ in 0..<20 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning { child.terminate() }
    }

    /// Process ID, for logs and targeted termination.
    public var pid: Int32? { process?.processIdentifier }

    // MARK: Commands

    /// Sends a question. The stream ends with `.settled` or throws (`.processExited`, …).
    public func prompt(_ text: String) async throws -> AsyncThrowingStream<PiRPCEvent, Error> {
        guard process?.isRunning == true else { throw PiRPCError.notRunning }
        guard events == nil else { throw PiRPCError.busy }
        // Listen first, then send (rpc.md "Run lifecycle").
        let (stream, continuation) = AsyncThrowingStream<PiRPCEvent, Error>.makeStream()
        events = continuation
        userMessagesInRun = 0
        do {
            let response = try await send(["type": "prompt", "message": text])
            if Self.disposition(response) == "handled" { finish(nil) }
        } catch {
            finish(error)
            throw error
        }
        return stream
    }

    /// Steer: delivered after the running tool calls and before the next model call.
    /// `true`: Pi accepted the message (it then appears as `.userMessage`).
    @discardableResult public func steer(_ text: String) async throws -> Bool {
        Self.disposition(try await send(["type": "steer", "message": text])) == "queued"
    }

    /// Deliver only after the running work has ended.
    @discardableResult public func followUp(_ text: String) async throws -> Bool {
        Self.disposition(try await send(["type": "follow_up", "message": text])) == "queued"
    }

    /// Abort; Pi replies only once the session is idle again.
    public func abort() async throws {
        _ = try await send(["type": "abort"])
    }

    /// Arbitrary command, for trial runs (`get_state`, `get_session_stats`, …). Returns `data` as JSON.
    public func command(_ payload: [String: any Sendable]) async throws -> Data? {
        try await send(payload).data
    }

    private static func disposition(_ response: Response) -> String? {
        response.data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["disposition"] as? String
    }

    private func send(_ payload: [String: any Sendable]) async throws -> Response {
        guard let stdin, process?.isRunning == true else { throw PiRPCError.notRunning }
        nextID += 1
        let id = "pippa-\(nextID)"
        var command: [String: Any] = payload
        command["id"] = id
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(10)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
            pending[id] = continuation
            do { try stdin.write(contentsOf: data) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
        guard response.success else {
            throw PiRPCError.commandFailed(command: payload["type"] as? String ?? "?", message: response.error ?? "")
        }
        return response
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? stdin.write(contentsOf: data)
    }

    // MARK: Input

    enum Incoming: Sendable { case line(Data), exited(Int32) }

    private func handle(_ item: Incoming) {
        switch item {
        case .exited(let status):
            let error = PiRPCError.processExited(status: status, diagnostics: stderrTail.text)
            let waiting = pending.values; pending.removeAll()
            for continuation in waiting { continuation.resume(throwing: error) }
            finish(error)
            process = nil; stdin = nil
        case .line(let line):
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            route(record)
        }
    }

    private func route(_ record: [String: Any]) {
        switch record["type"] as? String {
        case "response":
            guard let id = record["id"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
            let data = record["data"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            continuation.resume(returning: Response(success: record["success"] as? Bool == true, error: record["error"] as? String, data: data))
        case "message_update":
            guard let update = record["assistantMessageEvent"] as? [String: Any], update["type"] as? String == "text_delta",
                  let delta = update["delta"] as? String else { return }
            events?.yield(.textDelta(delta))
        case "message_start":
            guard let message = record["message"] as? [String: Any], message["role"] as? String == "user" else { return }
            userMessagesInRun += 1
            if userMessagesInRun > 1 { events?.yield(.userMessage(Self.text(of: message))) }
        case "message_end":
            guard let message = record["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            events?.yield(.assistantEnded(text: Self.text(of: message), stopReason: message["stopReason"] as? String ?? "",
                                          error: message["errorMessage"] as? String))
        case "tool_execution_start":
            events?.yield(.toolStarted(id: record["toolCallId"] as? String ?? "", name: record["toolName"] as? String ?? "",
                                       arguments: Self.json(record["args"], limit: 400)))
        case "tool_execution_end":
            let result = (record["result"] as? [String: Any]).map { Self.text(of: $0) } ?? ""
            let name = record["toolName"] as? String ?? ""
            // Pi's own `read` in full (up to 200,000 characters; Pi itself returns at most 50 KB per call): the
            // source check checks against exactly what Pi read (PiReadLedger). Everything else only the beginning.
            // Searches and listings: enough to count result lines for the everyday step summary ("3 matches").
            let limit = name == "read" ? Self.readResultLimit : Self.listingTools.contains(name) ? Self.listingResultLimit : 400
            events?.yield(.toolEnded(id: record["toolCallId"] as? String ?? "", name: name,
                                     isError: record["isError"] as? Bool == true, result: String(result.prefix(limit))))
        case "entry_appended":
            // Only Pippa's own receipt entries; other extensions write their own state there.
            guard let entry = record["entry"] as? [String: Any], entry["type"] as? String == "custom",
                  entry["customType"] as? String == PiGuardOutcome.entryType, let data = entry["data"],
                  let json = try? JSONSerialization.data(withJSONObject: data),
                  let outcome = try? JSONDecoder().decode(PiGuardOutcome.self, from: json) else { return }
            events?.yield(.guardOutcome(outcome))
        case "agent_settled":
            events?.yield(.settled)
            finish(nil)
        case "extension_ui_request":
            uiRequest(record)
        default:
            break
        }
    }

    public static let readResultLimit = 200_000
    public static let listingResultLimit = 20_000
    static let listingTools: Set<String> = ["bash", "find", "grep", "ls"]

    private func uiRequest(_ record: [String: Any]) {
        guard let id = record["id"] as? String, let method = record["method"] as? String else { return }
        switch method {
        case "confirm", "select", "input", "editor":
            let request = PiUIRequest(id: id, method: method, title: record["title"] as? String ?? "", message: record["message"] as? String ?? "",
                                      options: record["options"] as? [String] ?? [], placeholder: record["placeholder"] as? String,
                                      prefill: record["prefill"] as? String, timeout: record["timeout"] as? Int)
            let handler = uiHandler
            // Don't wait in the reader: while the dialog is open, `abort` and further lines must get through.
            Task { [weak self] in
                let answer = await handler?(request) ?? .cancelled
                await self?.respond(id: id, answer)
            }
        case "notify":
            events?.yield(.notice(record["message"] as? String ?? "", kind: record["notifyType"] as? String ?? "info"))
        default:
            break   // setStatus, setWidget, setTitle, set_editor_text: no display needed
        }
    }

    private func respond(id: String, _ answer: PiUIResponse) {
        switch answer {
        case .confirmed(let yes): write(["type": "extension_ui_response", "id": id, "confirmed": yes])
        case .value(let value): write(["type": "extension_ui_response", "id": id, "value": value])
        case .cancelled: write(["type": "extension_ui_response", "id": id, "cancelled": true])
        }
    }

    private func finish(_ error: Error?) {
        if let error { events?.finish(throwing: error) } else { events?.finish() }
        events = nil
    }

    private static func text(of message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    private static func json(_ value: Any?, limit: Int) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "" }
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }
}

/// Buffer for the read queues: split lines at LF (stdout) or keep only the tail (stderr).
final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func lines(appending chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var result: [Data] = []
        while let end = data.firstIndex(of: 10) {
            var line = Data(data[data.startIndex..<end])
            if line.last == 13 { line.removeLast() }
            result.append(line); data.removeSubrange(data.startIndex...end)
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
