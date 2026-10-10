import Foundation

/// "What happened" under an answer: one line per mutating tool call, built from Pi's tool events and Pippa's own
/// results, never from the model text. If the answer contradicts the receipt, the receipt wins.
///
/// Action and result are stored as text, not as an enum, in the history: a later value should not make
/// the history unreadable for older Pippas.
public struct ActionReceipt: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// create, createFolder (plain mkdir), overwrite, change, rename, move, trash, delete, look, command, tool;
        /// read (Pippa's MCP reader: `name` is then the finished line); online (own online service:
        /// `name` is the service); webSearch, webPage (pi-web-access); calendar/reminder/mail (ActionReceipt+Apps.swift):
        /// calendarAdd, reminderAdd, mailDraft (`name` finished from the server). Older histories may hold restore,
        /// setAside and remove (lines of the former undo), shown as they were.
        public var action: String
        /// done, declined, blocked, failed, unclear
        public var outcome: String
        /// File or folder name without path (for `tool`: the tool name).
        public var name: String?
        /// New name (rename) or target folder (move).
        public var toName: String?
        /// Why it did not happen or how it happened, e.g. "busy" (calendar), "nothingFound" (web), "reply" (mail).
        public var reason: String?

        public init(action: String, outcome: String, name: String? = nil, toName: String? = nil, reason: String? = nil) {
            self.action = action; self.outcome = outcome; self.name = name; self.toName = toName; self.reason = reason
        }

        public var happened: Bool { outcome == "done" }

        /// Pippa's memory (`remember`): `name` what was kept, `toName` what was let go ("*": everything).
        func memoryLine(language: String?) -> String {
            switch (outcome, name, toName) {
            case ("done", let added?, let forgot?) where reason != "nothingMatched":
                return L("Remembered: “%@” (instead of “%@”)", table: "Thought", language: language, added, forgot)
            case ("done", let added?, _):
                return L("Remembered: “%@”", table: "Thought", language: language, added)
            case ("done", nil, "*"?) where reason != "nothingMatched":
                return L("Forgot everything Pippa knew about you", table: "Thought", language: language)
            case ("done", nil, let forgot?):
                return reason == "nothingMatched" ? L("Nothing to forget for “%@”", table: "Thought", language: language, forgot)
                    : L("Forgot: “%@”", table: "Thought", language: language, forgot)
            case ("done", nil, nil):
                return L("Nothing remembered", table: "Thought", language: language)
            // Not kept is often something Pippa refuses to keep (account numbers, passwords): never repeat it here.
            case ("failed", _?, _), ("blocked", _?, _):
                return L("Not remembered", table: "Thought", language: language)
            case ("failed", nil, _?), ("blocked", nil, _?):
                return L("Not forgotten", table: "Thought", language: language)
            default:
                return L("Unclear whether Pippa remembered it", table: "Thought", language: language)
            }
        }

        /// "Online nachgesehen: „Wetter morgen Köln“" and the honest counterparts. `name` is the shown text.
        func webLine(language: String?) -> String {
            let page = action == "webPage"
            guard let what = name else {
                return L("An online lookup wasn’t allowed; nothing left your Mac", table: "Thought", language: language)
            }
            switch outcome {
            case "done":
                let base = page ? L("Read online: %@", table: "Thought", language: language, what)
                                : L("Looked up online: “%@”", table: "Thought", language: language, what)
                return reason == "nothingFound" ? L("%@ (nothing found)", table: "Thought", language: language, base) : base
            case "declined":
                let base = page ? L("Not read online: %@", table: "Thought", language: language, what)
                                : L("Not looked up online: “%@”", table: "Thought", language: language, what)
                return L("%@ (you said no)", table: "Thought", language: language, base)
            default:
                let base = page ? L("Not read online: %@", table: "Thought", language: language, what)
                                : L("Not looked up online: “%@”", table: "Thought", language: language, what)
                return L("%@ (didn’t work)", table: "Thought", language: language, base)
            }
        }

        /// A short line in the system language: "Nicht angelegt: Einkauf.txt (du hast abgelehnt)",
        /// "Angelegt: Einkauf.txt". `language` only for recordings and checks ("de", "en").
        public var line: String { line(language: nil) }

        public func line(language: String?) -> String {
            let what = name ?? "?"
            // Read (Pippa's MCP reader): neutral line, already fully worded (PippaMCPReadNote).
            if action == "read" { return name ?? L("Read something", table: "Thought", language: language) }
            // Lines of the former undo in older histories.
            if action == "restore" || action == "setAside" || action == "remove" {
                guard outcome == "done" else {
                    let base = L("Not undone: %@", table: "Thought", language: language, what)
                    return switch reason {
                    case "gone": L("%@ (no longer there)", table: "Thought", language: language, base)
                    case "changed": L("%@ (changed since, so it stays)", table: "Thought", language: language, base)
                    case "occupied": L("%@ (something else is in its place now)", table: "Thought", language: language, base)
                    case "notEmpty": L("%@ (there’s something in the folder now)", table: "Thought", language: language, base)
                    case "already": L("%@ (already undone)", table: "Thought", language: language, base)
                    case "notRestorable": L("%@ (no undo copy)", table: "Thought", language: language, base)
                    default: L("%@ (didn’t work)", table: "Thought", language: language, base)
                    }
                }
                return switch action {
                case "setAside": L("Undone: %@ moved to the Trash", table: "Thought", language: language, what)
                case "remove": L("Undone: %@ removed", table: "Thought", language: language, what)
                default: L("Restored: %@", table: "Thought", language: language, what)
                }
            }
            // Event, reminder, mail draft via Pippa's MCP server (ActionReceipt+Apps.swift).
            if Self.appActions.contains(action) { return appLine(language: language) }
            if action == "remember" { return memoryLine(language: language) }
            // Look up online on the Pi RPC path (pi-web-access, PiTurnReceipt): exactly what went out.
            if action == "webSearch" || action == "webPage" { return webLine(language: language) }
            // Request to the own online service via Pippa's broker (`name`: the service).
            if action == "online" {
                return switch outcome {
                case "done": L("Asked online: %@", table: "Thought", language: language, what)
                case "declined": L("Not asked online: %@ (you said no)", table: "Thought", language: language, what)
                case "local": L("Not asked online: %@ (answered on this Mac)", table: "Thought", language: language, what)
                default: L("Asked online: %@ (didn’t work)", table: "Thought", language: language, what)
                }
            }
            let base: String
            switch outcome {
            case "done":
                base = switch action {
                case "create": L("Created: %@", table: "Thought", language: language, what)
                case "createFolder": L("Folder created: %@", table: "Thought", language: language, what)
                case "overwrite": L("Overwritten: %@", table: "Thought", language: language, what)
                case "rename": L("Renamed: %@ → %@", table: "Thought", language: language, what, toName ?? "?")
                case "move": L("Moved: %@ → %@", table: "Thought", language: language, what, toName ?? "?")
                case "trash": L("Moved to the Trash: %@", table: "Thought", language: language, what)
                case "delete": L("Deleted: %@", table: "Thought", language: language, what)
                case "look": L("Looked in %@", table: "Thought", language: language, what)
                case "command": L("Ran a command", table: "Thought", language: language)
                case "tool": L("Used: %@", table: "Thought", language: language, what)
                default: L("Changed: %@", table: "Thought", language: language, what)
                }
            case "declined", "blocked", "failed":
                base = switch action {
                case "create": L("Not created: %@", table: "Thought", language: language, what)
                case "createFolder": L("Folder not created: %@", table: "Thought", language: language, what)
                case "overwrite": L("Not overwritten: %@", table: "Thought", language: language, what)
                case "rename": L("Not renamed: %@", table: "Thought", language: language, what)
                case "move": L("Not moved: %@", table: "Thought", language: language, what)
                case "trash": L("Not moved to the Trash: %@", table: "Thought", language: language, what)
                case "delete": L("Not deleted: %@", table: "Thought", language: language, what)
                case "look": L("Didn’t look in %@", table: "Thought", language: language, what)
                case "command": L("Command not run", table: "Thought", language: language)
                case "tool": L("Not used: %@", table: "Thought", language: language, what)
                default: L("Not changed: %@", table: "Thought", language: language, what)
                }
            default:
                // Started, but no result: claim neither "done" nor "did not happen".
                return L("Unclear whether it happened: %@", table: "Thought", language: language, action == "command" ? L("a command", table: "Thought", language: language) : what)
            }
            switch outcome {
            case "declined": return L("%@ (you said no)", table: "Thought", language: language, base)
            case "blocked", "failed": return L("%@ (didn’t work)", table: "Thought", language: language, base)
            default:
                // Something in the Trash can be put back from there.
                return action == "trash" ? L("%@ · you can put it back from the Trash", table: "Thought", language: language, base) : base
            }
        }
    }

    public var items: [Item]
    /// Added later (MailDraftOffer.swift): "Als Entwurf in Mail" under an answer without a draft. Missing in older histories.
    public var mailOffer: MailDraftOffer?
    /// What reading tools returned, as cards under the answer (ResultCard). Missing in older histories.
    public var cards: [ResultCard]?
    public init(items: [Item], mailOffer: MailDraftOffer? = nil, cards: [ResultCard]? = nil) {
        self.items = items; self.mailOffer = mailOffer; self.cards = cards?.isEmpty == false ? cards : nil
    }

    /// A card this version does not know (a newer app wrote it) or cannot read is dropped: the answer and its
    /// receipt still open, the answer text stays the plain-text fallback.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Item].self, forKey: .items)
        mailOffer = try c.decodeIfPresent(MailDraftOffer.self, forKey: .mailOffer)
        let known = (try? c.decodeIfPresent([LenientCard].self, forKey: .cards))?.compactMap(\.card)
        cards = known?.isEmpty == false ? known : nil
    }

    private struct LenientCard: Decodable {
        var card: ResultCard?
        init(from decoder: Decoder) throws { card = try? ResultCard(from: decoder) }
    }

    /// Lines without direct repetition (the same failed attempt twice → one line).

    public var lines: [(item: Item, text: String)] { lines(language: nil) }

    public func lines(language: String?) -> [(item: Item, text: String)] {
        var result: [(item: Item, text: String)] = []
        for item in items {
            let text = item.line(language: language)
            if result.last?.text != text { result.append((item, text)) }
        }
        return result
    }
}
