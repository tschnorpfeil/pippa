import Foundation

public struct PiProvider: Codable, Sendable, Identifiable, Equatable {
    public struct Method: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
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
}

public final class PiProviderClient: @unchecked Sendable {
    public enum Failure: Error { case unavailable, failed, cancelled, portBusy }

    public enum Problem: String, Sendable, Equatable { case signedOut, limit }

    public static func problem(in errorText: String) -> Problem? {
        let text = errorText.lowercased()
        if ["401", "unauthorized", "invalid_grant", "token expired", "refresh token", "not logged in", "no api key", "sign in again"].contains(where: text.contains) {
            return .signedOut
        }
        if ["429", "rate limit", "usage limit", "quota", "too many requests", "limit reached"].contains(where: text.contains) { return .limit }
        return nil
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
    public static func bundled(roots: PiInstallRoots, agentDirectory: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> PiProviderClient? {
        let helper = environment["PIPPA_PI_PROVIDERS"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pippa-auth/pi-providers.mjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { return nil }
        var env = PiInstaller.baseEnvironment(roots)
        env.removeValue(forKey: "PI_OFFLINE")
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
                let deadline = DispatchWorkItem { [state] in state.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + (arguments.first == "login" ? 610 : 45), execute: deadline)
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
                if state.isCancelled { throw Failure.cancelled }
                guard let last else { throw Failure.failed }
                if last.event == "error" {
                    switch last.code {
                    case "cancelled": throw Failure.cancelled
                    case "port_busy": throw Failure.portBusy
                    case "pi_missing": throw Failure.unavailable
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
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func start(_ process: Process, input: Pipe) throws {
        try lock.withLock {
            guard !cancelled, self.process == nil else { throw PiProviderClient.Failure.cancelled }
            self.process = process; self.input = input
            do { try process.run() } catch { self.process = nil; self.input = nil; throw PiProviderClient.Failure.unavailable }
        }
    }
    func respond(id: String, value: String) throws {
        try lock.withLock {
            guard !cancelled, let input, process?.isRunning == true else { throw PiProviderClient.Failure.cancelled }
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "value": value]) + Data([10])
            try input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
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
