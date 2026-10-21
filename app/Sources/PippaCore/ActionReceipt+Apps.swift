import Foundation

// Receipt lines for event, reminder and mail draft via Pippa's MCP server. The
// name ("Do., 8. Okt., 09:00 – Zahnarzt", "„Re: Termin“") is built by the server from its own result and reaches
// the receipt through the app (`PippaMCPService.writeNotes`). Mail: exact states (created, opened, unclear), never "sent".
extension ActionReceipt.Item {
    /// Actions of the writing MCP tools.
    public static let appActions: Set<String> = ["calendarAdd", "reminderAdd", "mailDraft"]

    /// "Open draft": a mail draft that is in Mail or may be.
    public var canOpenMailDraft: Bool { action == "mailDraft" && (outcome == "done" || outcome == "unclear") }

    /// Opening Reminders reveals the app, not an exact item: macOS exposes no supported reminder deep link.
    public var canOpenReminders: Bool { action == "reminderAdd" && (outcome == "done" || outcome == "unclear") }

    /// Only a durable, unresolved reminder has authoritative state to recheck. Legacy receipts cannot be replayed.
    public var canCheckReminderStatus: Bool {
        action == "reminderAdd" && outcome == "unclear" && operationID != nil && nativeRevision != nil
    }

    /// A known permission denial can open the relevant privacy pane. It never authorizes or retries an action.
    public var permissionSettingsIntegration: Integration? {
        guard reason == "denied", ["failed", "blocked", "declined"].contains(outcome) else { return nil }
        return switch action {
        case "calendarAdd": .calendar
        case "reminderAdd": .reminders
        case "mailDraft": .mail
        default: nil
        }
    }

    /// Preserve legacy native-write receipts; a successful Photos search can still have denied library previews.
    public var permissionRepairTarget: PermissionRepairTarget? {
        if let permissionRepair,
           ["failed", "blocked", "declined"].contains(outcome)
            || (action == "read" && outcome == "done" && permissionRepair == .photos) { return permissionRepair }
        return permissionSettingsIntegration.map(PermissionRepairTarget.init(integration:))
    }

    func appLine(language: String?) -> String {
        if outcome == "cancelled" {
            return switch action {
            case "calendarAdd": L("Stopped before adding anything to Calendar", table: "Thought", language: language)
            case "reminderAdd": L("Stopped before adding a reminder", table: "Thought", language: language)
            default: L("Stopped before creating a draft in Mail", table: "Thought", language: language)
            }
        }
        if reason == "pending" {
            return switch action {
            case "calendarAdd": L("Calendar hasn’t confirmed the result yet. Check Calendar before trying again.", table: "Thought", language: language)
            case "reminderAdd": L("Reminders hasn’t confirmed the result yet. Check Reminders before trying again.", table: "Thought", language: language)
            default: L("Mail hasn’t confirmed the draft yet. Check Mail before trying again. Nothing was sent.", table: "Thought", language: language)
            }
        }
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
            return calendar ? L("Added to Calendar: %@", table: "Thought", language: language, what)
                            : L("Reminder added: %@", table: "Thought", language: language, what)
        case "declined", "blocked", "failed":
            let base = calendar ? L("Not added to Calendar: %@", table: "Thought", language: language, what)
                                : L("Reminder not added: %@", table: "Thought", language: language, what)
            if reason == "busy" { return L("%@ (that time is already taken)", table: "Thought", language: language, base) }
            return suffix(base, language: language)
        default:
            return L("Unclear whether it happened: %@", table: "Thought", language: language, what)
        }
    }

    /// As with files: declined (the person's own "no" on the Mac's question), failed.
    private func suffix(_ base: String, language: String?) -> String {
        outcome == "declined" ? L("%@ (you said no)", table: "Thought", language: language, base)
                              : L("%@ (didn’t work)", table: "Thought", language: language, base)
    }
}
