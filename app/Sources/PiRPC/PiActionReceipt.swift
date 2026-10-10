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
    /// `nothingMatched`: `remember` had nothing to forget (from the tool's own result).
    public var reason: String? = nil
}

/// Collects the events of one answer (one `prompt` up to `agent_settled`, including late-delivered messages).
public struct PiTurnReceipt: Sendable {
    /// Tools that only read: no receipt line.
    public static let readOnlyTools: Set<String> = ["read", "grep", "find", "ls", "list_folder", "search_files"]
    /// Pippa's own housekeeping without a receipt line. `remember` (pippa-memory.ts) gets one: "Gemerkt: …" is how the
    /// person sees what Pippa keeps about them, from the call's own arguments.
    public static let quietTools: Set<String> = []

    private var order: [String] = []
    private var started: [String: (name: String, arguments: String)] = [:]
    private var ended: [String: Bool] = [:]
    /// `remember` calls whose forget found nothing (the tool says so in its result, without an error).
    private var forgotNothing: Set<String> = []
    /// For the sources card (PippaCore `WebSourcesCard`), never from the model's text: addresses of pages Pi read
    /// (`fetch_content`, from the call's arguments) and the results of searches (`web_search`, the tool's own output).
    public private(set) var webPagesRead: [String] = []
    public private(set) var webSearchResults: [String] = []

    public init() {}

    public mutating func observe(_ event: PiRPCEvent) {
        switch event {
        case .toolStarted(let id, let name, let arguments):
            if started[id] == nil { order.append(id) }
            started[id] = (name, arguments)
        case .toolEnded(let id, let name, let isError, let result):
            if started[id] == nil { order.append(id); started[id] = (name, "") }
            ended[id] = isError
            guard !isError else { break }
            if name == "fetch_content" {
                let args = (try? JSONSerialization.jsonObject(with: Data((started[id]?.arguments ?? "").utf8))) as? [String: Any]
                webPagesRead += (args?["urls"] as? [String]) ?? (args?["url"] as? String).map { [$0] } ?? []
            } else if name == "web_search" {
                webSearchResults.append(result)
            } else if name == "remember", result.contains("Nothing matched to forget") {
                forgotNothing.insert(id)
            }
        default:
            break
        }
    }

    /// One line per call that is not only reading, in call order.
    public var records: [PiActionRecord] {
        order.compactMap { id in
            let tool = started[id]?.name ?? ""
            guard !Self.readOnlyTools.contains(tool), !Self.quietTools.contains(tool) else { return nil }
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
            return PiActionRecord(toolCallId: id, tool: tool, action: action, outcome: outcome, name: name, toName: toName,
                                  reason: forgotNothing.contains(id) ? "nothingMatched" : nil)
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
        case "move_files":
            if let to = args?["to"] as? String, args?["groups"] == nil { return ("move", name, URL(fileURLWithPath: to).lastPathComponent) }
            let into = ((args?["groups"] as? [[String: Any]]) ?? []).compactMap { $0["into"] as? String }
            return ("move", (args?["folder"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
                    into.isEmpty ? nil : into.joined(separator: ", "))
        case "move_to_trash": return ("trash", name, nil)
        case "bash", "powershell": return ("command", nil, nil)
        // Pippa's memory: what was kept (`add`) and what was let go (`forget`), one line each, shortened.
        case "remember":
            func short(_ key: String) -> String? {
                guard let text = args?[key] as? String else { return nil }
                let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return one.isEmpty ? nil : one.count > 120 ? String(one.prefix(119)) + "…" : one
            }
            return ("remember", short("add"), short("forget"))
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
