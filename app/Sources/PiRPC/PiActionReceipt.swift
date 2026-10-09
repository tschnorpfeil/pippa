import Foundation

// Receipt "what happened" from Pi's tool events, never from the model text: `tool_execution_start` says what was
// called with which arguments, `tool_execution_end` whether it failed. Pi runs every tool without asking, so there is
// nothing declined. What the model writes about it plays no role.

/// What actually happened with a tool call.
public struct PiActionRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// Executed, tool reports no error.
        case done
        /// The tool failed (or an extension stopped it, e.g. the loop brake).
        case failed
        /// Started, but no result (aborted, Pi exited): whether it happened is unknown.
        case unclear
    }
    public var toolCallId: String
    public var tool: String
    public var action: String
    public var outcome: Outcome
    public var name: String?
    public var toName: String?
}

/// Collects the events of one answer (one `prompt` up to `agent_settled`, including late-delivered messages).
public struct PiTurnReceipt: Sendable {
    /// Tools that only read: no receipt line. `get_search_content` reads what a search or page already brought
    /// (pi-web-access keeps it on this Mac).
    public static let readOnlyTools: Set<String> = ["read", "grep", "find", "ls", "list_folder", "get_search_content"]

    private var order: [String] = []
    private var started: [String: (name: String, arguments: String)] = [:]
    private var ended: [String: Bool] = [:]

    public init() {}

    public mutating func observe(_ event: PiRPCEvent) {
        switch event {
        case .toolStarted(let id, let name, let arguments):
            if started[id] == nil { order.append(id) }
            started[id] = (name, arguments)
        case .toolEnded(let id, let name, let isError, _):
            if started[id] == nil { order.append(id); started[id] = (name, "") }
            ended[id] = isError
        default:
            break
        }
    }

    /// One line per call that is not only reading, in call order.
    public var records: [PiActionRecord] {
        order.compactMap { id in
            let tool = started[id]?.name ?? ""
            guard !Self.readOnlyTools.contains(tool) else { return nil }
            let outcome: PiActionRecord.Outcome = switch ended[id] {
            case .some(true): .failed
            case .some(false): .done
            case .none: .unclear
            }
            // Pippa's own tools (the app's MCP server): a neutral line; what was read or added is filled in by the
            // app from its server's notes (`name` is until then the tool name without prefix).
            if let own = Self.pippaTool(tool) {
                return PiActionRecord(toolCallId: id, tool: tool, action: Self.pippaWriters.contains(own) ? "write" : "read",
                                      outcome: outcome, name: own, toName: nil)
            }
            let (action, name, toName) = Self.fallback(tool: tool, arguments: started[id]?.arguments ?? "")
            return PiActionRecord(toolCallId: id, tool: tool, action: action, outcome: outcome, name: name, toName: toName)
        }
    }

    /// Pippa's writing MCP tools (PippaCore/MCP/PippaMCPWrite.swift).
    public static let pippaWriters: Set<String> = ["calendar_add", "reminder_add", "mail_draft"]

    /// `mcp__pippa__calendar_read` → `calendar_read` (Pippa's MCP server is called `pippa`), otherwise `nil`.
    public static func pippaTool(_ tool: String) -> String? {
        tool.hasPrefix("mcp__pippa__") ? String(tool.dropFirst("mcp__pippa__".count)) : nil
    }

    /// Action and names from the tool call's own arguments.
    static func fallback(tool: String, arguments: String) -> (action: String, name: String?, toName: String?) {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        let path = (args?["path"] ?? args?["from"]) as? String
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "write", "edit": return ("change", name, nil)
        case "rename_or_move": return ("move", name, (args?["to"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
        case "move_files":
            let into = ((args?["groups"] as? [[String: Any]]) ?? []).compactMap { $0["into"] as? String }
            return ("move", (args?["folder"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
                    into.isEmpty ? nil : into.joined(separator: ", "))
        case "move_to_trash": return ("trash", name, nil)
        case "bash", "powershell": return ("command", nil, nil)
        // pi-web-access: exactly what went out, from the call's own arguments (never from the model's text).
        case "web_search":
            let queries = (args?["queries"] as? [String]) ?? (args?["query"] as? String).map { [$0] } ?? []
            return ("webSearch", queries.isEmpty ? nil : queries.joined(separator: " · "), nil)
        case "fetch_content":
            let urls = (args?["urls"] as? [String]) ?? (args?["url"] as? String).map { [$0] } ?? []
            return ("webPage", urls.isEmpty ? nil : urls.joined(separator: " · "), nil)
        default: return ("tool", tool, nil)
        }
    }
}
