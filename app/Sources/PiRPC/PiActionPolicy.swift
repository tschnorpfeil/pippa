import Foundation

/// App-selected authority for one Pi process. Content cannot widen it; switch processes when it changes.
public enum PiActionPolicy: String, Sendable, Equatable {
    case standard
    /// Read local context and return text to Pippa; no tool writes, shell execution or web lookup tools.
    case draftOnly

    public static let environmentVariable = "PIPPA_ACTION_POLICY"
    public static let command = "pippa-action-policy"
    public static let nativeReaders = ["calendar_read", "reminders_read", "mail_selected", "mail_search", "excel_selection",
                                       "photos_search", "front_read", "read_document"].map { "mcp__pippa__" + $0 }
    /// MCP exposure hides non-readers while the namespace allowlist retains all native registrations.
    public static let draftLaunchTools = ["read", "search_files", "list_folder", "mcp__pippa__*"]
    public static let draftTools = ["read", "search_files", "list_folder"] + nativeReaders

    static func validate(_ text: String, nonce: String, expected: Self) throws {
        struct Receipt: Decodable { let v: Int; let nonce: String; let status: String; let policy: String; let tools: [String] }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(text.utf8)),
              receipt.v == 1, receipt.nonce == nonce, receipt.status == "ready", receipt.policy == expected.rawValue else {
            throw PiNativeReadiness.Failure.invalidReceipt
        }
        if expected == .draftOnly, Set(receipt.tools) != Set(draftTools) { throw PiNativeReadiness.Failure.invalidReceipt }
    }
}
