import Foundation

public struct PiProvider: Codable, Sendable, Identifiable, Equatable {
    public struct Method: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public struct Model: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public var id: String
    public var name: String
    public var configured: Bool
    public var methods: [Method]
    public var models: [Model]
    /// Pi's own choice for this provider (`pi --provider <id>` without `--model`), when the account lists it.
    public var defaultModel: String?

    public init(id: String, name: String, configured: Bool, methods: [Method], models: [Model], defaultModel: String? = nil) {
        self.id = id; self.name = name; self.configured = configured; self.methods = methods; self.models = models
        self.defaultModel = defaultModel
    }

    /// The model to preselect: the one in use, else Pi's default, else nothing (the person picks).
    public func preselected(_ preferred: String?) -> String {
        if let preferred, models.contains(where: { $0.id == preferred }) { return preferred }
        if let defaultModel, models.contains(where: { $0.id == defaultModel }) { return defaultModel }
        return ""
    }

    /// Presentation order only. Provider capabilities and model lists always come from Pi.
    public static func ordered(_ providers: [Self]) -> [Self] {
        let favorites = ["anthropic", "openai", "google-antigravity", "google", "openrouter", "opencode", "opencode-go", "xai", "openai-codex"]
        return providers.filter { $0.id != "pippa-online" && $0.id != "pippa-local" }.sorted {
            let a = favorites.firstIndex(of: $0.id) ?? favorites.count
            let b = favorites.firstIndex(of: $1.id) ?? favorites.count
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }
}

/// Typed JSONL events: authentication input travels only through stdin, never argv, settings, or logs.
public struct PiProviderEvent: Decodable, Sendable {
    public struct Option: Decodable, Sendable, Identifiable {
        public var id: String
        public var label: String
    }
    public var event: String?
    public var providers: [PiProvider]?
    public var id: String?
    public var type: String?
    public var message: String?
    public var placeholder: String?
    public var options: [Option]?
    public var url: String?
    public var instructions: String?
    public var userCode: String?
    public var verificationUri: String?
    public var code: String?
    /// `prepare`: the endpoint Pi derives from the credential for the turn's requests, `nil` when it uses the model's own.
    public var endpoint: String?
}

/// A failed model turn, sorted into a fixed class: what the chat says and what the log keeps, never the raw text.
public enum ModelFailureClass: String, Sendable, Equatable, CaseIterable {
    case authentication, permission, rateLimited, quotaExhausted, timeout, unavailable, offline, invalidRequest,
         toolsUnsupported, contextTooLarge, unknown
}

public struct ModelFailure: Sendable, Equatable {
    public var failureClass: ModelFailureClass
    /// The HTTP status the error text names on its own (100–599), if any.
    public var httpStatus: Int?
    public init(failureClass: ModelFailureClass, httpStatus: Int? = nil) { self.failureClass = failureClass; self.httpStatus = httpStatus }

    /// The class as one of the problems the chat handles on its own.
    public var problem: PiProviderClient.Problem? {
        switch failureClass {
        case .authentication: .signedOut
        case .rateLimited: .rateLimit
        case .quotaExhausted: .quota
        default: nil
        }
    }
}

public final class PiProviderClient: @unchecked Sendable {
    public enum Failure: Error { case unavailable, failed, cancelled, portBusy, signedOut }

    /// `rateLimit`: too many requests for now, gone within a minute or so (Pi waits and tries again). `quota`: the
    /// account's allowance is used up for hours or days (Pi does not try again).
    public enum Problem: String, Sendable, Equatable { case signedOut, rateLimit, quota }

    /// The sign-in and limit problems the chat handles on their own (Settings button, waiting, Continue).
    public static func problem(in errorText: String) -> Problem? { classify(errorText: errorText).problem }

    /// Sorts an online AI's raw error text into a fixed class, plus its HTTP status when one stands on its own.
    /// Words decide before status codes, in this order: a used-up allowance often comes as 429 too.
    public static func classify(errorText: String) -> ModelFailure {
        let text = errorText.lowercased()
        let codes = statusCodes(in: text)
        func has(_ words: [String], in value: String = text) -> Bool { words.contains(where: value.contains) }
        let failureClass: ModelFailureClass
        if has(["unauthorized", "invalid_grant", "token expired", "refresh token", "not logged in", "no api key", "sign in again",
                "invalid api key", "invalid_api_key", "incorrect api key", "authentication_error"]) || codes.contains(401) {
            failureClass = .authentication
        } else if has(["resource has been exhausted", "resource_exhausted"]) {
            // Google's per-minute "429 Resource has been exhausted (e.g. check quota)." passes on, as Pi retries it.
            failureClass = .rateLimited
        } else if has(["usage limit", "usage_limit", "usagelimit", "quota", "limit reached", "billing", "out of budget",
                       "available balance", "insufficient credits", "payment required"],
                      // OpenAI's per-minute "Rate limit reached for …" is no used-up allowance.
                      in: text.replacingOccurrences(of: "rate limit reached", with: "")) || codes.contains(402) {
            failureClass = .quotaExhausted
        } else if has(["rate limit", "rate_limit", "too many requests"]) || codes.contains(429) {
            failureClass = .rateLimited
        } else if has(["context length", "context_length", "context window", "maximum context", "prompt is too long",
                       "too many tokens", "request too large", "payload too large", "request_too_large"]) || codes.contains(413) {
            failureClass = .contextTooLarge
        } else if has(["does not support tools", "does not support tool", "tools are not supported", "tool use is not supported",
                       "support tool use", "function calling is not supported", "does not support function calling"]) {
            failureClass = .toolsUnsupported
        } else if has(["forbidden", "permission_denied", "permission denied", "access denied", "not allowed to",
                       "unsupported_country", "do not have access", "does not have access"]) || codes.contains(403) {
            failureClass = .permission
        } else if has(["timed out", "timeout", "etimedout", "deadline exceeded", "deadline_exceeded"]) || codes.contains(408) || codes.contains(504) {
            failureClass = .timeout
        } else if has(["enotfound", "getaddrinfo", "enetunreach", "network is unreachable", "not connected to the internet",
                       "internet connection appears to be offline", "eai_again", "fetch failed"]) {
            failureClass = .offline
        } else if has(["overloaded", "service unavailable", "bad gateway", "internal server error", "server_error", "unavailable",
                       "econnrefused", "econnreset", "socket hang up"]) || codes.contains(where: (500...599).contains) {
            failureClass = .unavailable
        } else if has(["invalid_request", "bad request", "model not found", "model_not_found", "unprocessable"])
                    || codes.contains(where: (400...499).contains) {
            failureClass = .invalidRequest
        } else {
            failureClass = .unknown
        }
        return ModelFailure(failureClass: failureClass, httpStatus: codes.first)
    }

