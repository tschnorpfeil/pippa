import CryptoKit
import Foundation

/// Who actually receives what Pi sends on an online route: the provider's effective configuration and account, not just
/// its Pi id (issue #193). A Pi provider's models.json entry (endpoint, API, headers, key reference) and its auth.json
/// credential, or an older Keychain connection's endpoint, model and key, become one digest. An approval and the online
/// AI's own Pi session are bound to that digest: a new endpoint, key or sign-in is a new recipient with fresh context.
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

    /// A Pi provider (built in or registered in models.json) with its configuration and account as Pi would use them.
    /// Pippa's Pi runs with a fixed environment, so the credential comes only from auth.json or the models.json entry.
    public func fingerprint(_ model: PiModelSelection) -> String? {
        guard let agent = agentDirectory, model.isValid,
              ![PiOnlineProvider.providerKey, PiInstaller.providerKey].contains(model.providerID) else { return nil }
        var parts: [String: Any] = ["kind": "pi", "provider": model.providerID, "model": model.modelID]
        let fm = FileManager.default
        let modelsJSON = agent.appendingPathComponent("models.json")
        if fm.fileExists(atPath: modelsJSON.path) {
            // Present but unreadable (also: comments): Pi might still use an entry Pippa cannot see. Fail closed.
            guard let document = JSONFile.readObject(modelsJSON) else { return nil }
            guard document["providers"] == nil || document["providers"] is [String: Any] else { return nil }
            if let entry = (document["providers"] as? [String: Any])?[model.providerID] { parts["config"] = entry }
        }
        let authJSON = agent.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: authJSON.path) {
            guard let document = JSONFile.readObject(authJSON) else { return nil }
            if let credential = document[model.providerID] {
                guard let account = Self.account(credential) else { return nil }
                parts["account"] = account
            }
        }
        // Neither a configuration nor a credential: Pi could not reach anyone Pippa can name.
        guard parts["config"] != nil || parts["account"] != nil else { return nil }
        return Self.digest(parts)
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

    /// The part of an auth.json credential that names the account. An API key counts whole. A sign-in drops its rotating
    /// tokens when it names its account (`accountId`, `enterpriseUrl`, …); one that names none is bound to the sign-in
    /// itself (its refresh token), so a token refresh counts as a new recipient rather than risking another account.
    static func account(_ value: Any) -> [String: Any]? {
        guard let credential = value as? [String: Any], let type = credential["type"] as? String else { return nil }
        switch type {
        case "api_key":
            guard credential["key"] != nil || credential["env"] != nil else { return nil }
            return credential
        case "oauth":
            var stable = credential
            for volatile in ["access", "refresh", "expires"] { stable.removeValue(forKey: volatile) }
            if stable.count > 1 { return stable }
            guard let refresh = credential["refresh"] as? String, !refresh.isEmpty else { return nil }
            stable["signIn"] = refresh
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
