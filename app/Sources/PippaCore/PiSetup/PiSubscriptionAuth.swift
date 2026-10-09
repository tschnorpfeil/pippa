import Foundation

// Optional cloud AI through the person's ChatGPT subscription, signed in with Pi's own sign-in (runtime/pippa-auth/
// pi-auth.mjs on Pi's public ModelRuntime API): Pi opens its callback on 127.0.0.1 with PKCE and state and keeps the
// credential in its auth.json, as `/login` in the terminal does. Pippa never reads, shows or copies a token; it only asks
// Pi whether a subscription sign-in exists and then starts Pi with `--provider openai`. Local stays the default; turning
// it off goes back to local and leaves the sign-in alone (Pippa and Terminal-Pi share it).

public struct PiSubscriptionAuth: Sendable {
    public static let provider = "openai"

    public struct Status: Sendable, Equatable {
        public var signedIn: Bool
        /// `subscription`, `apiKey` (an API key is not the subscription: not offered here) or `none`.
        public var kind: String
        /// Pi's own default model for the provider (live from the installed Pi).
        public var defaultModel: String?
        public var models: [String]
        public init(signedIn: Bool, kind: String, defaultModel: String?, models: [String]) {
            self.signedIn = signedIn; self.kind = kind; self.defaultModel = defaultModel; self.models = models
        }
    }

    public enum Failure: Error, Equatable {
        /// Pi or Pippa's helper is missing (setup not finished).
        case unavailable
        case cancelled
        /// Another sign-in (or the Codex CLI) holds Pi's callback port.
        case portBusy
        case failed
    }

    public var node: URL
    public var release: URL
    public var helper: URL
    public var environment: [String: String]

    public init(node: URL, release: URL, helper: URL, environment: [String: String]) {
        self.node = node; self.release = release; self.helper = helper; self.environment = environment
    }

    /// Helper in the app bundle (Contents/Resources/pippa-auth) or PIPPA_PI_AUTH (development).
    public static func helperURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let url = environment["PIPPA_PI_AUTH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pippa-auth/pi-auth.mjs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func status() async throws -> Status {
        let lines = try await run(["status"], onLine: { _ in })
        guard let object = lines.last, object["event"] == nil else { throw Failure.unavailable }
        return Self.status(object)
    }

    static func status(_ object: [String: Any]) -> Status {
        Status(signedIn: object["signedIn"] as? Bool ?? false, kind: object["kind"] as? String ?? "none",
               defaultModel: object["defaultModel"] as? String, models: object["models"] as? [String] ?? [])
    }

    /// Pi's browser sign-in. `open` gets the sign-in page (only https on openai.com/chatgpt.com, checked again here).
    /// Cancel by cancelling the task.
    public func signIn(open: @escaping @Sendable (URL) -> Void) async throws -> Status {
        let lines = try await run(["login"], onLine: { line in
            guard line["event"] as? String == "open", let text = line["url"] as? String, let url = URL(string: text),
                  Self.isSignInPage(url) else { return }
            open(url)
        })
        guard let last = lines.last else { throw Failure.failed }
        switch last["event"] as? String {
        case "done": return Self.status(last)
        case "error":
            switch last["code"] as? String {
            case "cancelled": throw Failure.cancelled
            case "port_busy": throw Failure.portBusy
            case "pi_missing": throw Failure.unavailable
            default: throw Failure.failed
            }
        default: throw Failure.failed
        }
    }

    public func signOut() async throws {
        let lines = try await run(["logout"], onLine: { _ in })
        guard lines.last?["done"] as? Bool == true else { throw Failure.failed }
    }

    public static func isSignInPage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com"
    }

    /// Runs the helper, hands every JSON line to `onLine` and returns them all. Cancelling the task ends it (SIGTERM).
    func run(_ arguments: [String], onLine: @escaping @Sendable ([String: Any]) -> Void) async throws -> [[String: Any]] {
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: helper.path) else {
            throw Failure.unavailable
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [helper.path, release.path] + arguments
        process.environment = environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        let collected = LinesBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for line in collected.append(data) { onLine(line) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[[String: Any]], Error>) in
                process.terminationHandler = { _ in
                    output.fileHandleForReading.readabilityHandler = nil
                    let rest = output.fileHandleForReading.readDataToEndOfFile()
                    for line in collected.append(rest + Data([10])) { onLine(line) }
                    continuation.resume(returning: collected.all)
                }
                do { try process.run() } catch { continuation.resume(throwing: Failure.unavailable) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Which Pi error means what for the person (Pi's text stays out of the UI and the log).
    public enum Problem: String, Sendable, Equatable { case signedOut, limit }

    public static func problem(in errorText: String) -> Problem? {
        let text = errorText.lowercased()
        if ["401", "unauthorized", "invalid_grant", "token expired", "refresh token", "not logged in", "no api key", "sign in again"].contains(where: text.contains) {
            return .signedOut
        }
        if ["429", "rate limit", "usage limit", "quota", "too many requests", "limit reached"].contains(where: text.contains) { return .limit }
        return nil
    }
}

private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [[String: Any]] = []
    func append(_ data: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var new: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { new.append(object) }
        }
        lines += new
        return new
    }
    var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return lines }
}

extension PiInstaller {
    /// Sign-in helper for this installation (`nil` until the "Pi" step has run or without the helper).
    public func subscriptionAuth(helper: URL? = PiSubscriptionAuth.helperURL(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> PiSubscriptionAuth? {
        guard let layout = state.layout, let helper else { return nil }
        var env = Self.baseEnvironment(roots)
        env.removeValue(forKey: "PI_OFFLINE")   // the sign-in itself needs the network
        if let agent = environment["PI_CODING_AGENT_DIR"] { env["PI_CODING_AGENT_DIR"] = agent }
        return PiSubscriptionAuth(node: roots.payload.node, release: roots.release(layout), helper: helper, environment: env)
    }
}
