import Foundation

/// A Pi tool call that ended with an error, as Pippa's diagnostics log names it (event `pi-werkzeug`). Pippa's own MCP
/// tools log themselves in the server (`mcp-werkzeug`), so this leaves them out. Only the kind reaches the log, never
/// the result text: `DiagnosticsLog` keeps no contents.
public enum PiToolFailure: String, Sendable, CaseIterable {
    /// Pi has no tool by that name: "Tool web_fetch_content not found".
    case notFound = "not_found"
    /// Pi refused the call before it ran: "Validation failed for tool …".
    case invalidArguments = "invalid_arguments"
    /// Pippa's helps and the person's no: "Not done:", "Not read:", "Tool execution was blocked".
    case blocked
    /// Anything else.
    case other

    /// The kind from the result's own first words. The text is only read, never kept.
    public static func classify(_ result: String) -> PiToolFailure {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Tool "), text.hasSuffix(" not found"), text.count > "Tool  not found".count { return .notFound }
        if text.hasPrefix("Validation failed") { return .invalidArguments }
        if text.hasPrefix("Not done:") || text.hasPrefix("Not read:") || text.hasPrefix("Tool execution was blocked") { return .blocked }
        return .other
    }

    /// The fields of one log line, or `nil`: nothing failed, or Pippa's MCP server logs that tool already.
    public static func fields(tool: String, isError: Bool, result: String) -> [String: String]? {
        guard isError, !tool.hasPrefix("mcp__pippa__") else { return nil }
        return ["name": bareName(tool), "fehler": "true", "art": classify(result).rawValue]
    }

    /// The tool's own name without Pi's MCP prefix ("mcp__pippa__read_document" → "read_document"), at most 60 characters.
    public static func bareName(_ tool: String, limit: Int = 60) -> String {
        var name = tool
        if name.hasPrefix("mcp__"), let end = name.range(of: "__", range: name.index(name.startIndex, offsetBy: 5)..<name.endIndex) {
            name = String(name[end.upperBound...])
        }
        return String(name.prefix(limit))
    }
}
