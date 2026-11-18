import Foundation
import LocalAuthentication
import Security

public enum InferencePolicy: String, Codable, Sendable, CaseIterable {
    case localOnly, ask, customAlways
}

public enum ModelProvider: String, Codable, Sendable, CaseIterable {
    case openAI = "openai"
    case anthropic
    case compatible = "openai-compatible"

    public var displayName: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .compatible: L("Custom Server", table: "Core") }
    }
    public var defaultEndpoint: URL {
        URL(string: self == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1")!
    }
}

public enum InferenceError: LocalizedError {
    case invalidConnection(String), missingCredential, busy, credentialStorage(OSStatus), invalidResponse
    /// The person said "No" to the request to their online service (name of the service).
    case onlineDeclined(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection(let reason): reason
        case .missingCredential: L("Please add an API key for this online AI.", table: "Core")
        case .busy: L("I’m still busy with something else. Please try again in a moment.", table: "Core")
        case .credentialStorage: L("The API key couldn’t be saved to or read from the keychain.", table: "Core")
        case .invalidResponse: L("Your connected AI didn’t give a valid answer for this task.", table: "Core")
        case .onlineDeclined(let service): L("I didn’t ask %@. Nothing left your Mac.", table: "Core", service)
        }
    }
}

public struct ModelConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var provider: ModelProvider
    public var endpoint: URL
    public var modelID: String
    public var contextWindow: Int
    public init(id: UUID = UUID(), provider: ModelProvider = .openAI, endpoint: URL? = nil, modelID: String = "", contextWindow: Int = 32768) {
        self.id = id; self.provider = provider; self.endpoint = endpoint ?? provider.defaultEndpoint
        self.modelID = modelID; self.contextWindow = contextWindow
    }
    /// Never infer locality from a provider name, private LAN address, or a DNS suffix.
    public var isLocal: Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    public var destination: String { endpoint.host ?? endpoint.absoluteString }
    public var displayName: String { "\(provider.displayName) · \(modelID)" }
    @discardableResult public func validated() throws -> Self {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && isLocal && provider == .compatible),
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw InferenceError.invalidConnection(L("Please enter a secure address (starting with https://) or an address on this Mac, without a user name or password in it.", table: "Core"))
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modelID.utf8.count <= 256,
              !modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InferenceError.invalidConnection(L("Please enter a valid model ID.", table: "Core"))
        }
        guard (4096...1048576).contains(contextWindow) else {
            throw InferenceError.invalidConnection(L("The context size must be between 4,096 and 1,048,576.", table: "Core"))
        }
        return self
    }
}

/// Only routing metadata. Credentials and provider behavior belong to Pi.
public struct PiModelSelection: Codable, Sendable, Equatable {
    public var providerID: String
    public var modelID: String
    public var providerName: String
    /// The model's name as the provider lists it ("GPT-6.1 Terra"); `nil` for selections saved before it was kept.
    public var modelName: String?
    public init(providerID: String, modelID: String, providerName: String, modelName: String? = nil) {
        self.providerID = providerID; self.modelID = modelID; self.providerName = providerName; self.modelName = modelName
    }
    /// What people see: the model's name, its ID only when there is no name.
    public var modelDisplayName: String {
        guard let name = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return modelID }
        return name
    }
    public var isValid: Bool {
        [providerID, modelID, providerName].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }
    public var launchArguments: [String] { ["--provider", providerID, "--model", modelID] }
}

/// Settings → AI: the bundled optional capabilities Pi loads, chosen separately for the AI on this Mac and for the online
/// AI (a Pi provider or an older Keychain connection). Missing values, as in settings saved before this choice existed,
/// mean on, so existing installations keep what they had.
public struct OptionalCapabilities: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        /// Web search and reading pages (pi-web-access).
        public var web: Bool
        /// Personal notes: the `remember` tool and the notes in each new conversation's prompt. Off keeps the notes file.
        public var memory: Bool
        public init(web: Bool = true, memory: Bool = true) { self.web = web; self.memory = memory }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            web = try values.decodeIfPresent(Bool.self, forKey: .web) ?? true
            memory = try values.decodeIfPresent(Bool.self, forKey: .memory) ?? true
        }
    }
    public var local: Choice
    public var online: Choice
    public init(local: Choice = Choice(), online: Choice = Choice()) { self.local = local; self.online = online }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        local = try values.decodeIfPresent(Choice.self, forKey: .local) ?? Choice()
        online = try values.decodeIfPresent(Choice.self, forKey: .online) ?? Choice()
    }
    public subscript(online isOnline: Bool) -> Choice {
        get { isOnline ? online : local }
        set { if isOnline { online = newValue } else { local = newValue } }
    }
}

