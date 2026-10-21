import Foundation

/// Closed evidence from Pippa's own folder reader, captured before display-text truncation.
public struct PiFileAccessFailure: Sendable, Equatable {
    public let path: String
    public let code: String

    public static func decode(tool: String, isError: Bool, result: [String: Any]?) -> Self? {
        guard tool == "list_folder", isError,
              let details = result?["details"] as? [String: Any],
              let value = details["pippaFileAccess"] as? [String: Any],
              let schema = value["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let code = value["code"] as? String, ["EACCES", "EPERM"].contains(code),
              let path = value["path"] as? String, path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.contains("\0"), !path.contains(where: \.isNewline) else { return nil }
        return Self(path: path, code: code)
    }
}

// Receipt "what happened" from Pi's tool events, never from the model text: `tool_execution_start` says what was
// called with which arguments; `tool_execution_end` carries execution evidence. An error does not prove that a
// command had no effects. What the model writes about it plays no role.

/// What actually happened with a tool call.
public struct PiActionRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// Executed, tool reports no error.
        case done
        /// The tool reported an error; some effects may already have happened.
        case failed
        /// Authoritative tool evidence says it was stopped before any effect.
        case blocked
        /// Missing/malformed result, interruption, or an explicitly unconfirmed native effect.
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
    public var fileAccessFailure: PiFileAccessFailure? = nil
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
    private var ended: [String: PiActionRecord.Outcome] = [:]
    /// `remember` calls whose forget found nothing (the tool says so in its result, without an error).
    private var forgotNothing: Set<String> = []
    private var fileAccessFailures: [String: PiFileAccessFailure] = [:]
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
        case .toolEnded(let id, let name, let isError, let result, let outcome, let fileAccessFailure):
            if started[id] == nil { order.append(id); started[id] = (name, "") }
            // Older in-process callers have only text. RPC supplies the full result's classification before truncation.
            let state = outcome ?? Self.classify(tool: name, isError: isError, result: ["content": [["type": "text", "text": result]]])
            ended[id] = state
            fileAccessFailures[id] = name == "list_folder" && started[id]?.name == name && isError && state == .failed ? fileAccessFailure : nil
            guard state == .done else { break }
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
            if let failure = fileAccessFailures[id] {
                return PiActionRecord(toolCallId: id, tool: tool, action: "look", outcome: .blocked,
                                      name: URL(fileURLWithPath: failure.path).lastPathComponent, reason: "denied",
                                      fileAccessFailure: failure)
            }
            guard !Self.readOnlyTools.contains(tool), !Self.quietTools.contains(tool) else { return nil }
            let outcome = ended[id] ?? .unclear
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

    // Emitted before an effect by PippaMCPWrite.swift; unknown future statuses stay unconfirmed.
    private static let nativeNoEffect: Set<String> = ["invalid_arguments", "cancelled", "needs_access", "denied", "unavailable", "failed",
        "not_dispatched", "not_checked", "busy", "nothing_selected", "no_message_id", "not_found", "ambiguous", "search_incomplete", "not_created"]

    /// Interpret the complete tool envelope, not display text or answer prose. Called before the RPC preview is cut.
    public static func classify(tool: String, isError: Bool, result: [String: Any]?) -> PiActionRecord.Outcome {
        guard let result, let content = result["content"] as? [[String: Any]],
              content.allSatisfy({ $0["type"] is String && ($0["type"] as? String != "text" || $0["text"] is String) }) else { return .unclear }
        if let own = pippaTool(tool), pippaWriters.contains(own) {
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let data = text.data(using: .utf8), let native = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unclear }
            if ["unclear", "dispatched"].contains(native["state"] as? String ?? "")
                || ["unclear", "dispatched"].contains(native["status"] as? String ?? "") { return .unclear }
            if native.keys.contains("dispatched"), boolean(native["dispatched"]) == nil { return .unclear }
            if boolean(native["done"]) == true, !isError { return .done }
            if boolean(native["done"]) == false, boolean(native["dispatched"]) != true,
               let status = native["status"] as? String, nativeNoEffect.contains(status) { return .blocked }
            return .unclear
        }
        if tool == "bash", let details = result["details"] as? [String: Any] {
            if details["pippaExecution"] as? String == "not_dispatched" { return isError ? .blocked : .unclear }
            if details["pippaExecution"] as? String == "uncertain" { return .unclear }
        }
        return isError ? .failed : .done
    }

    /// JSON numbers such as 1 are not boolean confirmation.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

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
