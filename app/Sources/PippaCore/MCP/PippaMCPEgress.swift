import Foundation

/// The app's MCP server for an online AI's Pi process (issue #193): which of Pippa's tools that process may list and call.
/// Readers never: what an online AI gets from Mail, Calendar, Reminders, Photos or documents is only the text the person
/// approved in the review. Writers only for sources on "Ask before sharing", and their results carry back only what the
/// model itself sent (no calendar conflicts, no list names, no reply to a mail it never saw). `browse` only with web access.
/// Set per Pi process on the host the server is started with (`PippaMCPHost.egress`), checked on every request.
public struct PippaMCPEgress: Sendable, Equatable {
    public var rules: SourceSharing
    public var web: Bool

    public init(rules: SourceSharing, web: Bool) { self.rules = rules; self.web = web }

    /// The tools this process may use, in the server's order (also what `--tools` names).
    public var tools: [String] {
        var allowed: [String] = []
        if rules.calendar == .ask { allowed.append("calendar_add") }
        if rules.reminders == .ask { allowed.append("reminder_add") }
        if rules.mail == .ask { allowed.append("mail_draft") }
        if web { allowed.append(PippaMCPBrowserTool.name) }
        return allowed
    }

    public func allows(_ tool: String) -> Bool { tools.contains(tool) }

    /// The arguments an online AI may not use: replying needs the original mail, `if_free` reads the calendar.
    func refusal(_ tool: String, _ arguments: [String: Any]) -> String? {
        if !allows(tool) { return "stays_on_mac" }
        if tool == "mail_draft", arguments["reply_to"] != nil { return "reply_needs_mail" }
        if tool == "calendar_add", arguments["if_free"] as? Bool == true { return "needs_calendar" }
        return nil
    }

    /// A refused call, for the model: what to tell the person and the safe way that remains.
    func refused(_ tool: String, reason: String) -> PippaMCPToolResult {
        let tell: String = switch reason {
        case "reply_needs_mail":
            L("The online AI can’t open your emails. Pippa saves a new draft instead, or the AI on this Mac can reply in the thread.", table: "MCP")
        case "needs_calendar":
            L("The online AI can’t look into your calendar. Ask the AI on this Mac, or share the days with + first.", table: "MCP")
        default:
            L("This stays on this Mac while you use an online AI. Add what’s needed with + to check it before it’s sent, or ask the AI on this Mac.", table: "MCP")
        }
        let next = reason == "reply_needs_mail"
            ? "Nothing was created. Offer a new draft with subject and to instead, or repeat the sentence in tell."
            : "Nothing was read or changed. Repeat the sentence in tell. Do not try another tool for it."
        return PippaMCPToolResult(text: PippaMCPTools.json(["done": false, "read": false, "status": reason, "tell": tell, "next": next]),
                                  isError: true)
    }

    /// What a writer's result may carry back: the model's own values and whether it worked, nothing read on this Mac.
    func scrub(_ tool: String, _ result: PippaMCPToolResult) -> PippaMCPToolResult {
        guard tool != PippaMCPBrowserTool.name,
              var object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] else { return result }
        var changed = false
        func strip(_ keys: [String], in dictionary: inout [String: Any]) {
            for key in keys where dictionary[key] != nil { dictionary[key] = nil; changed = true }
        }
        strip(["conflicts", "untrusted", "rule"], in: &object)
        if var added = object["added"] as? [String: Any] {
            strip(["conflicts", "conflicts_unknown", "calendar", "list", "listNote"], in: &added)
            object["added"] = added
        }
        // The instruction may not point at what was withheld.
        if changed, tool == "calendar_add", object["done"] as? Bool == true {
            object["next"] = "Say in one sentence that it is in the calendar, with day and time as in when."
        }
        guard changed else { return result }
        var scrubbed = result
        scrubbed.text = PippaMCPTools.json(object)
        return scrubbed
    }
}
