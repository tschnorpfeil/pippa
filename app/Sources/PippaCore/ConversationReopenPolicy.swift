import Foundation

/// Presentation choice on explicit reopen. It never mutates the conversation or schedules a timer.
///
/// After `freshAfter` without the person's input Pippa starts a new topic by itself (no "New Topic" for the person to
/// press): the reopen shows an empty conversation, the old one stays in the history, and Pi's new session gets a short
/// handover from the old one (runtime/pippa-tools/pippa-context.ts), so "and the letter from earlier?" still works.
public enum ConversationReopenPolicy {
    public static let compactAfter: TimeInterval = 10 * 60
    public static let freshAfter: TimeInterval = 3 * 60 * 60

    public enum Destination: Equatable, Sendable {
        case conversation
        case compact
        /// A new topic: start a new conversation quietly.
        case fresh
    }

    public static func destination(lastActivity: Date, now: Date, requiresAttention: Bool = false) -> Destination {
        if requiresAttention { return .conversation }
        let quiet = now.timeIntervalSince(lastActivity)
        if quiet < compactAfter { return .conversation }
        return quiet < freshAfter ? .compact : .fresh
    }
}
