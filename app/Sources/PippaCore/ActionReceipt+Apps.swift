import Foundation

// Receipt lines for event, reminder and mail draft via Pippa's MCP server. The
// name ("Do., 8. Okt., 09:00 – Zahnarzt", "„Re: Termin“") is built by the server from its own result; the guard
// passes it through (`pippa-receipt`). Mail: exact states (created, opened, unclear), never "sent".
extension ActionReceipt.Item {
    /// Actions of the writing MCP tools.
    public static let appActions: Set<String> = ["calendarAdd", "reminderAdd", "mailDraft"]

    /// "Open draft" instead of "Undo": a mail draft that is in Mail or may be.
    public var canOpenMailDraft: Bool { action == "mailDraft" && (outcome == "done" || outcome == "unclear") }

    func appLine(language: String?) -> String {
        let what = name ?? "?"
        if action == "mailDraft" {
            switch outcome {
            // The reply has a reply text or claims a draft, but code created none.
            case "notYet": return L("No draft in Mail yet", table: "Thought", language: language)
            case "done":
                return switch reason {
                case "opened": L("Reply opened in Mail, text not confirmed: %@ · not sent", table: "Thought", language: language, what)
                case "newMessage": L("New email opened in Mail: %@ · not sent", table: "Thought", language: language, what)
                default: L("Reply draft created in Mail: %@ · not sent", table: "Thought", language: language, what)
                }
            case "unclear": return L("Unclear whether a reply is open in Mail: %@ · nothing sent", table: "Thought", language: language, what)
            default:
                let base = L("No draft created in Mail: %@", table: "Thought", language: language, what)
                // The mail to reply to is no longer in Mail (searched via its Message-ID).
                if outcome == "failed", reason == "not_found" {
                    return L("%@ (I can’t find the email in Mail anymore)", table: "Thought", language: language, base)
                }
                return suffix(base, language: language)
            }
        }
        let calendar = action == "calendarAdd"
        switch outcome {
        case "done":
            let base = calendar ? L("Added to Calendar: %@", table: "Thought", language: language, what)
                                : L("Reminder added: %@", table: "Thought", language: language, what)
            if undoPruned { return L("%@ · can no longer be undone (undo copy cleared after a while)", table: "Thought", language: language, base) }
            return restorable ? L("%@ · can be undone", table: "Thought", language: language, base) : L("%@ · can’t be undone", table: "Thought", language: language, base)
        case "declined", "blocked", "failed":
            let base = calendar ? L("Not added to Calendar: %@", table: "Thought", language: language, what)
                                : L("Reminder not added: %@", table: "Thought", language: language, what)
            if reason == "busy" { return L("%@ (that time is already taken)", table: "Thought", language: language, base) }
            return suffix(base, language: language)
        default:
            return L("Unclear whether it happened: %@", table: "Thought", language: language, what)
        }
    }

    /// As with files: declined, blocked without asking, failed.
    private func suffix(_ base: String, language: String?) -> String {
        switch outcome {
        case "declined": L("%@ (you said no)", table: "Thought", language: language, base)
        case "blocked": L("%@ (needs your OK, couldn’t ask)", table: "Thought", language: language, base)
        default: L("%@ (didn’t work)", table: "Thought", language: language, base)
        }
    }
}
