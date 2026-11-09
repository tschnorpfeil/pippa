import Foundation

extension PippaMCPTools {
    // MARK: Read receipt

    /// The receipt line for a call: from the call itself and Pippa's own result (subject, hit count),
    /// never from model text. Foreign content (subject, search term) only single-line and truncated.
    static func readNote(_ name: String, _ input: ToolInput, _ outcome: PippaMCPToolResult, calendar: Calendar) -> PippaMCPReadNote {
        let app: String = switch name {
        case "calendar_read": Integration.calendar.appName
        case "reminders_read": Integration.reminders.appName
        case "mail_selected", "mail_search": Integration.mail.appName
        case "photos_search": PhotosLibrary.appName
        case "front_read": Self.frontAppName(outcome)
        default: ExcelScript.appName
        }
        guard !outcome.isError else {
            return PippaMCPReadNote(tool: name, read: false, line: L("Not read: %@", table: "MCP", app), permissionRepair: outcome.permissionRepair)
        }
        let data = ((try? JSONSerialization.jsonObject(with: Data(outcome.text.utf8))) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        func short(_ text: String) -> String {
            let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return one.count > 60 ? String(one.prefix(59)) + "…" : one
        }
        let line: String
        switch name {
        case "calendar_read": line = L("Read Calendar: %@", table: "MCP", periodLabel(input, calendar: calendar))
        case "reminders_read":
            line = switch input.days {
            case nil: L("Read Reminders: open ones", table: "MCP")
            case 1?: L("Read Reminders: due today", table: "MCP")
            case let days?: L("Read Reminders: due in the next %lld days", table: "MCP", days)
            }
        case "mail_selected": line = L("Read Mail: “%@”", table: "MCP", short(data["subject"] as? String ?? ""))
        case "mail_search":
            let query = (data["query"] as? String) ?? "", total = data["total"] as? Int ?? 0
            line = switch (query.isEmpty, data["unread"] as? Bool == true) {
            case (false, _): L("Searched Mail for “%@”: %lld found", table: "MCP", short(query), total)
            case (true, true): L("Read Mail: %lld unread", table: "MCP", total)
            case (true, false): L("Read Mail: newest emails", table: "MCP")
            }
        case "photos_search":
            line = switch (data["query"] as? String, data["days"] as? Int) {
            case let (query?, _): L("Searched Photos for “%@”: %lld found", table: "MCP", short(query), data["total"] as? Int ?? 0)
            case (nil, 1?): L("Read Photos: pictures from today", table: "MCP")
            case let (nil, days?): L("Read Photos: pictures from the last %lld days", table: "MCP", days)
            case (nil, nil): L("Read Photos: newest pictures", table: "MCP")
            }
        case "front_read": line = L("Read %@: “%@”", table: "MCP", app, short(data["title"] as? String ?? ""))
        default: line = L("Read Excel: active sheet", table: "MCP")
        }
        // Identity of the mail read, from Pippa's own result (never from model text).
        let mail = name == "mail_selected" ? (data["messageID"] as? String).flatMap {
            MailReplySource(messageID: $0, replyTo: data["replyTo"] as? String, subject: data["subject"] as? String ?? "")
        } : nil
        return PippaMCPReadNote(tool: name, read: true, line: line, mail: mail, card: outcome.card, permissionRepair: outcome.permissionRepair)
    }

    /// The chip's app name in a `front_read` result (beside the blocked answer, or under data); the app's own text never.
    static func frontAppName(_ outcome: PippaMCPToolResult) -> String {
        let json = (try? JSONSerialization.jsonObject(with: Data(outcome.text.utf8))) as? [String: Any] ?? [:]
        return json["app"] as? String ?? (json["data"] as? [String: Any])?["app"] as? String ?? L("the app in front", table: "MCP")
    }

    /// Time range in words, as the person meant it ("heute", "nächste Woche", "Do., 8. Okt. 2026 bis …").
    static func periodLabel(_ input: ToolInput, calendar: Calendar) -> String {
        switch input.period {
        case "today": return L("today", table: "MCP")
        case "tomorrow": return L("tomorrow", table: "MCP")
        case "rest_of_week": return L("rest of this week", table: "MCP")
        case "next_week": return L("next week", table: "MCP")
        case "weekend": return L("the weekend", table: "MCP")
        case "next_days": return L("next %lld days", table: "MCP", input.days ?? 1)
        default:
            let parser = DateFormatter()
            parser.calendar = calendar; parser.timeZone = calendar.timeZone
            parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
            let label = { (raw: String?) in raw.flatMap(parser.date(from:)).map { dateLabel($0, time: false, calendar: calendar) } ?? raw ?? "?" }
            return L("%@ to %@", table: "MCP", label(input.start), label(input.end))
        }
    }
}
