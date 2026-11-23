import Foundation
import PiRPC
import PippaCore

/// The conversation files, read and written on one background queue: encoding and writing never hold up the window,
/// and saves land on disk in the order they were made (a later save of a conversation never loses to an earlier one).
final class ConversationStore: Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "Pippa.conversations", qos: .utility)

    init(folder: URL) { self.folder = folder }

    /// Called off the main actor (at launch). Every file that can be read counts; a missing folder is a first run. The
    /// folder or files that cannot be read are counted and logged, so they never pass for an empty history.
    func load() -> (conversations: [Conversation], unreadable: Int) {
        queue.sync {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
            catch {
                if (error as NSError).code == NSFileReadNoSuchFileError { return ([], 0) }
                UserMessage.record(error, context: "gespraeche-ordner")
                return ([], 1)
            }
            let decoder = JSONDecoder()
            var conversations: [Conversation] = [], unreadable = 0
            for file in files where file.pathExtension == "json" {
                do { conversations.append(try decoder.decode(Conversation.self, from: Data(contentsOf: file))) }
                catch { unreadable += 1; UserMessage.record(error, context: "gespraech-lesen") }
            }
            return (conversations.sorted { $0.updated > $1.updated }, unreadable)
        }
    }

    func save(_ conversation: Conversation) {
        let folder = self.folder
        queue.async {
            guard let data = try? JSONEncoder().encode(conversation) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("\(conversation.id).json"), options: .atomic)
        }
    }

    /// After any save still waiting, so a late write never brings a deleted conversation back.
    func trash(_ id: String) {
        let file = folder.appendingPathComponent("\(id).json")
        queue.async { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    /// Waits until every save so far is on disk (when Pippa quits).
    func flush() { queue.sync {} }
}

/// A short everyday line for a tool call ("Reading Lease.pdf"). Display only; Pi never sees it.
enum StepLabel {
    /// A running step's label with where it is in a long document: "Reading Thesis.docx · Part 3 of 10".
    static func progress(_ label: String, part: Int, of: Int, merging: Bool) -> String {
        merging ? T("%@ · merging the notes", table: "App", label) : T("%@ · Part %lld of %lld", table: "App", label, part, of)
    }

    static func text(tool: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let name = SourceLog.bareToolName(tool)
        func file(_ key: String) -> String { (args[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
        func value(_ key: String) -> String { (args[key] as? String) ?? "" }
        /// A detail worth naming: the value, or the first of a list, on one line and short; "" when there is none.
        func detail(_ key: String, list: String? = nil) -> String {
            let first = (args[key] as? String) ?? list.flatMap { (args[$0] as? [Any])?.first as? String } ?? ""
            return clip(first)
        }
        switch name {
        case "read", "read_document":
            // A web address is not a file: `read_document` refuses it, Pi's `read` cannot open it.
            let path = value("path")
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return T("Reading a web page", table: "App") }
            return T("Reading %@", table: "App", file("path"))
        case "write": return T("Writing %@", table: "App", file("path"))
        case "bash": return T("Running a command", table: "App")
        case "search_files": return T("Searching files for “%@”", table: "App", value("query"))
        case "list_folder": return T("Looking in %@", table: "App", file("path"))
        case "move_files": return T("Moving files", table: "App")
        case "web_search":
            let query = detail("query", list: "queries")
            return query.isEmpty ? T("Searching the web", table: "App") : T("Searching the web for “%@”", table: "App", query)
        case "fetch_content":
            let site = host(of: (args["url"] as? String) ?? ((args["urls"] as? [Any])?.first as? String) ?? "")
            return site.isEmpty ? T("Reading a web page", table: "App") : T("Reading a page on %@", table: "App", site)
        case "browse":
            let site = value("action") == "open" ? host(of: value("url")) : ""
            return site.isEmpty ? T("Browsing a web page", table: "App") : T("Browsing %@", table: "App", site)
        case "remember": return T("Remembering", table: "App")
        case "ask": return T("Asking you", table: "App")
        case "calendar_read": return T("Reading Calendar", table: "App")
        case "calendar_add":
            let title = detail("title")
            return title.isEmpty ? T("Adding to Calendar", table: "App") : T("Adding “%@” to Calendar", table: "App", title)
        case "reminders_read": return T("Reading Reminders", table: "App")
        case "reminder_add":
            let title = detail("title")
            return title.isEmpty ? T("Adding a reminder", table: "App") : T("Adding the reminder “%@”", table: "App", title)
        case "mail_search":
            let query = detail("query")
            return query.isEmpty ? T("Reading Mail", table: "App") : T("Searching Mail for “%@”", table: "App", query)
        case "mail_folders":
            let account = detail("account")
            return account.isEmpty ? T("Reading Mail", table: "App") : T("Reading the Mail folders of %@", table: "App", account)
        case "mail_read": return T("Reading Mail", table: "App")
        case "mail_move":
            // The folder by its own name ("Invoices"), not its whole path ("Work/2026/Invoices").
            let folder = clip(value("to").split(separator: "/").last.map(String.init) ?? "")
            if args["dry_run"] as? Bool == true {
                return folder.isEmpty ? T("Planning mail moves", table: "App") : T("Planning mail moves to %@", table: "App", folder)
            }
            return folder.isEmpty ? T("Moving mails", table: "App") : T("Moving mails to %@", table: "App", folder)
        case "mail_draft":
            let subject = detail("subject"), to = detail("to")
            if !subject.isEmpty { return T("Writing a Mail draft: %@", table: "App", subject) }
            return to.isEmpty ? T("Writing a Mail draft", table: "App") : T("Writing a Mail draft to %@", table: "App", to)
        case "mail_send": return T("Sending a mail", table: "App")
        case "photos_search":
            let query = detail("query")
            return query.isEmpty ? T("Searching Photos", table: "App") : T("Searching Photos for “%@”", table: "App", query)
        case "front_read": return T("Reading the app in front", table: "App")
        case "prepare_files": return T("Preparing files", table: "App")
        case PiTurnReceipt.scriptTool: return T("Working through the list", table: "App")
        // A tool Pippa does not know (a model may invent one): say that a tool is used, never the raw name.
        default: return T("Using a tool", table: "App")
        }
    }

    /// One line of at most `max` characters, cut at a word where one is near ("Quarterly report for…").
    static func clip(_ text: String, _ max: Int = 36) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard line.count > max else { return line }
        let cut = String(line.prefix(max - 1))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) }
        let kept = word.flatMap { $0.count >= max / 2 ? $0 : nil } ?? cut
        return kept.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// The site of a web address without "www." ("zeit.de"); "" for anything that is not one.
    static func host(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host()?.lowercased(), !host.isEmpty else { return "" }
        return clip(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
}
