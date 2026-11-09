import AppKit
import PippaCore
import SwiftUI

/// What a writing tool did: added to Calendar, a reminder, a Mail draft. Done ones open the app; an added event or
/// reminder can be undone once, and only if nobody changed it since (`PippaMCPHost.undo`).
struct ReceiptRow: View {
    var receipt: PippaMCPWriteReceipt
    var undoing = false
    /// `nil`: no Undo here (the context panel, or while the answer is still running).
    var undo: (() -> Void)? = nil
    private var removed: Bool { receipt.undo == "removed" }
    private var done: Bool { receipt.outcome == "done" && !removed }

    var body: some View {
        HStack(spacing: Space.ml) {
            Image(systemName: removed ? "arrow.uturn.backward" : Self.symbol(receipt))
                .font(Typo.footnote.weight(.semibold))
                .foregroundStyle(removed ? Theme.ink2 : done ? Theme.ok : Theme.need)
                .frame(width: 28, height: 28)
                .background(removed ? Theme.fill2 : done ? Theme.okTint : Theme.needTint,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(receipt)).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                if !receipt.name.isEmpty {
                    Text(receipt.name).font(Typo.footnote).foregroundStyle(Theme.ink2).lineLimit(2)
                        .strikethrough(removed, color: Theme.ink3)
                }
                if let note = Self.undoNote(receipt) {
                    Text(note).font(Typo.footnote).foregroundStyle(Theme.need).lineLimit(2)
                }
            }
            Spacer(minLength: Space.m)
            if let undo, receipt.canUndo {
                if undoing { ProgressView().controlSize(.small) } else { ActionPill(title: T("Undo", table: "App"), action: undo) }
            }
            if !removed, let open = Self.openAction(receipt), let label = Self.openLabel(receipt) {
                ActionPill(title: label, action: open)
            }
        }
        .padding(Space.ml)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .raised(Radius.card)
    }

    static func symbol(_ receipt: PippaMCPWriteReceipt) -> String {
        switch receipt.action {
        case "calendarAdd": return "calendar.badge.plus"
        case "reminderAdd": return "checklist"
        case "mailDraft": return "envelope"
        default: return "checkmark"
        }
    }

    static func title(_ receipt: PippaMCPWriteReceipt) -> String {
        let done = receipt.outcome == "done"
        if receipt.undo == "removed" {
            switch receipt.action {
            case "calendarAdd": return T("Removed from Calendar", table: "App")
            case "reminderAdd": return T("Reminder removed", table: "App")
            default: break
            }
        }
        switch receipt.action {
        case "calendarAdd": return done ? T("Added to Calendar", table: "App") : T("Not added to Calendar", table: "App")
        case "reminderAdd": return done ? T("Reminder added", table: "App") : T("No reminder added", table: "App")
        case "mailDraft": return done ? T("Draft in Mail, not sent", table: "App") : T("No Mail draft", table: "App")
        default: return receipt.name
        }
    }

    /// Why an Undo did not remove anything; the entry stays as it is.
    static func undoNote(_ receipt: PippaMCPWriteReceipt) -> String? {
        switch receipt.undo {
        case "gone": T("Not undone: it was already deleted.", table: "App")
        case "changed": T("Not undone: it was changed since, so it stays.", table: "App")
        case "failed": T("Couldn’t undo it. You can delete it in the app.", table: "App")
        default: nil
        }
    }

    private static func openLabel(_ receipt: PippaMCPWriteReceipt) -> String? {
        switch receipt.action {
        case "calendarAdd": return T("Open Calendar", table: "App")
        case "reminderAdd": return T("Open Reminders", table: "App")
        case "mailDraft": return T("Open Mail", table: "App")
        default: return nil
        }
    }

    /// Brings the app with what was added to the front; `nil` when nothing was added.
    static func openAction(_ receipt: PippaMCPWriteReceipt) -> (() -> Void)? {
        guard receipt.outcome == "done" else { return nil }
        switch receipt.action {
        case "mailDraft": return { Task { await PippaMCPService.showMail() } }
        case "calendarAdd": return { bringForward(.calendar) }
        case "reminderAdd": return { bringForward(.reminders) }
        default: return nil
        }
    }

    /// With PIPPA_DEMO=1 nothing (no real apps).
    private static func bringForward(_ integration: Integration) {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1",
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: config)
    }
}
