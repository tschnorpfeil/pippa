import CryptoKit
import Foundation

/// Who actually receives what Pi sends on an online route: the provider's effective configuration and account, not just
/// its Pi id (issue #193). A Pi provider's models.json entry (endpoint, API, headers, key reference), its cached catalog
/// entry and its auth.json credential, or an older Keychain connection's endpoint, model and key, become one digest.
///
/// Two digests come out (`Identity`). `recipient` binds an approval: it also covers the endpoint Pi derives from the
/// sign-in itself (GitHub Copilot routes each access token to the `proxy-ep` it names), so a renewal that moves the
/// endpoint needs a fresh review. `account` keys the online AI's own Pi session of typed words: the same account keeps
/// its history across such a move; a new endpoint configuration, key or sign-in starts fresh context.
///
/// Only digests leave this type; no key, token or header value is returned, logged or stored. `nil` means the recipient
/// cannot be determined (no credential, an unreadable file, an unknown credential shape), and nothing approved may go out.
public struct PiRecipient: Sendable {
    /// Pi's agent folder (models.json, auth.json). `nil`: unknown, nothing resolves.
    public var agentDirectory: URL?
    /// An older connection's Keychain key, read without a dialog; `nil` when it is missing or locked.
    public var credential: @Sendable (UUID) -> String?

    public init(agentDirectory: URL?, credential: @escaping @Sendable (UUID) -> String? = { _ in nil }) {
        self.agentDirectory = agentDirectory; self.credential = credential
    }

    /// Resolves nothing: for checks and for places that only need the configured name of a destination.
    public static let unresolved = PiRecipient(agentDirectory: nil)

    /// The app's own Pi folder (as PiSession starts Pi) and the Keychain without a dialog.
    public static func live(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PiRecipient {
        let agent = environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? PiPayload.locate(environment: environment).map { PiInstallRoots.forApp(payload: $0, environment: environment).agentDirectory }
        return PiRecipient(agentDirectory: agent) { id in (try? ModelCredentialStore.readWithoutPrompt(id)) ?? nil }
    }

    public struct Identity: Sendable, Equatable {
        /// What an approval is bound to: configuration, account and the endpoint Pi derives from the credential.
        public var recipient: String
        /// What typed history is bound to: the same, without the credential-derived endpoint.
        public var account: String
        public init(recipient: String, account: String) { self.recipient = recipient; self.account = account }
    }

    /// Providers whose requests go to an endpoint Pi derives from the credential (`toAuth` returns a `baseUrl`), as of
    /// the bundled Pi (checked by runtime/pippa-auth/pi-prepare.test.mjs). For any other provider such an endpoint is
    /// unexpected, and the prepared turn sends nothing (`PiRecipientSnapshot.prepare`).
    public static let credentialRoutedProviders: Set<String> = ["github-copilot"]

    /// A Pi provider's recipient digest (`Identity.recipient`).
    public func fingerprint(_ model: PiModelSelection) -> String? { identity(model)?.recipient }

    /// A Pi provider (built in or registered in models.json) with its configuration and account as Pi would use them.
    /// Pippa's Pi runs with a fixed environment, so the credential comes only from auth.json or the models.json entry.
    public func identity(_ model: PiModelSelection) -> Identity? {
        guard let agent = agentDirectory, model.isValid,
              ![PiOnlineProvider.providerKey, PiInstaller.providerKey].contains(model.providerID) else { return nil }
        var parts: [String: Any] = ["kind": "pi", "provider": model.providerID, "model": model.modelID]
        var routing: String?
        let fm = FileManager.default
        let modelsJSON = agent.appendingPathComponent("models.json")
        if fm.fileExists(atPath: modelsJSON.path) {
            // Present but unreadable (also: comments): Pi might still use an entry Pippa cannot see. Fail closed.
            guard let document = JSONFile.readObject(modelsJSON) else { return nil }
            guard document["providers"] == nil || document["providers"] is [String: Any] else { return nil }
            if let entry = (document["providers"] as? [String: Any])?[model.providerID] {
                guard Self.hasStaticRouting(entry) else { return nil }
                parts["config"] = entry
            }
        }
        // Pi also restores dynamic models (including their endpoint and headers) from the provider catalog on disk.
        let catalog = agent.appendingPathComponent("models-store.json")
        if fm.fileExists(atPath: catalog.path) {
            guard let document = JSONFile.readObject(catalog) else { return nil }
            if let entry = document[model.providerID] {
                guard let record = entry as? [String: Any], let models = record["models"] as? [[String: Any]] else { return nil }
                let selected = models.filter { $0["id"] as? String == model.modelID && $0["provider"] as? String == model.providerID }
                guard Self.hasStaticRouting(selected) else { return nil }
                if !selected.isEmpty { parts["catalogModel"] = selected }
            }
        }
        let authJSON = agent.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: authJSON.path) {
            guard let document = JSONFile.readObject(authJSON) else { return nil }
            if let credential = document[model.providerID] {
                guard let account = Self.account(credential) else { return nil }
                parts["account"] = account
                routing = Self.routing(model.providerID, credential)
            }
        }
        // Neither a configuration nor a credential: Pi could not reach anyone Pippa can name.
        guard parts["config"] != nil || parts["account"] != nil, let account = Self.digest(parts) else { return nil }
        guard let routing else { return Identity(recipient: account, account: account) }
        parts["routing"] = routing
        return Self.digest(parts).map { Identity(recipient: $0, account: account) }
    }

