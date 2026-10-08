import Foundation

// The person's own online service (OpenAI, Anthropic,
// OpenAI-compatible) as Pi provider `pippa-online`. Pi **never** reaches it directly, only via Pippa's loopback
// proxy (`PippaOnlineProxy`), which asks before every request and only then forwards with the key from the Keychain.
// models.json therefore contains:
//
// - `baseUrl` = 127.0.0.1 with Pippa's fixed online port (`PippaSettings.onlinePort`), never the service's address;
// - `apiKey` = `!command`, which prints only the access token **of this app run** from Pippa's environment for its own Pi
//   (`PIPPA_ONLINE_TOKEN`). The service's real key is in no file;
// - `api` matching the service, so the proxy can pass the request on unchanged (streaming included).
//
// Pi in the terminal: without Pippa's environment the key is empty and Pi aborts before any request ("No API key"); without a
// running Pippa nothing listens on the port either. No silent way out.
public enum PiOnlineProvider {
    public static let providerKey = "pippa-online"
    /// Environment variable with the per-app-run access token (only in the environment of Pippa's own Pi).
    public static let tokenVariable = "PIPPA_ONLINE_TOKEN"
    /// Pi 1.0.4 runs `!…` via `/bin/sh -c` (on every request, no cache); empty output = no key.
    public static let apiKeyCommand = "!printf '%s' \"$" + tokenVariable + "\""

    /// Pi's API id per service (Pi docs models.md / custom-provider.md).
    public static func api(_ provider: ModelProvider) -> String {
        provider == .anthropic ? "anthropic-messages" : "openai-completions"
    }

    /// Path Pi appends to `baseUrl`, without the part the proxy strips again. OpenAI SDK: `<baseUrl>/chat/completions`
    /// (baseUrl ends in `/v1`, so does the service address); Anthropic SDK: `<baseUrl>/v1/messages` (address without `/v1`).
    public static func basePath(_ provider: ModelProvider) -> String { provider == .anthropic ? "" : "/v1" }

    /// The only paths (after `basePath`) the proxy forwards. Everything else: 404, nothing goes out.
    public static func allowedPaths(_ provider: ModelProvider) -> Set<String> {
        provider == .anthropic ? ["/v1/messages"] : ["/chat/completions"]
    }

    public static func baseURL(_ provider: ModelProvider, port: Int) -> String {
        "http://127.0.0.1:\(port)" + basePath(provider)
    }

    /// Longest response Pi requests (Anthropic requires `max_tokens`).
    public static func maxTokens(_ connection: ModelConnection) -> Int { min(8192, max(1024, connection.contextWindow / 4)) }

    public static func entry(_ connection: ModelConnection, port: Int) -> [String: Any] {
        ["baseUrl": baseURL(connection.provider, port: port), "api": api(connection.provider), "apiKey": apiKeyCommand,
         "models": [["id": connection.modelID, "name": connection.displayName, "contextWindow": connection.contextWindow,
                     "maxTokens": maxTokens(connection)] as [String: Any]]]
    }

    /// Pi options for Pippa's own Pi when the online service is working (instead of `--provider pippa-local`).
    public static func launchArguments(_ connection: ModelConnection) -> [String] {
        ["--provider", providerKey, "--model", connection.modelID]
    }

    /// Write `pippa-online` into models.json (`connection` set) or remove it (`nil`). Only this one entry;
    /// everything else stays as it is. Atomic via a temp file, permissions of the old file kept. If the file is
    /// not readable JSON, it stays unchanged (error). Returns whether anything changed.
    @discardableResult
    public static func sync(_ connection: ModelConnection?, port: Int, modelsJSON url: URL) throws -> Bool {
        let fm = FileManager.default
        var document: [String: Any] = [:]
        let existed = fm.fileExists(atPath: url.path)
        if existed {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["providers"] == nil || object["providers"] is [String: Any] else {
                throw PiInstallFailure.modelsJSONUnreadable(url.path)
            }
            document = object
        } else if connection == nil {
            return false
        }
        var providers = document["providers"] as? [String: Any] ?? [:]
        if let connection {
            let entry = entry(connection, port: port)
            if let current = providers[providerKey], PiInstaller.canonical(current) == PiInstaller.canonical(entry) { return false }
            providers[providerKey] = entry
        } else {
            guard providers[providerKey] != nil else { return false }
            providers.removeValue(forKey: providerKey)
        }
        document["providers"] = providers
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".models.json.pippa-\(UUID().uuidString)")
        try (data + Data("\n".utf8)).write(to: temporary)
        let mode = existed ? ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600) : 0o600
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
        return true
    }

    /// The entry as it currently stands in models.json (for checks).
    public static func current(modelsJSON: URL) -> [String: Any]? {
        let providers = (try? Data(contentsOf: modelsJSON))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["providers"] as? [String: Any]
        return providers?[providerKey] as? [String: Any]
    }

    /// Fixed proxy port: chosen freely once, then remembered in Pippa's settings.json (like `PiInstaller.stablePort`).
    /// `avoid`: a port that could not be bound (then a new one).
    public static func stablePort(support: URL, avoid: Int? = nil) -> Int {
        var settings = PippaSettings.load(from: support)
        if let port = settings.onlinePort, port != avoid { return port }
        var port = LlamaServer.freePort()
        if port == settings.llamaPort || port == avoid { port = LlamaServer.freePort() }
        settings.onlinePort = port
        try? settings.save(to: support)
        return port
    }

    /// Which path applies for Pippa's Pi (RPC path): the online service only if connected and not switched off.
    /// "Always" from the old path counts as "ask" here: Pippa asks before every request that leaves the Mac.
    public static func activeConnection(_ settings: InferenceSettings) -> ModelConnection? {
        guard settings.policy != .localOnly, let connection = settings.connection, (try? connection.validated()) != nil else { return nil }
        return connection
    }
}
