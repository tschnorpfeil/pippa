import Foundation
import PippaCore

/// Tracks in-flight title refinement tasks per `ChatModel` instance and conversation so newer requests cancel older ones
/// without adding stored properties to `ChatModel.swift`.
@MainActor
private enum TitleRefinementRegistry {
    private struct Key: Hashable {
        let model: ObjectIdentifier
        let conversationID: String
    }

    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private static var entries: [Key: Entry] = [:]

    static func start(
        for model: ChatModel,
        conversationID: String,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let key = Key(model: ObjectIdentifier(model), conversationID: conversationID)
        entries[key]?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor in
            await operation()
            if entries[key]?.token == token {
                entries[key] = nil
            }
        }
        entries[key] = Entry(token: token, task: task)
        return task
    }

    static func cancel(for model: ChatModel, conversationID: String) {
        let key = Key(model: ObjectIdentifier(model), conversationID: conversationID)
        entries.removeValue(forKey: key)?.task.cancel()
    }
}

/// Asynchronous on-device conversation title refinement for `ChatModel`.
@MainActor
extension ChatModel {
    /// Refines a conversation's provisional title asynchronously using `reflex`.
    /// Cancels any prior refinement task for the same conversation and never overwrites a manual user rename.
    @discardableResult
    func refineTitleIfUnchanged(
        conversationID: String,
        initialTitle: String,
        prompt: String,
        language: String = Bundle.module.preferredLocalizations.first ?? "en",
        reflex: any LocalReflexModel = AppleFoundationReflex()
    ) -> Task<Void, Never>? {
        TitleRefinementRegistry.cancel(for: self, conversationID: conversationID)
        let boundedPrompt = LocalReflexTitleSanitizer.truncateInput(prompt)
        guard !boundedPrompt.isEmpty, reflex.isAvailable else { return nil }
        return TitleRefinementRegistry.start(for: self, conversationID: conversationID) { [weak self] in
            let refined = await reflex.conversationTitle(for: boundedPrompt, language: language)
            guard !Task.isCancelled, let self else { return }
            guard let index = self.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            let currentTitle = self.conversations[index].title
            guard let nextTitle = ConversationTitlePolicy.resolvedTitle(
                current: currentTitle,
                initial: initialTitle,
                refined: refined
            ) else {
                return
            }
            self.conversations[index].title = nextTitle
            self.save(conversationID)
        }
    }

    /// Cancels any in-flight title refinement for `conversationID`.
    func cancelTitleRefinement(for conversationID: String) {
        TitleRefinementRegistry.cancel(for: self, conversationID: conversationID)
    }
}
