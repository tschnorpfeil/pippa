import Foundation

/// Separates new prompt documents from sources already used by this conversation.
/// It does not read files or rewrite historical messages.
public enum ConversationPromptAttachments {
    public static func pendingFiles(in conversation: Conversation) -> [URL] {
        guard let context = conversation.context else { return [] }
        if let explicit = context.pendingFiles {
            let active = Set(context.files.map(key))
            return unique(explicit.filter { active.contains(key($0)) })
        }
        var used = Set<String>()
        // Older versions stored Give batches in system notices. A subsequent request
        // or result means that batch was used; keep its evidence at that original notice.
        var legacyBatch: [URL] = []
        for message in conversation.messages {
            if message.role == .system && !message.attachments.isEmpty {
                legacyBatch.append(contentsOf: message.attachments)
            }
            if message.role == .user || message.role == .assistant || message.receipt != nil {
                used.formUnion(legacyBatch.map(key))
                legacyBatch.removeAll()
            }
            if message.role == .user { used.formUnion(message.attachments.map(key)) }
        }
        // Old workflows could produce a result without an Added notice or user prompt.
        if conversation.messages.contains(where: { $0.role == .assistant || $0.receipt != nil }),
           !conversation.messages.contains(where: { !$0.attachments.isEmpty }) {
            used.formUnion(context.files.map(key))
        }
        return unique(context.files.filter { !used.contains(key($0)) })
    }

    public static func currentFiles(in conversation: Conversation) -> [URL] {
        let pending = Set(pendingFiles(in: conversation).map(key))
        return unique((conversation.context?.files ?? []).filter { !pending.contains(key($0)) })
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert(key($0)).inserted }
    }
}
