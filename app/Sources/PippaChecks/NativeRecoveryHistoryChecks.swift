import Foundation
import PippaCore

@MainActor func runNativeRecoveryHistoryChecks() {
    check("Recovered reminder status updates its original answer across conversations and survives reopening") {
        let directory = dir("native-recovery-history")
        let store = try ConversationStore(directory: directory)
        let original = try store.create(title: "Original task")
        let request = ConversationMessage(role: .user, text: "Add a synthetic reminder")
        _ = try store.append(request, to: original.id)
        let operation = UUID()
        let pending = ActionReceipt.Item(action: "reminderAdd", outcome: "unclear", name: "Synthetic reminder", operationID: operation)
        let answer = ConversationMessage(role: .assistant, text: "Waiting for confirmation", actions: ActionReceipt(items: [pending]))
        _ = try store.append(answer, to: original.id)
        let other = try store.create(title: "Other conversation")
        let confirmed = ActionReceipt.Item(action: "reminderAdd", outcome: "done", name: "Synthetic reminder", operationID: operation)
        let updated = try store.recordRecoveredNativeWrites([(request.id, confirmed)], in: original.id)
        let unchanged = try store.recordRecoveredNativeWrites([(request.id, pending)], in: original.id)
        let reopened = try ConversationStore(directory: directory)
        let saved = try reopened.load(original.id)
        return updated.messages.count == 2 && updated.messages[1].id == answer.id
            && updated.messages[1].actions?.items == [confirmed] && unchanged == updated
            && reopened.selectedID == other.id && saved == updated
    }
    check("A crash before saving an answer inserts status beside its request, before a later unrelated request") {
        let store = try ConversationStore(directory: dir("native-recovery-no-answer"))
        let conversation = try store.create(title: "Interrupted task")
        let request = ConversationMessage(role: .user, text: "Original request")
        let later = ConversationMessage(role: .user, text: "Later unrelated request")
        _ = try store.append(request, to: conversation.id)
        _ = try store.append(later, to: conversation.id)
        let item = ActionReceipt.Item(action: "reminderAdd", outcome: "unclear", name: "Synthetic reminder", operationID: UUID())
        let first = try store.recordRecoveredNativeWrites([(request.id, item)], in: conversation.id)
        let repeated = try store.recordRecoveredNativeWrites([(request.id, item)], in: conversation.id)
        return first.messages.count == 3 && first.messages[0].id == request.id && first.messages[2].id == later.id
            && first.messages[1].role == .system && first.messages[1].notice == true
            && first.messages[1].actions?.items == [item] && repeated == first
    }
    check("Recovery ignores unknown request identities and never recreates deleted history") {
        let store = try ConversationStore(directory: dir("native-recovery-deleted"))
        let conversation = try store.create(title: "Deleted task")
        let item = ActionReceipt.Item(action: "reminderAdd", outcome: "done", name: "Synthetic reminder", operationID: UUID())
        let ignored = try store.recordRecoveredNativeWrites([(UUID(), item)], in: conversation.id)
        guard ignored.messages.isEmpty else { return false }
        try store.delete(conversation.id)
        do { _ = try store.recordRecoveredNativeWrites([(UUID(), item)], in: conversation.id); return false }
        catch ConversationStoreError.unknownConversation { return !store.list().contains { $0.id == conversation.id } }
    }
    check("Recovery updates every retry receipt so the newest prompt evidence retains confirmed completion") {
        let store = try ConversationStore(directory: dir("native-recovery-retried"))
        let conversation = try store.create(title: "Retried task")
        let original = ConversationMessage(role: .user, text: "Original reminder request")
        _ = try store.append(original, to: conversation.id)
        let operation = UUID()
        let pending = ActionReceipt.Item(action: "reminderAdd", outcome: "unclear", operationID: operation, nativeRevision: 2)
        _ = try store.append(.init(role: .system, text: "Interrupted", actions: .init(items: [pending])), to: conversation.id)
        _ = try store.append(.init(role: .user, text: "Explicit retry"), to: conversation.id)
        _ = try store.append(.init(role: .assistant, text: "Still unconfirmed", actions: .init(items: [pending])), to: conversation.id)
        let confirmed = ActionReceipt.Item(action: "reminderAdd", outcome: "done", operationID: operation, nativeRevision: 3)
        let updated = try store.recordRecoveredNativeWrites([(original.id, confirmed)], in: conversation.id)
        return updated.messages.compactMap(\.actions).flatMap(\.items) == [confirmed, confirmed]
            && NativeReceiptContext.summary(messages: updated.messages).contains("\"outcome\":\"done\"")
            && !NativeReceiptContext.summary(messages: updated.messages).contains("\"outcome\":\"unclear\"")
    }
    check("An older startup recovery cannot replace a newer dispatched retry with a no-effect receipt") {
        let store = try ConversationStore(directory: dir("native-recovery-stale"))
        let conversation = try store.create(title: "Active retry")
        let request = ConversationMessage(role: .user, text: "Original request")
        _ = try store.append(request, to: conversation.id)
        let operation = UUID()
        let current = ActionReceipt.Item(action: "reminderAdd", outcome: "unclear", operationID: operation, nativeRevision: 4)
        _ = try store.append(.init(role: .assistant, text: "Retry dispatched", actions: .init(items: [current])), to: conversation.id)
        let stale = ActionReceipt.Item(action: "reminderAdd", outcome: "cancelled", operationID: operation, nativeRevision: 2)
        let updated = try store.recordRecoveredNativeWrites([(request.id, stale)], in: conversation.id)
        return updated.messages.last?.actions?.items == [current]
    }
    check("A late live reminder confirmation updates all retry rows and rejects an older callback") {
        let store = try ConversationStore(directory: dir("native-recovery-live-callback"))
        let conversation = try store.create(title: "Late confirmation")
        let request = ConversationMessage(role: .user, text: "Original reminder request")
        _ = try store.append(request, to: conversation.id)
        let operation = UUID()
        let pending = ActionReceipt.Item(action: "reminderAdd", outcome: "unclear", operationID: operation, nativeRevision: 2)
        let originalAnswer = ConversationMessage(role: .system, text: "Stopped", actions: .init(items: [pending]))
        _ = try store.append(originalAnswer, to: conversation.id)
        _ = try store.append(.init(role: .user, text: "Explicit retry"), to: conversation.id)
        _ = try store.append(.init(role: .assistant, text: "Still unconfirmed", actions: .init(items: [pending])), to: conversation.id)
        let done = ActionReceipt.Item(action: "reminderAdd", outcome: "done", operationID: operation, nativeRevision: 3)
        let updated = try store.recordNativeWrite(done, messageID: originalAnswer.id, in: conversation.id)
        let stale = try store.recordNativeWrite(pending, messageID: originalAnswer.id, in: conversation.id)
        return updated == stale && updated.messages.compactMap(\.actions).flatMap(\.items) == [done, done]
            && NativeReceiptContext.summary(messages: updated.messages).contains("\"outcome\":\"done\"")
    }
}
