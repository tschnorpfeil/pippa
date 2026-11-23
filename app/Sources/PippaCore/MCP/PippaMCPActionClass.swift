import Foundation

/// What a tool can do to the person's world (docs/pippa-1.0.md "Action classes"). Every tool belongs to exactly one.
public enum PippaActionClass: String, Sendable, CaseIterable {
    /// Changes nothing.
    case read
    /// Changes something on this Mac that Pippa can put back herself.
    case undoable
    /// Cannot be put back: deleting for good, emptying the Trash, overwriting without a copy.
    case irreversible
    /// Leaves this Mac or reaches someone else: mail, invitations, messages, payments, going online.
    case external

    /// `irreversible` and `external` run only after the person pressed a button on a card (`PippaMCPHost.confirmAction`).
    public var needsConfirmation: Bool { self == .irreversible || self == .external }

    /// MCP annotations follow the class, so they cannot drift from what the gate does.
    public var annotations: [String: Any] {
        ["readOnlyHint": self == .read, "destructiveHint": self == .irreversible,
         "idempotentHint": self == .read, "openWorldHint": self == .external]
    }
}

/// The one table: the class of every tool Pippa's AI can call, on Pippa's MCP server (`PippaMCPTools.toolList`) and
/// in Pi (`PippaPiLaunch.tools`). A tool missing here does not run (`PippaMCPTools` refuses it before dispatch), and
/// PippaChecks fails for every listed tool without a class.
public enum PippaActionClasses {
    public static let table: [String: PippaActionClass] = [
        // Pippa's MCP server: readers.
        "calendar_read": .read, "reminders_read": .read, "mail_search": .read, "mail_read": .read, "mail_folders": .read,
        "photos_search": .read, "front_read": .read, "notes_read": .read, "contacts_search": .read, "compute": .read, "read_document": .read,
        // Pippa's MCP server: changes on this Mac with a receipt and Undo (events, reminders), an unsent draft, or new
        // files next to the originals (`prepare_files`).
        "calendar_add": .undoable, "reminder_add": .undoable, "calendar_update": .undoable, "reminder_update": .undoable, "mail_draft": .undoable, "prepare_files": .undoable,
        // Moves mails between folders of one account; every move is journaled and Undo moves it back by Message-ID.
        "mail_move": .undoable,
        // `browse` goes online and acts on web pages. It keeps its own question per step (a new host, every click, fill
        // and select: `PippaMCPHost.confirmBrowser`), listed in `asksPerStep`, instead of one card per call:
        // a snapshot or a page on an approved host reaches no one new.
        PippaMCPBrowserTool.name: .external,
        // Sends one draft Pippa saved in this conversation, after a card with the draft as Mail has it (PippaMCPMailSend.swift).
        PippaMCPMailSend.name: .external,

        // Pi's tools (runtime/pippa-tools). Their gate is Pi's `tool_call` hook and the shell sandbox, which also see
        // calls from codemode scripts; the MCP server never dispatches them.
        "read": .read, "search_files": .read, "list_folder": .read,
        // Asks the person a question and changes nothing.
        "ask": .read,
        // `write` keeps a copy of the old file first; `move_files` records where each file was; `remember` changes only
        // Pippa's own notes, which the person can remove.
        "write": .undoable, "move_files": .undoable, "remember": .undoable,
        // `bash` is classed by the most it can do: a command may go online (asked per command in shell.ts) and, after
        // the person's yes, change files in their folders (asked once per answer, with copies of the files it names:
        // not provably undoable). Everything else runs in the working folder, closed to other apps.
        "bash": .external,
        // The query and the address leave this Mac; both keep their own question (pi-web-access, egress rules).
        "web_search": .external, "fetch_content": .external,
    ]

    /// `external` tools that ask the person per step themselves instead of one card per call. Keep this short.
    public static let asksPerStep: Set<String> = [PippaMCPBrowserTool.name]

    public static func of(_ tool: String) -> PippaActionClass? { table[tool] }

    /// MCP annotations for a listed tool, from its class. Without a class: no hints, and the call is refused.
    static func annotations(_ tool: String, title: String) -> [String: Any] {
        (of(tool)?.annotations ?? [:]).merging(["title": title]) { a, _ in a }
    }
}

