import Foundation

/// General starters belong to an empty input. Supplied material and open workflows
/// already offer specific next steps, which must stay at the top of the conversation.
public enum ConversationEntryPresentation {
    /// Adding context creates a system notice. That notice must not consume the chance to choose an action.
    /// User/assistant messages and completed work receipts do mark the context as already used.
    public static func showsContextActions(messages: [ConversationMessage], isWorking: Bool) -> Bool {
        !isWorking && !ConversationContext.startsNewConversation(messages: messages)
    }

    public static func showsWelcome(messageCount: Int, isWorking: Bool, hasWorkflow: Bool,
                                    context: ConversationContext?) -> Bool {
        messageCount == 0 && !isWorking && !hasWorkflow
            && context?.selectedText == nil && context?.files.isEmpty != false
    }
}
