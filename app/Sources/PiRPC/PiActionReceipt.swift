import Foundation

// Receipt "what happened" from events, never from the model text. Sources:
// `tool_execution_start`/`_end` from Pi and the `pippa-receipt` entries of the Pippa guard
// (runtime/pippa-guard/pippa-guard.ts, via `pi.appendEntry` → `entry_appended`). The guard knows whether the person
// declined and where the undo entry is; Pi's tool events know whether the tool failed.
// What the model writes about it plays no role.

/// An entry of the guard (schema `v: 1`).
public struct PiGuardOutcome: Sendable, Equatable, Codable {
    public var toolCallId: String
    public var tool: String
    /// "declined", "blocked", "done", "failed"; also "unclear" (mail draft: whether a window is open is unknown)
    public var outcome: String
    /// "create", "overwrite", "change", "rename", "move", "trash", "delete", "look", "command", "tool";
    /// "calendarAdd", "reminderAdd", "mailDraft" (name and state from the MCP server, `reason` e.g. "opened", "busy")
    public var action: String
    public var name: String?
    public var path: String?
    public var toName: String?
    public var to: String?
    /// Folder with `manifest.json` (restore.mjs).
    public var undo: String?
    public var restorable: Bool?
    /// For "blocked": "noUI" or "noUndo".
    public var reason: String?
    public var error: String?
    /// Did the guard ask? (`undo-first` lets file tools run without asking; runtime/pippa-guard/policy.ts)
    public var asked: Bool?
    /// Kind per policy.ts: fileChange, look, command, delete, network, send, tool.
    public var category: String?

    public init(toolCallId: String, tool: String, outcome: String, action: String, name: String? = nil, path: String? = nil,
                toName: String? = nil, to: String? = nil, undo: String? = nil, restorable: Bool? = nil, reason: String? = nil, error: String? = nil,
                asked: Bool? = nil, category: String? = nil) {
        self.toolCallId = toolCallId; self.tool = tool; self.outcome = outcome; self.action = action; self.name = name; self.path = path
        self.toName = toName; self.to = to; self.undo = undo; self.restorable = restorable; self.reason = reason; self.error = error
        self.asked = asked; self.category = category
    }

    /// Session entry type of the guard.
    public static let entryType = "pippa-receipt"
}

/// What actually happened with a mutating tool call.
public struct PiActionRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// Executed, tool reports no error.
        case done
        /// The person chose "Nicht erlauben".
        case declined
        /// The guard prevented it without asking (no UI, no backup copy).
        case blocked
        /// Allowed, but the tool failed.
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
    public var undoEntry: String?
    public var restorable: Bool
    /// For `.blocked`: "noUI" or "noUndo".
    public var reason: String?
    /// The guard asked about it.
    public var asked = false
}

/// Collects the events of one answer (one `prompt` up to `agent_settled`, including late-delivered messages).
public struct PiTurnReceipt: Sendable {
    /// Tools that only read: no receipt line without a guard entry.
    public static let readOnlyTools: Set<String> = ["read", "grep", "find", "ls", "list_folder"]

    private var order: [String] = []
    private var started: [String: (name: String, arguments: String)] = [:]
    private var ended: [String: Bool] = [:]
    private var guards: [String: PiGuardOutcome] = [:]

    public init() {}

    public mutating func observe(_ event: PiRPCEvent) {
        switch event {
        case .toolStarted(let id, let name, let arguments):
            if started[id] == nil { order.append(id) }
            started[id] = (name, arguments)
        case .toolEnded(let id, let name, let isError, _):
            if started[id] == nil { order.append(id); started[id] = (name, "") }
            ended[id] = isError
        case .guardOutcome(let outcome):
            if started[outcome.toolCallId] == nil { order.append(outcome.toolCallId); started[outcome.toolCallId] = (outcome.tool, "") }
            // The last entry counts (a call has at most one; declined/blocked come before, done after the tool).
            guards[outcome.toolCallId] = outcome
        default:
            break
        }
    }

    /// One line per mutating call, in call order. Only reading calls without a guard entry are missing.
    public var records: [PiActionRecord] {
        order.compactMap { id in
            let tool = started[id]?.name ?? ""
            let toolFailed = ended[id]
            if let entry = guards[id] {
                var outcome: PiActionRecord.Outcome = switch entry.outcome {
                case "declined": .declined
                case "blocked": .blocked
                case "failed": .failed
                case "done": .done
                default: .unclear
                }
                // Pi's tool event contradicts the guard ("done" but error): the error wins.
                if outcome == .done, toolFailed == true { outcome = .failed }
                var record = PiActionRecord(toolCallId: id, tool: tool, action: entry.action, outcome: outcome, name: entry.name,
                                            toName: entry.toName, undoEntry: outcome == .done ? entry.undo : nil,
                                            restorable: outcome == .done && entry.restorable == true, reason: entry.reason)
                record.asked = entry.asked ?? (outcome == .declined)
                return record
            }
            guard !Self.readOnlyTools.contains(tool) else { return nil }
            // Pippa's own readers (the app's MCP server): a neutral read line; what was read is filled in by the
            // app from its server's notes (`name` is until then the tool name without prefix).
            if let reader = Self.pippaReader(tool) {
                let outcome: PiActionRecord.Outcome = switch toolFailed { case .some(true): .failed; case .some(false): .done; case .none: .unclear }
                return PiActionRecord(toolCallId: id, tool: tool, action: "read", outcome: outcome, name: reader, toName: nil,
                                      undoEntry: nil, restorable: false, reason: nil)
            }
            // Without a guard entry (foreign extension blocks, guard not loaded): only what Pi itself says.
            let outcome: PiActionRecord.Outcome = switch toolFailed {
            case .some(true): .failed
            case .some(false): .done
            case .none: .unclear
            }
            let (action, name) = Self.fallback(tool: tool, arguments: started[id]?.arguments ?? "")
            return PiActionRecord(toolCallId: id, tool: tool, action: action, outcome: outcome, name: name, toName: nil,
                                  undoEntry: nil, restorable: false, reason: nil)
        }
    }

    /// Pippa's writing MCP tools (PippaCore/MCP/PippaMCPWrite.swift). Their receipt comes from the guard; without
    /// its entry they are not a read line but "Benutzt: …" (what happened is then known only to Pi).
    public static let pippaWriters: Set<String> = ["calendar_add", "reminder_add", "mail_draft"]

    /// `mcp__pippa__calendar_read` → `calendar_read` (Pippa's MCP server is called `pippa`), otherwise `nil`.
    public static func pippaReader(_ tool: String) -> String? {
        guard tool.hasPrefix("mcp__pippa__") else { return nil }
        let name = String(tool.dropFirst("mcp__pippa__".count))
        return pippaWriters.contains(name) ? nil : name
    }

    /// Action and name only from the tool call if the guard reported nothing.
    static func fallback(tool: String, arguments: String) -> (action: String, name: String?) {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        let path = (args?["path"] ?? args?["from"]) as? String
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "write", "edit": return ("change", name)
        case "rename_or_move": return ("move", name)
        case "move_files": return ("move", (args?["folder"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
        case "move_to_trash": return ("trash", name)
        case "bash", "powershell": return ("command", nil)
        default: return ("tool", tool)
        }
    }
}