/// What the card shows before an `irreversible` or `external` tool runs, built by the server from the call's
/// arguments: the same values the tool body then uses.
public struct PippaMCPConfirmation: Sendable, Equatable {
    public var tool: String
    public var actionClass: PippaActionClass
    /// Plain words, no command: "Send this mail?"
    public var title: String
    /// Who receives it (`external`), if anyone.
    public var recipient: String?
    /// What is affected (`irreversible`): files, mails, events.
    public var objects: [String]
    /// The exact content that leaves or is lost.
    public var content: String
    /// The answer the card belongs to.
    public var turnID: UUID?
    /// The buttons in plain words ("Send", "Don’t Send"); `nil`: the card's usual Allow and Don’t Allow.
    public var confirmLabel: String?
    public var declineLabel: String?

    public init(tool: String, actionClass: PippaActionClass, title: String, recipient: String? = nil, objects: [String] = [],
                content: String, turnID: UUID? = nil, confirmLabel: String? = nil, declineLabel: String? = nil) {
        self.tool = tool; self.actionClass = actionClass; self.title = title; self.recipient = recipient
        self.objects = objects; self.content = content; self.turnID = turnID
        self.confirmLabel = confirmLabel; self.declineLabel = declineLabel
    }

    /// The card's text: recipient or objects first, then the exact content.
    public var message: String {
        ([recipient].compactMap { $0 } + objects + [content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A tool the host adds to the server, for checks only: the app never sets one. It passes the same class gate as
/// Pippa's own tools; `actionClass: nil` stands for a tool someone forgot to class.
public struct PippaMCPHostTool: Sendable {
    public var name: String
    public var actionClass: PippaActionClass?
    /// The card for a confirmed class, from the call's arguments. `nil`: there is nothing to show, so nothing runs.
    public var describe: @Sendable (_ arguments: [String: Any]) -> PippaMCPConfirmation?
    public var run: @Sendable (_ arguments: [String: Any]) async -> PippaMCPToolResult

    public init(name: String, actionClass: PippaActionClass?,
                describe: @escaping @Sendable (_ arguments: [String: Any]) -> PippaMCPConfirmation?,
                run: @escaping @Sendable (_ arguments: [String: Any]) async -> PippaMCPToolResult) {
        self.name = name; self.actionClass = actionClass; self.describe = describe; self.run = run
    }
}

extension PippaMCPTools {
    /// The class gate, before any tool body runs. `nil`: dispatch. `read` and `undoable` pass at once; a tool without a
    /// class never runs; `irreversible` and `external` run only after the person's yes on the card, while the answer
    /// that asked is still the running one. The yes comes from `host.confirmAction` alone, never from arguments.
    func gate(_ name: String, _ actionClass: PippaActionClass?, card: PippaMCPConfirmation?,
              context: PippaMCPRequestContext) async -> PippaMCPToolResult? {
        guard let actionClass else {
            DiagnosticsLog.shared.event("mcp-unclassed", ["name": name])
            return Self.notDispatched("blocked", error: "This tool has no action class, so Pippa does not run it.",
                                      next: "Nothing happened. Do not try another way; answer with what you have.")
        }
        guard actionClass.needsConfirmation, !PippaActionClasses.asksPerStep.contains(name) else { return nil }
        let live = { !Task.isCancelled && !context.writes.snapshot.cancelled
            && (context.turn != nil || !host.requireActiveWriteTurn)
            && host.turns.isLive(context.turn, generation: context.turnGeneration) }
        guard live() else { return Self.notDispatched("cancelled", tell: PippaMCPWriteTools.stoppedText) }
        // A card with nothing on it is no confirmation of anything.
        guard var card, !card.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let confirm = host.confirmAction else {
            return Self.notDispatched("cancelled", tell: L("Pippa can only do this when you can confirm it.", table: "MCP"))
        }
        card.turnID = context.turn?.id
        let yes = await confirm(card)
        // Stop or a newer answer while the card was open: a late press changes nothing.
        guard live() else { return Self.notDispatched("cancelled", tell: PippaMCPWriteTools.stoppedText) }
        guard yes else { return Self.notDispatched("declined", tell: L("Not done: you said no.", table: "Tools"), isError: false) }
        return nil
    }

    static func notDispatched(_ status: String, tell: String? = nil, error: String? = nil, isError: Bool = true,
                              next: String = "Nothing happened. Do not try another way; answer with what you have.") -> PippaMCPToolResult {
        var value: [String: Any] = ["done": false, "status": status, "dispatched": false, "next": next]
        if let tell { value["tell"] = tell }
        if let error { value["error"] = error }
        return PippaMCPToolResult(text: json(value), isError: isError)
    }
}
