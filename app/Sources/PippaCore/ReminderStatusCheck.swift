import Foundation

/// A person's explicit read-only check is bound to the receipt they clicked, even if they switch conversations.
/// The caller supplies native readback; this coordinator has no native writer or permission-request capability.
@MainActor public final class ReminderStatusCheck {
    public struct Request: Sendable, Equatable {
        public let conversationID: UUID
        public let messageID: UUID
        public let operationID: UUID
        private let token = UUID()
        fileprivate init(conversationID: UUID, messageID: UUID, operationID: UUID) {
            self.conversationID = conversationID; self.messageID = messageID; self.operationID = operationID
        }
    }

    public enum Phase: Sendable, Equatable { case checking, confirmed, unconfirmed, updated, unavailable }

    public struct State: Sendable, Equatable {
        public let request: Request
        public let phase: Phase
        fileprivate init(_ request: Request, _ phase: Phase) { self.request = request; self.phase = phase }
    }

    public private(set) var state: State?
    public var isRunning: Bool { active != nil }
    private var active: Request?
    private var lookupStarted = false

    public init() {}

    /// Claim before scheduling a task so two clicks cannot start two lookups.
    public func begin(conversationID: UUID, messageID: UUID, operationID: UUID, store: ConversationStore) -> Request? {
        guard active == nil,
              let conversation = try? store.load(conversationID),
              conversation.messages.first(where: { $0.id == messageID })?.actions?.items.contains(where: {
                  $0.operationID == operationID && $0.canCheckReminderStatus
              }) == true else { return nil }
        let request = Request(conversationID: conversationID, messageID: messageID, operationID: operationID)
        active = request; lookupStarted = false; state = State(request, .checking)
        return request
    }

    /// No retry is dispatched. Missing, ambiguous or inaccessible native evidence leaves the existing receipt intact.
    @discardableResult public func run(_ request: Request, store: ConversationStore,
        lookup: @Sendable (UUID, UUID) async throws -> [NativeReminderRecord]) async -> Conversation? {
        guard active == request, !lookupStarted else { return nil }
        lookupStarted = true
        defer { active = nil; lookupStarted = false }
        do {
            let records = try await lookup(request.conversationID, request.operationID)
            try Task.checkCancellation()
            // Reject unrelated or duplicate records rather than borrowing evidence from another operation.
            let matches = records.filter { $0.id == request.operationID && $0.origin?.conversationID == request.conversationID }
            guard matches.count == 1, let record = matches.first, let origin = record.origin else {
                state = State(request, .unavailable); return nil
            }
            let prior = try store.load(request.conversationID)
            guard prior.messages.first(where: { $0.id == request.messageID })?.actions?.items.contains(where: {
                      $0.operationID == request.operationID && $0.action == "reminderAdd"
                  }) == true,
                  prior.messages.contains(where: { $0.id == origin.requestID && $0.role == .user }) else {
                state = nil; return nil
            }
            let updated = try store.recordRecoveredNativeWrites([(origin.requestID, record.receipt.item)], in: request.conversationID)
            // History rejects stale revisions and preserves later confirmations. Present that accepted state.
            let items = updated.messages.flatMap { $0.actions?.items ?? [] }.filter { $0.operationID == request.operationID }
            let phase: Phase = items.contains(where: { $0.happened }) ? .confirmed
                : items.contains(where: { $0.outcome == "unclear" }) ? .unconfirmed : .updated
            state = State(request, phase)
            return updated
        } catch ConversationStoreError.unknownConversation {
            // A lookup must never recreate a conversation deleted while it was running.
            state = nil
            return nil
        } catch {
            state = State(request, .unavailable)
            return nil
        }
    }
}
