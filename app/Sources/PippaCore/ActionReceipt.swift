import Foundation

/// "What happened" under an answer: one line per mutating tool call, built from tool events
/// and the entries of the Pippa guard, never from the model text.
/// If the answer contradicts the receipt ("Die Datei wurde erstellt" after a no), the receipt wins.
///
/// Action and result are stored as text, not as an enum, in the history: a later value should not make
/// the history unreadable for older Pippas.
public struct ActionReceipt: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// create, createFolder (plain mkdir), overwrite, change, rename, move, trash, delete, look, command, tool;
        /// read (Pippa's MCP reader: `name` is then the finished line); online (own online service:
        /// `name` is the service); after "undo": restore, setAside
        /// (a file created by Pi or a new folder set aside); calendar/reminder/mail (ActionReceipt+Apps.swift):
        /// calendarAdd, reminderAdd, mailDraft (`name` finished from the server) and after "undo" remove
        public var action: String
        /// done, declined, blocked, failed, unclear
        public var outcome: String
        /// File or folder name without path (for `tool`: the tool name).
        public var name: String?
        /// New name (rename) or target folder (move).
        public var toName: String?
        /// Undo entry of the guard (folder with manifest.json).
        public var undoEntry: String?
        public var restorable: Bool
        /// For `blocked`: "noUI" or "noUndo"; for failed restore/setAside: "gone", "occupied", "notEmpty",
        /// "already", "notRestorable", "error".
        public var reason: String?

        /// Does the line show "undo"? Done, undoable, with entry, not yet restored.
        public var canUndo: Bool {
            outcome == "done" && restorable && undoEntry != nil && !["restore", "setAside", "remove", "look", "read", "mailDraft", "online"].contains(action)
                && !PiUndo.isRestored(URL(fileURLWithPath: undoEntry!, isDirectory: true)) && !undoPruned
        }

        /// The guard cleaned up the backup (7 days / 500 MB): no button anymore, a sentence instead.
        public var undoPruned: Bool {
            outcome == "done" && restorable && undoEntry.map { PiUndo.isPruned(URL(fileURLWithPath: $0, isDirectory: true)) } == true
        }
        public init(action: String, outcome: String, name: String? = nil, toName: String? = nil, undoEntry: String? = nil,
                    restorable: Bool = false, reason: String? = nil) {
            self.action = action; self.outcome = outcome; self.name = name; self.toName = toName
            self.undoEntry = undoEntry; self.restorable = restorable; self.reason = reason
        }

        public var happened: Bool { outcome == "done" }

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
                return switch reason {
                case "blocked": L("%@ (the search service is blocking requests right now)", table: "Thought", language: language, base)
                case "timeout": L("%@ (took too long)", table: "Thought", language: language, base)
                case "unreadable": L("%@ (the page couldn’t be read)", table: "Thought", language: language, base)
                default: L("%@ (didn’t work)", table: "Thought", language: language, base)
                }
            }
        }

        /// A short line in the system language: "Nicht angelegt: Einkauf.txt (du hast abgelehnt)",
        /// "Angelegt: Einkauf.txt · rückgängig machbar". `language` only for recordings and checks ("de", "en").
        public var line: String { line(language: nil) }

        public func line(language: String?) -> String {
            let what = name ?? "?"
            // Read (Pippa's MCP reader): neutral line, already fully worded (PippaMCPReadNote), never with undo.
            if action == "read" { return name ?? L("Read something", table: "Thought", language: language) }
            // Restored via "Rückgängig" (PiUndo): own line, without "rückgängig machbar".
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
            // Look up online on the Pi RPC path (WebAccessGate.records): exactly the text that went out. Never undoable.
            if action == "webSearch" || action == "webPage" { return webLine(language: language) }
            // Request to the own online service via Pippa's broker (`name`: the service). Never undoable.
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
                case "createFolder": restorable ? L("Folder created: %@", table: "Thought", language: language, what)
                                                : L("Folder already there: %@", table: "Thought", language: language, what)
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
            case "blocked": return reason == "noUndo" ? L("%@ (no undo copy possible)", table: "Thought", language: language, base)
                                                      : L("%@ (needs your OK, couldn’t ask)", table: "Thought", language: language, base)
            case "failed": return L("%@ (didn’t work)", table: "Thought", language: language, base)
            default:
                if action == "look" || (action == "createFolder" && !restorable) { return base }
                // Something in the Trash can always be put back from there, even when Pippa's own undo has expired.
                if action == "trash", undoPruned || !restorable {
                    return L("%@ · you can put it back from the Trash", table: "Thought", language: language, base)
                }
                if undoPruned { return L("%@ · can no longer be undone (undo copy cleared after a while)", table: "Thought", language: language, base) }
                return restorable ? L("%@ · can be undone", table: "Thought", language: language, base) : L("%@ · can’t be undone", table: "Thought", language: language, base)
            }
        }
    }

    public var items: [Item]
    /// Added later (MailDraftOffer.swift): "Als Entwurf in Mail" under an answer without a draft. Missing in older histories.
    public var mailOffer: MailDraftOffer?
    public init(items: [Item], mailOffer: MailDraftOffer? = nil) { self.items = items; self.mailOffer = mailOffer }

    /// Lines without direct repetition (the same declined attempt twice → one line).
    /// Lines for "Alles rückgängig", in restore order (bottom to top).
    public var undoAllItems: [Item] { items.filter(\.canUndo).reversed() }
    /// "Alles rückgängig" appears from two restorable lines (with one, its own button suffices).
    public var offersUndoAll: Bool { items.lazy.filter(\.canUndo).prefix(2).count == 2 }

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