public struct InferenceSettings: Codable, Sendable, Equatable {
    public var policy: InferencePolicy
    public var connection: ModelConnection?
    /// Legacy ChatGPT setting: the model Pi uses with `--provider openai`. `nil` = off.
    /// Takes precedence over `connection` for Pippa's Pi; local stays the default.
    public var subscriptionModel: String?
    public var piModel: PiModelSelection?
    /// Existing ChatGPT selections keep working without copying or changing their credentials.
    public var activePiModel: PiModelSelection? {
        piModel ?? subscriptionModel.map { PiModelSelection(providerID: "openai", modelID: $0, providerName: "ChatGPT") }
    }
    public var usesOnlineAI: Bool { activePiModel != nil || PiOnlineProvider.activeConnection(self) != nil }
    public var capabilities: OptionalCapabilities
    /// What may go to an online AI after the person's review, per source (Settings → AI → Sharing). Missing: "Ask".
    public var sharing: SourceSharing
    /// The online AI a single question can go to ("Ask OpenAI…") while conversations stay on this Mac. Remembered when the
    /// person switches back to this Mac; it is an address, not a permission: every message to it is reviewed first.
    public var handoffModel: PiModelSelection?
    /// The same for an older Keychain connection that was the online AI: its id, valid only while `connection` is still
    /// that connection. Set by `onThisMac()`; at most one of the two is set.
    public var handoffConnection: UUID?
    /// Settings → AI → "Allow Mac access" (issue #196): the one online AI the person allowed the same Mac tools as the AI
    /// on this Mac, as it was verified when they turned it on. Missing: none, also for settings saved before.
    public var macAccess: ShareDestination?
    public init(policy: InferencePolicy = .localOnly, connection: ModelConnection? = nil, subscriptionModel: String? = nil,
                piModel: PiModelSelection? = nil, capabilities: OptionalCapabilities = OptionalCapabilities(),
                sharing: SourceSharing = SourceSharing(), handoffModel: PiModelSelection? = nil, handoffConnection: UUID? = nil,
                macAccess: ShareDestination? = nil) {
        self.policy = policy; self.connection = connection; self.subscriptionModel = subscriptionModel
        self.piModel = piModel; self.capabilities = capabilities; self.sharing = sharing; self.handoffModel = handoffModel
        self.handoffConnection = handoffConnection; self.macAccess = macAccess
    }
    enum CodingKeys: String, CodingKey {
        case policy, connection, subscriptionModel, piModel, capabilities, sharing, handoffModel, handoffConnection, macAccess
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        policy = try values.decode(InferencePolicy.self, forKey: .policy)
        connection = try values.decodeIfPresent(ModelConnection.self, forKey: .connection)
        subscriptionModel = try values.decodeIfPresent(String.self, forKey: .subscriptionModel)
        piModel = try values.decodeIfPresent(PiModelSelection.self, forKey: .piModel)
        capabilities = try values.decodeIfPresent(OptionalCapabilities.self, forKey: .capabilities) ?? OptionalCapabilities()
        sharing = try values.decodeIfPresent(SourceSharing.self, forKey: .sharing) ?? SourceSharing()
        handoffModel = try values.decodeIfPresent(PiModelSelection.self, forKey: .handoffModel)
        handoffConnection = try values.decodeIfPresent(UUID.self, forKey: .handoffConnection)
        macAccess = try values.decodeIfPresent(ShareDestination.self, forKey: .macAccess)
    }

