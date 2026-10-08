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
        case .missingCredential: L("Please add an API key for this service.", table: "Core")
        case .busy: L("I’m still busy with something else. Please try again in a moment.", table: "Core")
        case .credentialStorage: L("The API key couldn’t be saved to or read from the keychain.", table: "Core")
        case .invalidResponse: L("Your connected service didn’t give a valid answer for this task.", table: "Core")
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

public struct InferenceSettings: Codable, Sendable, Equatable {
    public var policy: InferencePolicy
    public var connection: ModelConnection?
    public init(policy: InferencePolicy = .localOnly, connection: ModelConnection? = nil) {
        self.policy = policy; self.connection = connection
    }
    public static func load(from base: URL = Pippa.supportDirectory) -> Self {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("inference-settings.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.policy == .localOnly || value.connection != nil,
              value.connection == nil || (try? value.connection?.validated()) != nil else { return Self() }
        return value
    }
    public func save(to base: URL = Pippa.supportDirectory) throws {
        if let connection { try connection.validated() }
        guard policy == .localOnly || connection != nil else {
            throw InferenceError.invalidConnection(L("Please connect a service first.", table: "Core"))
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
