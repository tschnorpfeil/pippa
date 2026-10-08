import Foundation

/// Presentation choice on explicit reopen. It never mutates the conversation or schedules a timer.
public enum ConversationReopenPolicy {
    public static let compactAfter: TimeInterval = 10 * 60

    public enum Destination: Equatable, Sendable {
        case conversation
        case compact
    }

    public static func destination(lastActivity: Date, now: Date, requiresAttention: Bool = false) -> Destination {
        if requiresAttention { return .conversation }
        return now.timeIntervalSince(lastActivity) < compactAfter ? .conversation : .compact
    }
}