    /// Whether `destination` has the person's Mac access: only a verified recipient, and only while its configuration,
    /// endpoint and account are exactly the ones they allowed. Never inferred from a provider's name or address.
    public func allowsMacAccess(_ destination: ShareDestination?) -> Bool {
        guard let destination, destination.isVerified, let allowed = macAccess else { return false }
        return allowed.key == destination.key && allowed.recipient == destination.recipient
    }
    /// "Use this Mac": conversations stay here; the online AI used until now stays the recipient for single questions.
    public func onThisMac() -> Self {
        var saved = self
        if let model = activePiModel {
            saved.handoffModel = model; saved.handoffConnection = nil
        } else if let connection = PiOnlineProvider.activeConnection(self) {
            saved.handoffConnection = connection.id; saved.handoffModel = nil
        }
        saved.piModel = nil; saved.subscriptionModel = nil; saved.policy = .localOnly
        return saved
    }

    /// The older Keychain connection single questions go to, while it is still saved, valid and the remembered one.
    public var handoffLegacyConnection: ModelConnection? {
        guard handoffModel == nil, let id = handoffConnection, let connection, connection.id == id,
              (try? connection.validated()) != nil else { return nil }
        return connection
    }

    /// "Remove" under single questions: no recipient for single questions, neither a provider nor a connection.
    public func withoutHandoff() -> Self {
        var saved = self
        saved.handoffModel = nil; saved.handoffConnection = nil
        return saved
    }

    /// Signing out of a provider also forgets it as the recipient for single questions.
    public func disconnected(provider: String) -> Self {
        var saved = self
        if activePiModel?.providerID == provider { saved.piModel = nil; saved.subscriptionModel = nil; saved.policy = .localOnly }
        if handoffModel?.providerID == provider { saved.handoffModel = nil }
        if saved.macAccess?.key.hasPrefix("pi|\(provider)|") == true { saved.macAccess = nil }
        return saved
    }

    public static func load(from base: URL = Pippa.supportDirectory) -> Self {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("inference-settings.json")) else { return Self() }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { UserMessage.record(error, context: "inference-settings-load"); return Self() }
        guard value.policy == .localOnly || value.connection != nil,
              value.connection == nil || (try? value.connection?.validated()) != nil,
              value.activePiModel?.isValid != false, value.handoffModel?.isValid != false else {
            DiagnosticsLog.shared.event("inference-settings-ungueltig")
            return Self()
        }
        return value
    }
    public func save(to base: URL = Pippa.supportDirectory) throws {
        guard activePiModel?.isValid != false, handoffModel?.isValid != false else { throw InferenceError.invalidResponse }
        if let connection { try connection.validated() }
        guard policy == .localOnly || connection != nil else {
            throw InferenceError.invalidConnection(L("Please connect an online AI first.", table: "Core"))
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: base.appendingPathComponent("inference-settings.json"), options: .atomic)
    }
}

/// API secrets live only in the application's Keychain entry, never settings or argv. `service` other than the default
/// only for checks (a clearly test-only service name, deleted afterwards).
public enum ModelCredentialStore {
    public static let defaultService = "de.pippa.model-credentials"
    private static func query(_ id: UUID, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    /// Metadata only; does not retrieve a secret or present an authentication dialog.
    public static func contains(_ id: UUID, service: String = defaultService) throws -> Bool {
        var request = query(id, service: service)
        request[kSecReturnData as String] = false
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show a dialog: an entry that would need approval counts as present-but-locked (error).
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw InferenceError.credentialStorage(status) }
        return true
    }
    public static func read(_ id: UUID, service: String = defaultService) throws -> String? {
        var request = query(id, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw InferenceError.credentialStorage(status)
        }
        return value
    }
    /// Like `read`, but never shows a dialog: a key that would need the person's approval counts as unavailable (`nil`).
    public static func readWithoutPrompt(_ id: UUID, service: String = defaultService) throws -> String? {
        var request = query(id, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw InferenceError.credentialStorage(status)
        }
        return value
    }
    public static func save(_ value: String, for id: UUID, service: String = defaultService) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InferenceError.missingCredential }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(id, service: service) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id, service: service)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw InferenceError.credentialStorage(added) }
        } else if status != errSecSuccess { throw InferenceError.credentialStorage(status) }
    }
    public static func delete(_ id: UUID, service: String = defaultService) throws {
        let status = SecItemDelete(query(id, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw InferenceError.credentialStorage(status) }
    }
}
