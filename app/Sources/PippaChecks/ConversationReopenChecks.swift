import Foundation
import PippaCore

@MainActor func runConversationReopenChecks() {
    let last = Date(timeIntervalSince1970: 1_790_000_000)
    check("Reopen: before ten minutes restores the conversation, including backward clock changes") {
        [-100.0, 0, 599.999].allSatisfy {
            ConversationReopenPolicy.destination(lastActivity: last, now: last.addingTimeInterval($0)) == .conversation
        }
    }
    check("Reopen: from ten minutes to under an hour chooses compact presentation") {
        [600.0, 600.001, 3_599.999].allSatisfy {
            ConversationReopenPolicy.destination(lastActivity: last, now: last.addingTimeInterval($0)) == .compact
        }
    }
    check("Reopen: an hour and later starts a new topic by itself") {
        [3_600.0, 10_800, 86_400, 30 * 86_400].allSatisfy {
            ConversationReopenPolicy.destination(lastActivity: last, now: last.addingTimeInterval($0)) == .fresh
        }
    }
    check("Reopen: active work and unreviewed actions stay visible at every age") {
        [0.0, 600, 86_400].allSatisfy {
            ConversationReopenPolicy.destination(lastActivity: last, now: last.addingTimeInterval($0), requiresAttention: true) == .conversation
        }
    }
}