    /// Status codes only on their own, never inside a port, address, byte count, model name or request id (as in Pi's
    /// rule): "429 Too Many Requests" and "status code 503" count, "127.0.0.1:8429", "req_42900a", "500 bytes" do not.
    static func statusCodes(in text: String) -> [Int] {
        let pattern = #"(?<![\w.:,/\-#])[1-5]\d\d(?![\w]|[.:,/\-]\d)(?!\s*(?:bytes?|tokens?|files?|ms|kb|mb|gb|seconds?|s\b|%))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { Int(text[$0]) }
        }
    }

    private let node: URL
    private let release: URL
    private let helper: URL
    private let environment: [String: String]
    private let state = ProviderProcessState()

    public init(node: URL, release: URL, helper: URL, environment: [String: String]) {
        self.node = node; self.release = release; self.helper = helper; self.environment = environment
    }

    /// Uses the bundled release even before local model setup. No model download or server is needed for login.
    /// `offline`: no model catalog from the network (an online turn's `prepare`; a due sign-in renewal still runs).
    public static func bundled(roots: PiInstallRoots, agentDirectory: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               helper fallback: URL? = nil, offline: Bool = false) -> PiProviderClient? {
        let helper = environment["PIPPA_PI_PROVIDERS"].map { URL(fileURLWithPath: $0) } ?? fallback
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pippa-auth/pi-providers.mjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { return nil }
        var env = PiInstaller.baseEnvironment(roots)
        if !offline { env.removeValue(forKey: "PI_OFFLINE") }
        env["PI_CODING_AGENT_DIR"] = agentDirectory.path
        return PiProviderClient(node: roots.payload.node, release: roots.payload.release, helper: helper, environment: env)
    }

    public func respond(id: String, value: String) throws {
        try state.respond(id: id, value: value)
    }
    public func cancel() { state.cancel() }

    /// A client represents one operation. Create a new client for the next catalog/login/logout.
    public func run(_ arguments: [String], onEvent: @escaping @Sendable (PiProviderEvent) -> Void = { _ in }) async throws -> PiProviderEvent {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { [self] in
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = node
                process.arguments = [helper.path, release.path] + arguments
                process.environment = environment
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try state.start(process, input: input)
                defer {
                    if process.isRunning {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                    state.finish(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
                }
                // A broken helper cannot keep an operation alive indefinitely.
                let deadline = DispatchWorkItem { [state] in state.cancel(reason: .failed) }
                // `prepare` may wait for Pi's auth.json lock (up to 30 s) and then for a renewal (up to 15 s).
                DispatchQueue.global().asyncAfter(deadline: .now() + (arguments.first == "login" ? 610 : arguments.first == "prepare" ? 60 : 45),
                                                  execute: deadline)
                defer { deadline.cancel() }
                var buffer = Data(), total = 0
                var last: PiProviderEvent?
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    total += chunk.count
                    guard total <= 16 * 1024 * 1024 else { state.cancel(); throw Failure.failed }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard !line.isEmpty else { continue }
                        let event = try JSONDecoder().decode(PiProviderEvent.self, from: line)
                        if event.providers != nil || event.event == "done" || event.event == "error" { last = event }
                        onEvent(event)
                    }
                }
                process.waitUntilExit()
                if let reason = state.stopReason { throw reason }
                guard let last else { throw Failure.failed }
                if last.event == "error" {
                    switch last.code {
                    case "cancelled": throw Failure.cancelled
                    case "port_busy": throw Failure.portBusy
                    case "pi_missing": throw Failure.unavailable
                    case "signed_out": throw Failure.signedOut
                    default: throw Failure.failed
                    }
                }
                guard process.terminationStatus == 0, last.providers != nil || last.event == "done" else { throw Failure.failed }
                return last
            }.value
        } onCancel: { [state] in state.cancel() }
    }
}

private final class ProviderProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var reason: PiProviderClient.Failure?
    var stopReason: PiProviderClient.Failure? { lock.withLock { reason } }
    func start(_ process: Process, input: Pipe) throws {
        try lock.withLock {
            guard reason == nil, self.process == nil else { throw PiProviderClient.Failure.cancelled }
            self.process = process; self.input = input
            do { try process.run() } catch { self.process = nil; self.input = nil; throw PiProviderClient.Failure.unavailable }
        }
    }
    func respond(id: String, value: String) throws {
        try lock.withLock {
            guard reason == nil, let input, process?.isRunning == true else { throw PiProviderClient.Failure.cancelled }
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "value": value]) + Data([10])
            try input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func cancel(reason: PiProviderClient.Failure = .cancelled) {
        lock.withLock {
            guard self.reason == nil else { return }
            self.reason = reason
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            lock.withLock {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func finish() { lock.withLock { process = nil; input = nil } }
}
