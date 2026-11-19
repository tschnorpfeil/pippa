import Foundation
import PippaCore

/// Something an answer read: a file, a mail or a web page. Shown as a chip under the answer and in the context panel.
struct ChatSource: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case file, mail, web }
    var kind: Kind
    var name: String
    /// File path, web address or message URL; empty when the source cannot be opened.
    var location: String
    /// "Pages 1–3", "Beginning only": filled in once the read has ended.
    var detail: String?
    /// Pippa's notes on a document too long to read at once (a Markdown file, runtime/pippa-tools/digest.ts): the
    /// answer rests on these notes, not on the full text.
    var notes: String?
}

/// How full the conversation's context was after the answer (Pi's `get_session_stats`).
struct ContextUsage: Codable, Equatable {
    var tokens: Int
    var window: Int
    var fraction: Double { window > 0 ? min(1, Double(tokens) / Double(window)) : 0 }
}

/// Sources from tool calls, never from the model's text.
enum SourceLog {
    /// A tool's own name, without the prefix Pi gives Pippa's MCP tools ("mcp__pippa__read_document" → "read_document").
    static func bareToolName(_ tool: String) -> String {
        let prefix = "mcp__pippa__"
        return tool.hasPrefix(prefix) ? String(tool.dropFirst(prefix.count)) : tool
    }

    static func source(tool: String, arguments: String, result: String? = nil) -> ChatSource? {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let name = bareToolName(tool)
        switch name {
        case "read", "read_document":
            guard let path = args["path"] as? String, !path.isEmpty else { return nil }
            let full = (path as NSString).expandingTildeInPath
            return ChatSource(kind: .file, name: URL(fileURLWithPath: full).lastPathComponent, location: full)
        case "mail_read":
            // The result identifies what was read, including calls that supplied only message_id.
            guard let result, let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
                  let data = object["data"] as? [String: Any], let subject = data["subject"] as? String, !subject.isEmpty else { return nil }
            let id = (data["messageID"] as? String).flatMap(MailReplySource.canonicalMessageID)
            let location = id.flatMap { "<\($0)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "message://" + $0 } ?? ""
            if let account = data["account"] as? String {
                // A message URL cannot distinguish copies delivered to different accounts.
                return ChatSource(kind: .mail, name: subject + " · " + account, location: "")
            }
            return ChatSource(kind: .mail, name: subject, location: location)
        case "fetch_content":
            guard let url = (args["url"] as? String) ?? (args["urls"] as? [String])?.first, let host = URL(string: url)?.host() else { return nil }
            return ChatSource(kind: .web, name: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, location: url)
        default:
            return nil
        }
    }

    /// `read_document`'s pages and whether it read only part, from its result.
    static func detail(result: String, mail: Bool = false) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        if mail { return data["bodyTruncated"] as? Bool == true ? T("Beginning only", table: "App") : nil }
        let pages = data["pages"] as? String
        let total = data["pageCount"] as? Int
        if data["truncated"] as? Bool == true {
            return pages.map { T("Pages %@, more not read", table: "App", $0) } ?? T("Beginning only", table: "App")
        }
        if let pages, let total { return pages == "1" && total == 1 ? T("Whole page", table: "App") : T("Pages %@ of %lld", table: "App", pages, total) }
        return T("Whole document", table: "App")
    }
}

extension Conversation {
    /// Compiled once: the sidebar asks for every preview on each redraw.
    private static let markdownLead = try! NSRegularExpression(pattern: #"^[#>\-\*\d\.\s]+"#)
    private static let markdownMarks = try! NSRegularExpression(pattern: #"[\*_`]"#)

    /// One line for the sidebar: the start of the last answer, without Markdown.
    var preview: String {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return "" }
        if last.text.isEmpty, let error = last.error { return error }
        let line = last.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let lead = Self.markdownLead.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return Self.markdownMarks.stringByReplacingMatches(in: lead, range: NSRange(lead.startIndex..., in: lead), withTemplate: "")
    }

    /// A symbol for what the conversation was about: its files, what it read or added.
    var symbol: String {
        let files = messages.flatMap(\.files).map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        if files.contains(where: { ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains($0) }) { return "photo" }
        if files.contains("pdf") { return "doc.text" }
        if !files.isEmpty { return "doc" }
        let sources = messages.flatMap { $0.sources ?? [] }
        let receipts = messages.flatMap(\.receipts).map(\.action)
        if receipts.contains("calendarAdd") { return "calendar" }
        if receipts.contains("reminderAdd") { return "checklist" }
        if sources.contains(where: { $0.kind == .mail }) || receipts.contains("mailDraft") { return "envelope" }
        if sources.contains(where: { $0.kind == .web }) { return "globe" }
        if sources.contains(where: { $0.kind == .file }) { return "doc.text" }
        return "bubble.left"
    }
}
