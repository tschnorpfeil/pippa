import Foundation

/// The app's MCP server for an online AI's Pi process (issue #193): which of Pippa's tools that process may list and call.
/// Readers never: what an online AI gets from Mail, Calendar, Reminders, Photos or documents is only the text the person
/// approved in the review. Writers for sources on "Ask before sharing" return a fixed set of operation outcomes.
/// `browse` requires web access and a separate session for the running answer.
/// Set per Pi process on the host the server is started with (`PippaMCPHost.egress`), checked on every request.
public struct PippaMCPEgress: Sendable, Equatable {
    public var rules: SourceSharing
    public var web: Bool
    public var onlineBrowser: PippaMCPOnlineBrowser?

    public init(rules: SourceSharing, web: Bool) { self.rules = rules; self.web = web }

    /// Equality compares route policy. The app attaches the browser only to the running endpoint.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rules == rhs.rules && lhs.web == rhs.web }

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

    private enum WriterStatus: String, Decodable {
        case invalid_arguments, cancelled, needs_access, denied, unavailable, failed, not_dispatched
        case not_found, ambiguous, search_incomplete, not_created
    }

    private struct WriterOutcome: Decodable {
        enum State: String, Decodable { case unclear, new_mail_open }
        let done: Bool
        let status: WriterStatus?
        let state: State?
        let sent: Bool?
        let dispatched: Bool?
        let already_completed: Bool?
    }

    /// Build fresh model-visible JSON from typed outcome fields. Native text, identifiers and receipts stay on this Mac.
    package func scrubWriter(_ tool: String, _ result: PippaMCPToolResult) -> PippaMCPToolResult {
        let integration: Integration
        switch tool {
        case "calendar_add": integration = .calendar
        case "reminder_add": integration = .reminders
        case "mail_draft": integration = .mail
        default: return Self.unconfirmed(isError: true)
        }
        guard let outcome = try? JSONDecoder().decode(WriterOutcome.self, from: Data(result.text.utf8)) else {
            return Self.unconfirmed(isError: true)
        }
        if outcome.done {
            guard !result.isError, outcome.status == nil, outcome.dispatched != false else { return Self.unconfirmed(isError: true) }
            switch integration {
            case .calendar, .reminders:
                guard outcome.state == nil, outcome.sent == nil else { return Self.unconfirmed(isError: true) }
                if integration == .reminders, outcome.already_completed == true {
                    return Self.response(["done": true, "already_completed": true,
                                          "next": "The reminder was already created. Report the prior completion."], isError: false)
                }
                return Self.response(["done": true, "next": "Confirm the creation using the details from the tool call."], isError: false)
            case .mail:
                guard outcome.state == .new_mail_open, outcome.sent == false else { return Self.unconfirmed(isError: true) }
                return Self.response(["done": true, "state": "new_mail_open", "sent": false,
                                      "next": "Tell the person their unsent draft is open in Mail."], isError: false)
            }
        }
        if outcome.state == .unclear, outcome.status == nil {
            return Self.unconfirmed(isError: result.isError)
        }
        guard outcome.state == nil, let status = outcome.status, result.isError, outcome.dispatched != true else {
            return Self.unconfirmed(isError: true)
        }
        var values: [String: Any] = ["done": false, "status": status.rawValue, "dispatched": false]
        switch status {
        case .needs_access: values["tell"] = PippaMCPTools.notYet(integration)
        case .denied: values["tell"] = PippaMCPWriteTools.denied(integration)
        case .cancelled: values["tell"] = PippaMCPWriteTools.stoppedText
        case .invalid_arguments: values["error"] = "Check the required arguments and formats in the tool description."
        case .not_dispatched: values["next"] = "This request can only prepare text. Do not retry through another tool."
        default: values["next"] = "Tell the person the change could not be made."
        }
        return Self.response(values, isError: true)
    }

    private static func unconfirmed(isError: Bool) -> PippaMCPToolResult {
        response(["done": false, "state": "unclear",
                  "next": "Ask the person to check the app before trying again. Do not retry automatically."], isError: isError)
    }

    private static func response(_ fields: [String: Any], isError: Bool) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(fields), isError: isError)
    }
}

/// An endpoint-owned browser factory. Its session and host approvals belong to one answer at a time.
@MainActor
public final class PippaMCPOnlineBrowser {
    public nonisolated let approvals: PippaMCPBrowserApprovals
    private let makeSession: (PippaMCPTurn) -> (any BrowserOperating)?
    private var active: (turn: PippaMCPTurn, browser: any BrowserOperating)?
    private var invalidated = false

    public init(approvals: PippaMCPBrowserApprovals = .init(), makeSession: @escaping (PippaMCPTurn) -> (any BrowserOperating)?) {
        self.approvals = approvals
        self.makeSession = makeSession
    }

    func session(for turn: PippaMCPTurn, in turns: PippaMCPTurns) -> (any BrowserOperating)? {
        guard !invalidated, !Task.isCancelled, turns.active === turn, !turn.writes.snapshot.cancelled else { return nil }
        if let active, active.turn === turn { return active.browser }
        guard let browser = makeSession(turn) else { return nil }
        closeActive()
        active = (turn, browser)
        return browser
    }

    public func end(_ turn: PippaMCPTurn, alreadyClosed: Bool = false) {
        guard active?.turn === turn else { return }
        if alreadyClosed { active = nil } else { closeActive() }
    }

    public func invalidate() {
        invalidated = true
        closeActive()
    }

    private func closeActive() {
        guard let browser = active?.browser else { return }
        active = nil
        Task { _ = try? await browser.perform(.close) }
    }
}
