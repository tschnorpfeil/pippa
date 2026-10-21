import Foundation
import PippaCore

@MainActor func runConversationEntryChecks() {
    func welcome(_ context: ConversationContext? = nil, messages: Int = 0,
                 working: Bool = false, workflow: Bool = false) -> Bool {
        ConversationEntryPresentation.showsWelcome(messageCount: messages, isWorking: working,
                                                   hasWorkflow: workflow, context: context)
    }

    check("Conversation entry: an empty conversation keeps the everyday starters") {
        welcome() && welcome(ConversationContext(name: "New Conversation"))
    }
    check("Conversation entry: selected-text actions are not buried beneath general starters") {
        !welcome(ConversationContext(name: "Selected Text", selectedText: "Please review this sentence."))
    }
    check("Conversation entry: attachment notices leave contextual actions available") {
        let notices = [ConversationMessage(role: .system, text: "Added: Text"),
                       ConversationMessage(role: .system, text: "Added: example.pdf")]
        return ConversationEntryPresentation.showsContextActions(messages: notices, isWorking: false)
    }
    check("Conversation entry: answers and completed work retire contextual starters") {
        let used = [ConversationMessage(role: .user, text: "Summarize this"),
                    ConversationMessage(role: .assistant, text: "A summary"),
                    ConversationMessage(role: .system, text: "Done", receipt: UUID())]
        return used.allSatisfy { !ConversationEntryPresentation.showsContextActions(messages: [$0], isWorking: false) }
            && !ConversationEntryPresentation.showsContextActions(messages: [], isWorking: true)
    }
    check("Conversation entry: a given file or folder shows its own actions first") {
        [URL(fileURLWithPath: "/tmp/example.pdf"), URL(fileURLWithPath: "/tmp/example", isDirectory: true)]
            .allSatisfy { !welcome(ConversationContext(name: "Given", files: [$0])) }
    }
    check("Conversation entry: an open preview takes priority before the first chat message") {
        !welcome(workflow: true)
    }
    check("Conversation entry: work and existing history do not regain general starters") {
        !welcome(working: true) && !welcome(messages: 1)
    }
    check("Conversation entry: removing the last supplied item restores general starters") {
        var context = ConversationContext(name: "Given", files: [URL(fileURLWithPath: "/tmp/example.txt")],
                                          selectedText: "Example")
        context.files = []
        let textStillPresent = welcome(context)
        context.selectedText = nil
        return !textStillPresent && welcome(context)
    }
    check("Action menu: every photo action remains reachable after the suggestion cap") {
        let photo = URL(fileURLWithPath: "/tmp/example.jpg")
        let candidates = ThingActions.candidates(for: [photo], size: { _ in 0 })
        let offered = ThingActions.offered(for: [photo], records: [], size: { _ in 0 })
        let choices = ThingActionChoices(offered: offered, candidates: candidates)
        return choices.suggestions.count == 2 && offered.count == ThingActions.maxOffered
            && choices.all == candidates && choices.overflow.contains(.tool(.asPNG))
            && choices.overflow.contains(.tool(.makeSmaller))
    }
    check("Action menu: ranked overflow leads remaining actions, with no duplicate IDs") {
        let candidates: [ThingAction] = [.tool(.extractText), .tool(.removeLocation), .tool(.asPDF), .tool(.asPNG)]
        let offered: [ThingAction] = [.tool(.asPNG), .tool(.extractText), .tool(.removeLocation), .tool(.extractText)]
        let choices = ThingActionChoices(offered: offered, candidates: candidates + [.tool(.asPNG)])
        return choices.suggestions == [.tool(.asPNG), .tool(.extractText)]
            && choices.overflow == [.tool(.removeLocation), .tool(.asPDF)]
    }
    check("Action menu: faded suggestions remain discoverable without returning as buttons") {
        let candidates: [ThingAction] = [.tool(.asPDF), .tool(.asPNG)]
        let choices = ThingActionChoices(offered: [], candidates: candidates)
        return choices.suggestions.isEmpty && choices.overflow == candidates
    }
    check("Action menu: stale suggestions never expose an inapplicable action") {
        let choices = ThingActionChoices(offered: [.tool(.asPNG), .tool(.asPDF)], candidates: [.tool(.asPDF)])
        return choices.all == [.tool(.asPDF)] && choices.overflow.isEmpty
    }
}
