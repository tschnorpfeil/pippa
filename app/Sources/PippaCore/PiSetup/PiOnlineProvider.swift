import Foundation

// The person's own online service (OpenAI, Anthropic, OpenAI-compatible) as Pi provider `pippa-online`: Pi talks to
// the service itself, like any provider in models.json (Pi docs models.md "Configure a compatible endpoint"). Whoever
// switches the service on in Pippa's settings has agreed; there is no extra question per request.
// models.json therefore contains:
//
// - `baseUrl` = the service's address (OpenAI shape ends in `/v1`, Anthropic without it: the SDKs append the rest);
// - `apiKey` = `$PIPPA_ONLINE_KEY`, which Pi resolves from its environment. Pippa reads the key from the Keychain and
//   puts it only into the environment of its own Pi; it is in no file and no argument list;
// - `api` matching the service.
//
// Pi in the terminal: without Pippa's environment the key is empty and Pi aborts before any request ("No API key").
public enum PiOnlineProvider {
    public static let providerKey = "pippa-online"
    /// Environment variable with the key (only in the environment of Pippa's own Pi).
    public static let keyVariable = "PIPPA_ONLINE_KEY"

    /// Pi's API id per service (Pi docs models.md / custom-provider.md).
    public static func api(_ provider: ModelProvider) -> String {
        provider == .anthropic ? "anthropic-messages" : "openai-completions"
    }

    /// The service's address without a trailing slash; Pi's SDKs append `/chat/completions` or `/v1/messages`.
    public static func baseURL(_ connection: ModelConnection) -> String {
        var endpoint = connection.endpoint.absoluteString
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        return endpoint
    }

    /// Path the service's chat endpoint has after `baseURL` (also used by "Test connection").
    public static func chatPath(_ provider: ModelProvider) -> String {
        provider == .anthropic ? "/v1/messages" : "/chat/completions"
    }

    /// Longest response Pi requests (Anthropic requires `max_tokens`).
    public static func maxTokens(_ connection: ModelConnection) -> Int { min(8192, max(1024, connection.contextWindow / 4)) }

    public static func entry(_ connection: ModelConnection) -> [String: Any] {
        ["baseUrl": baseURL(connection), "api": api(connection.provider), "apiKey": "$" + keyVariable,
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
    public static func sync(_ connection: ModelConnection?, modelsJSON url: URL) throws -> Bool {
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
            let entry = entry(connection)
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

    /// Which path applies for Pippa's Pi (RPC path): the online service only if connected and not switched off.
    /// "Ask" and "always" from earlier versions both mean on.
    public static func activeConnection(_ settings: InferenceSettings) -> ModelConnection? {
        guard settings.policy != .localOnly, let connection = settings.connection, (try? connection.validated()) != nil else { return nil }
        return connection
    }
}
