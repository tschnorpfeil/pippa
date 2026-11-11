import Foundation
import Darwin
import CoreFoundation

// Pippa drives the real Pi via `pi --mode rpc`. Protocol: JSONL on stdin/stdout,
// see the Pi docs rpc.md, rpc-commands.md, rpc-extension-ui.md.
// Deliberately no dependency on PippaCore, so the probe program builds fast.

/// Drives a `pi --mode rpc` process. One response at a time; deliver more via `steer`.
public actor PiRPCClient {
    /// Tested range: the pinned minor version (app/Packaging/pi-release, currently Pi 1.5.x). `start()` rejects other versions
    /// with `.versionMismatch`. scripts/bump-pi.sh aborts if that does not match the new pin.
    public static let supportedVersionPrefix = "1.5."
    public nonisolated let configuration: PiRPCConfiguration
    private var generation = UUID()
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [String: CheckedContinuation<Response, Error>] = [:]
    private var events: AsyncThrowingStream<PiRPCEvent, Error>.Continuation?
    private var uiHandler: PiUIHandler?
    private var stderrTail = Buffer(limit: 16 * 1024)
    /// The version `start()` found.
    public private(set) var version: String?
    private var nextID = 0
    /// How many user messages have arrived in the current run: the first is the prompt itself, each further one delivered later.
    private var userMessagesInRun = 0
    /// Pi compacts a long session between answers. Pi refuses a prompt meanwhile.
    private var compacting = false
    private var nativeReadinessAttempt: UUID?

    struct Response: Sendable { let success: Bool; let error: String?; let data: Data? }

    public init(configuration: PiRPCConfiguration) { self.configuration = configuration }

    public func setUIHandler(_ handler: PiUIHandler?) { uiHandler = handler }
    public var isRunning: Bool { process?.isRunning == true }
    public var isAnswering: Bool { events != nil }

    // MARK: Process

    /// Check the version and start Pi. Calling it repeatedly is harmless.
    public func start() async throws {
        if process?.isRunning == true { return }
        let waiting = pending.values; pending.removeAll()
        pendingTimers.values.forEach { $0.cancel() }; pendingTimers.removeAll()
        for continuation in waiting { continuation.resume(throwing: PiRPCError.notRunning) }
        finish(PiRPCError.notRunning)
        let generation = UUID(); self.generation = generation
        version = try Self.checkedVersion(configuration)
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
        let tail = Buffer(limit: 16 * 1024)
        stderrTail = tail
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
        Task { [weak self] in for await item in lines { await self?.handle(item, generation: generation) } }
    }

    /// Close stdin (orderly shutdown per rpc.md), kill hard after two seconds.
    public func shutdown() async {
        guard let child = process else { return }
        try? stdin?.close()
        for _ in 0..<20 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning { child.terminate() }
        for _ in 0..<5 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning, kill(child.processIdentifier, 0) == 0 { kill(child.processIdentifier, SIGKILL) }
    }

    // Startup admission has its own cancellation path: an unanswered command must not retain its continuation.
    func beginNativeReadiness() throws -> UUID {
        guard nativeReadinessAttempt == nil, events == nil else { throw PiRPCError.busy }
        let attempt = UUID()
        nativeReadinessAttempt = attempt
        return attempt
    }

    func finishNativeReadiness(_ attempt: UUID) {
        if nativeReadinessAttempt == attempt { nativeReadinessAttempt = nil }
    }

    func rejectNativeReadiness(_ attempt: UUID, error: PiNativeReadiness.Failure) {
        guard nativeReadinessAttempt == attempt else { return }
        nativeReadinessAttempt = nil
        let waiting = pending.values; pending.removeAll()
        pendingTimers.values.forEach { $0.cancel() }; pendingTimers.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
        finish(error)
        try? stdin?.close(); stdin = nil
        if process?.isRunning == true { process?.terminate() }
    }

    /// Stop during startup must end discovery even before a user prompt has been submitted.
    public func cancelNativeReadiness() {
        if let attempt = nativeReadinessAttempt { rejectNativeReadiness(attempt, error: .cancelled) }
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
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.finish(CancellationError()) }
            }
        }
        events = continuation
        userMessagesInRun = 0
        do {
            // The person comes first: stop a quiet summary (Pi keeps the conversation as it was) and ask right away.
            // Also when the summary started just before the prompt reached Pi (`Self.isCompactionBusy`).
            if compacting { try await abort() }
            var response: Response
            do {
                response = try await send(["type": "prompt", "message": text])
            } catch let error as PiRPCError where Self.isCompactionBusy(error) {
                try await abort()
                response = try await send(["type": "prompt", "message": text])
            }
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

    /// Abort; Pi replies only once the session is idle again.
    public func abort(timeout: Duration = .seconds(3)) async throws {
        _ = try await send(["type": "abort"], timeout: timeout)
    }

    /// Arbitrary command, for trial runs (`get_state`, `get_session_stats`, …). Returns `data` as JSON.
    public func command(_ payload: [String: any Sendable], timeout: Duration? = nil) async throws -> Data? {
        try await send(payload, timeout: timeout).data
    }
    private func send(_ payload: [String: any Sendable], timeout: Duration? = nil) async throws -> Response {
        guard let stdin, process?.isRunning == true else { throw PiRPCError.notRunning }
        nextID += 1
        let id = "pippa-\(nextID)"
        var command: [String: Any] = payload
        command["id"] = id
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(10)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                pending[id] = continuation
                pendingTimers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout ?? .seconds(300)) } catch { return }
                    await self?.cancelPending(id, error: PiRPCError.commandFailed(command: payload["type"] as? String ?? "?", message: "Command timed out"))
                }
                do { try stdin.write(contentsOf: data) } catch { cancelPending(id, error: error) }
            }
        } onCancel: { Task { await self.cancelPending(id, error: CancellationError()) } }
        guard response.success else {
            throw PiRPCError.commandFailed(command: payload["type"] as? String ?? "?", message: response.error ?? "")
        }
        return response
    }

    private var pendingTimers: [String: Task<Void, Never>] = [:]
    private func cancelPending(_ id: String, error: Error) {
        pendingTimers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? stdin.write(contentsOf: data)
    }

    // MARK: Input

    enum Incoming: Sendable { case line(Data), exited(Int32) }

    private func handle(_ item: Incoming, generation: UUID) {
        guard self.generation == generation else { return }
        switch item {
        case .exited(let status):
            let error = PiRPCError.processExited(status: status, diagnostics: stderrTail.text)
            let waiting = pending.values; pending.removeAll()
            pendingTimers.values.forEach { $0.cancel() }; pendingTimers.removeAll()
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
            pendingTimers.removeValue(forKey: id)?.cancel()
            let data = record["data"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            continuation.resume(returning: Response(success: record["success"] as? Bool == true, error: record["error"] as? String, data: data))
        case "message_update":
            guard let update = record["assistantMessageEvent"] as? [String: Any], let delta = update["delta"] as? String else { return }
            switch update["type"] as? String {
            case "text_delta": events?.yield(.textDelta(delta))
            case "thinking_delta": events?.yield(.thinkingDelta(delta))
            default: break
            }
        case "message_start":
            guard let message = record["message"] as? [String: Any], message["role"] as? String == "user" else { return }
            userMessagesInRun += 1
            if userMessagesInRun > 1 { events?.yield(.userMessage(Self.text(of: message))) }
        case "message_end":
            guard let message = record["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            events?.yield(.assistantEnded(text: Self.text(of: message), stopReason: message["stopReason"] as? String ?? "",
                                          error: message["errorMessage"] as? String))
        case "tool_execution_start":
            let name = record["toolName"] as? String ?? ""
            events?.yield(.toolStarted(id: record["toolCallId"] as? String ?? "", name: name,
                                       arguments: Self.json(record["args"], valueLimit: Self.argumentValueLimit)))
        case "tool_execution_update":
            // Only Pippa's own progress (a long document read part by part); bash's partial output needs no display.
            guard let details = (record["partialResult"] as? [String: Any])?["details"] as? [String: Any],
                  let progress = details["pippaProgress"] as? [String: Any],
                  let part = progress["part"] as? Int, let of = progress["of"] as? Int, part >= 1, of >= part else { return }
            events?.yield(.toolProgress(id: record["toolCallId"] as? String ?? "", part: part, of: of,
                                        merging: progress["phase"] as? String == "merge"))
        case "tool_execution_end":
            let payload = record["result"] as? [String: Any]
            let flag = record["isError"] as? NSNumber
            let validFlag = flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
            let validResult = payload?["content"] is [[String: Any]] && validFlag
            let isError = validResult ? flag?.boolValue == true : true
            let result = payload.map { Self.text(of: $0) } ?? ""
            let name = record["toolName"] as? String ?? ""
            // Pi's own `read` in full (up to 200,000 characters; Pi itself returns at most 50 KB per call): the
            // source check checks against exactly what Pi read (PiReadLedger). Everything else only the beginning.
            // Searches and listings: enough to count result lines for the everyday step summary ("3 matches").
            // Pippa's own readers and fetched pages likewise: the answer's dates are checked against them (DateEvidence).
            let whole = name == "read" || name == "fetch_content" || name.hasPrefix("mcp__pippa__")
            let limit = whole ? Self.readResultLimit : Self.listingTools.contains(name) ? Self.listingResultLimit : Self.resultLimit
            if !isError, let digest = (payload?["details"] as? [String: Any])?["pippaDigest"] as? [String: Any],
               let notes = digest["notes"] as? String, notes.hasPrefix("/") {
                events?.yield(.toolNotes(id: record["toolCallId"] as? String ?? "", path: notes))
            }
            events?.yield(.toolEnded(id: record["toolCallId"] as? String ?? "", name: name,
                                     isError: isError, result: String(result.prefix(limit)),
                                     outcome: PiTurnReceipt.classify(tool: name, isError: isError, result: validResult ? payload : nil),
                                     fileAccessFailure: PiFileAccessFailure.decode(tool: name, isError: isError, result: validResult ? payload : nil)))
        case "entry_appended":
            if let entry = record["entry"] as? [String: Any], entry["type"] as? String == "custom",
               let kind = entry["customType"] as? String, ["pippa-loop-stop", "pippa-search-result", "pippa-listed-files", "pippa-change", PiNativeReadiness.command].contains(kind), let data = entry["data"],
               let json = try? JSONSerialization.data(withJSONObject: data) {
                events?.yield(.notice(String(decoding: json, as: UTF8.self), kind: kind))
            }
        case "compaction_start":
            compacting = true
        case "compaction_end":
            compacting = false
        case "agent_settled":
            events?.yield(.settled(aborted: record["aborted"] as? Bool == true))
            finish(nil)
        case "extension_ui_request":
            uiRequest(record)
        default:
            break
        }
    }
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
}
