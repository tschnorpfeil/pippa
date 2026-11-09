import Foundation

/// The receipt of a write call, built from Pippa's own result, never from the model's text.
public struct PippaMCPWriteReceipt: Sendable, Equatable, Codable {
    /// calendarAdd, reminderAdd, mailDraft
    public var action: String
    /// done, failed, unclear
    public var outcome: String
    /// Finished name for the row, e.g. "Do., 8. Okt., 09:00 – Zahnarzt" or "Re: Termin".
    public var name: String
    /// Mail: reply, opened, newMessage; not done: busy, notFound, denied, …
    public var reason: String?
    /// Origin and operation identity for retaining late native outcomes under the correct answer.
    public var turnID: UUID?
    public var operationID: UUID?
    public var nativeRevision: Int?
    /// What was created (events and reminders), so the receipt row can undo it. Never set for mail drafts.
    public var created: CreatedItem?
    /// After the person pressed Undo: removed, gone (already deleted), changed (edited since, so it stays), failed.
    public var undo: String?

    public init(action: String, outcome: String, name: String, reason: String? = nil, created: CreatedItem? = nil) {
        self.action = action; self.outcome = outcome; self.name = name; self.reason = reason; self.created = created
    }

    /// Undo is offered once, for an event or reminder Pippa created and nothing has been tried on it yet.
    public var canUndo: Bool { outcome == "done" && created != nil && undo == nil }

    /// The receipt line.
    public var item: ActionReceipt.Item { ActionReceipt.Item(action: action, outcome: outcome, name: name, reason: reason, operationID: operationID, nativeRevision: nativeRevision) }
}