    /// What Pi derives the request endpoint from in a credential of a credential-routed provider. GitHub Copilot: the
    /// access token's `proxy-ep` (empty without one; Pi then uses `enterpriseUrl`, part of the account, or its default).
    static func routing(_ provider: String, _ credential: Any) -> String? {
        guard credentialRoutedProviders.contains(provider), let fields = credential as? [String: Any],
              fields["type"] as? String == "oauth" else { return nil }
        let access = fields["access"] as? String ?? ""
        guard let start = access.range(of: "proxy-ep=") else { return "" }
        return String(access[start.upperBound...].prefix { $0 != ";" })
    }

    /// An older Keychain connection (`pippa-online`), with the key read without a dialog.
    public func fingerprint(_ connection: ModelConnection) -> String? {
        credential(connection.id).flatMap { Self.fingerprint(connection, key: $0) }
    }

    /// An older Keychain connection with the key PiSession hands to Pi: endpoint, API, model and key.
    public static func fingerprint(_ connection: ModelConnection, key: String) -> String? {
        guard (try? connection.validated()) != nil, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return digest(["kind": "connection", "id": connection.id.uuidString, "api": PiOnlineProvider.api(connection.provider),
                       "baseUrl": PiOnlineProvider.baseURL(connection), "model": connection.modelID,
                       "contextWindow": connection.contextWindow, "key": key])
    }

    /// Pi can resolve credential and header values at runtime. An expression cannot identify the value Pi will use.
    private static func hasStaticRouting(_ value: Any) -> Bool {
        if let fields = value as? [String: Any] {
            return fields.allSatisfy { name, field in
                switch name {
                case "apiKey", "baseUrl": return (field as? String).map(isLiteral) == true
                case "headers": return (field as? [String: String])?.values.allSatisfy(isLiteral) == true
                default: return hasStaticRouting(field)
                }
            }
        }
        if let items = value as? [Any] { return items.allSatisfy(hasStaticRouting) }
        return true
    }

    private static func isLiteral(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("!") && !text.contains("$")
    }

    /// Marks the refresh token of a credential pinned for one Pi process: `pippa-frozen:` and the token's SHA-256, so a
    /// pinned copy names the same sign-in as the shared credential but holds nothing a provider would accept.
    public static let frozenRefreshPrefix = "pippa-frozen:"

    /// Bind OAuth to an explicit account ID, or to the sign-in itself (its refresh token's digest) if Pi supplies only
    /// workspace metadata. Fields a renewal replaces (tokens, expiry, Copilot's current model list) are not the account.
    static func account(_ value: Any) -> [String: Any]? {
        guard let credential = value as? [String: Any], let type = credential["type"] as? String else { return nil }
        switch type {
        case "api_key":
            guard let key = credential["key"] as? String, isLiteral(key), credential["env"] == nil else { return nil }
            return credential
        case "oauth":
            var stable = credential
            for volatile in ["access", "refresh", "expires", "availableModelIds"] { stable.removeValue(forKey: volatile) }
            if let id = stable["accountId"] as? String, !id.isEmpty { return stable }
            guard let refresh = credential["refresh"] as? String, !refresh.isEmpty else { return nil }
            stable["signIn"] = refresh.hasPrefix(frozenRefreshPrefix) ? String(refresh.dropFirst(frozenRefreshPrefix.count))
                : SHA256.hash(data: Data(refresh.utf8)).map { String(format: "%02x", $0) }.joined()
            return stable
        default:
            return nil
        }
    }

    static func digest(_ parts: [String: Any]) -> String? {
        guard let data = JSONFile.canonical(parts) else { return nil }
        let hash = SHA256.hash(data: Data("pippa-recipient-v1\n".utf8) + data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
