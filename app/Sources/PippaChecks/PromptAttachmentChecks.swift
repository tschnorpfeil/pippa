import Foundation
import PippaCore

func runPromptAttachmentChecks() {
    let a = URL(fileURLWithPath: "/first/report.pdf")
    let b = URL(fileURLWithPath: "/second/report.pdf")
    check("new documents wait at composer, distinct same basenames survive") {
        let topic = Conversation(title: "New", context: .init(name: "Files", files: [a, b]))
        return ConversationPromptAttachments.pendingFiles(in: topic) == [a, b]
            && ConversationPromptAttachments.currentFiles(in: topic).isEmpty
    }
    check("only fresh batch repeats at next prompt") {
        let topic = Conversation(title: "Followup", messages: [.init(role: .user, text: "Explain", attachments: [a])],
                                 context: .init(name: "Files", files: [a, b]))
        return ConversationPromptAttachments.pendingFiles(in: topic) == [b]
            && ConversationPromptAttachments.currentFiles(in: topic) == [a]
    }
    check("old Added notices remain used after a question") {
        let topic = Conversation(title: "Legacy", messages: [.init(role: .system, text: "Added", attachments: [a]),
            .init(role: .user, text: "Explain"), .init(role: .system, text: "Added", attachments: [b])],
            context: .init(name: "Files", files: [a, b]))
        return ConversationPromptAttachments.pendingFiles(in: topic) == [b]
            && ConversationPromptAttachments.currentFiles(in: topic) == [a]
    }
    check("explicit re-add of same document is pending again") {
        let topic = Conversation(title: "Again", messages: [.init(role: .user, text: "Explain", attachments: [a])],
            context: .init(name: "Files", files: [a, b], pendingFiles: [a, a]))
        return ConversationPromptAttachments.pendingFiles(in: topic) == [a]
            && ConversationPromptAttachments.currentFiles(in: topic) == [b]
    }
    check("removed context stays historical and cannot become pending") {
        let message = ConversationMessage(role: .user, text: "Explain", attachments: [a])
        let topic = Conversation(title: "Removed", messages: [message],
            context: .init(name: "Files", files: [b], pendingFiles: [a]))
        return ConversationPromptAttachments.pendingFiles(in: topic).isEmpty
            && ConversationPromptAttachments.currentFiles(in: topic) == [b] && topic.messages == [message]
    }
    check("explicit empty pending suppresses repeating workflow sources") {
        let topic = Conversation(title: "Used", context: .init(name: "Files", files: [a], pendingFiles: []))
        return ConversationPromptAttachments.pendingFiles(in: topic).isEmpty
            && ConversationPromptAttachments.currentFiles(in: topic) == [a]
    }
}
