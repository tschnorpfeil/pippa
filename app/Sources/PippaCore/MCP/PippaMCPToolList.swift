import Foundation

extension PippaMCPTools {
    // MARK: Tools

    static var readOnly: [String: Any] { ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false] }

    /// Short descriptions: every word costs prompt time with the local model. Schemas declare fields and types;
    /// values and unknown arguments are checked here (`ToolInput`, each tool), with an error the model can act on.
    public static func toolList() -> [[String: Any]] {
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "title": title, "description": description, "inputSchema": schema,
                    "annotations": readOnly.merging(["title": title]) { a, _ in a }]
        }
        let string: [String: Any] = ["type": "string"], integer: [String: Any] = ["type": "integer"]
        // Closed enums already restrict their value types; repeating type adds no validation.
        let readers: [[String: Any]] = [
            tool("calendar_read", "Kalender lesen",
                 "next_days=days; dates=start/end YYYY-MM-DD (max31d).",
                 ["period": ["enum": ["today", "tomorrow", "rest_of_week", "next_week", "weekend", "next_days", "dates"]],
                  "days": integer, "start": string, "end": string], required: ["period"]),
            tool("reminders_read", "Erinnerungen lesen",
                 "Open; days=due within N (1=today).", ["days": integer]),
            tool("mail_search", "Mail suchen",
                 "Inbox, newest first. query=word in subject/sender; omit=newest; unread=true only unread.",
                 ["query": string, "unread": ["type": "boolean"], "limit": integer]),
            tool("mail_read", "Mail öffnen",
                 "Whole inbox email from mail_search: message_id from the result, else subject exact + from=its sender; attachments saved for read_document.",
                 ["message_id": string, "subject": string, "from": string]),
            tool("photos_search", "Fotos suchen",
                 "query=one Mac-language word; omit=newest; days=last N (no query).",
                 ["query": string, "days": integer, "limit": integer]),
            // The message names the app ([Im Vordergrund: …], FrontApp.label); a question that points at it already brings
            // the content (FrontQuestion), this call is for the rest.
            tool("front_read", "Geöffnetes lesen", "Front content."),
        ]
        return readers + PippaMCPTurnTools.toolList() + PippaMCPWriteTools.toolList() + PippaMCPFilePreparation.toolList()

    }

    /// Each reader accepts only its own declared fields and types. An invalid optional filter must never become
    /// an omitted filter: `photos_search(query: 123)` must not fall through to reading the newest pictures.
    struct ToolInput: Sendable {
        var period: String?, start: String?, end: String?, query: String?, subject: String?, from: String?, messageID: String?
        var days: Int?, limit: Int?
        var unread: Bool?
        var unknown: [String]
        static let allowed: [String: Set<String>] = [
            "calendar_read": ["period", "days", "start", "end"],
            "reminders_read": ["days"],
            "mail_search": ["query", "unread", "limit"],
            "mail_read": ["subject", "from", "message_id"],
            "photos_search": ["query", "days", "limit"],
            "front_read": [],
        ]

        init(_ tool: String, _ raw: [String: Any]) {
            func int(_ key: String) -> Int? {
                guard let n = raw[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                return Int(exactly: n.doubleValue)
            }
            period = raw["period"] as? String; start = raw["start"] as? String; end = raw["end"] as? String
            query = raw["query"] as? String; days = int("days"); limit = int("limit")
            subject = raw["subject"] as? String; from = raw["from"] as? String; messageID = raw["message_id"] as? String
            func bool(_ key: String) -> Bool? {
                guard let n = raw[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
                return n.boolValue
            }
            unread = bool("unread")
            let allowed = Self.allowed[tool] ?? []
            unknown = raw.keys.filter { key in
                guard allowed.contains(key) else { return true }
                if key == "days" || key == "limit" { return int(key) == nil }
                if key == "unread" { return bool(key) == nil }
                // Optional means omitted, not null, a boolean, an array, or another scalar type.
                return !(raw[key] is String)
            }.sorted()
        }
    }
}
