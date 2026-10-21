import Foundation
import PippaCore

func runConversationRetryChecks() {
    check("Conversation retry retains source identity and detects changed, replaced, removed and newly selected material") {
        let folder = dir("conversation-retry")
        let file = folder.appendingPathComponent("Letter.txt")
        write("original", file)
        let context = ConversationContext(name: "Letter", files: [file], selectedText: "selected", focusedFiles: [file])
        let guardSource = ConversationRetryGuard(context: context)
        guard guardSource.matches(context: context) else { return false }
        var changed = context
        changed.selectedText = "a new selection"
        guard !guardSource.matches(context: changed) else { return false }
        changed = context; changed.focusedFiles = []
        guard !guardSource.matches(context: changed) else { return false }
        write("different contents with a different size", file)
        guard !guardSource.matches(context: context) else { return false }
        try FileManager.default.removeItem(at: file)
        guard !guardSource.matches(context: context) else { return false }
        write("replacement source", file)
        return !guardSource.matches(context: context)
    }
    check("Conversation retry permits unchanged text-only context and refuses an unreadable original file") {
        let text = ConversationContext(name: "Selection", selectedText: "A useful question")
        let missing = ConversationContext(name: "Missing", files: [dir("conversation-retry-missing").appendingPathComponent("missing.txt")])
        return ConversationRetryGuard(context: nil).matches(context: nil)
            && ConversationRetryGuard(context: text).matches(context: text)
            && !ConversationRetryGuard(context: text).matches(context: nil)
            && !ConversationRetryGuard(context: missing).matches(context: missing)
    }
    check("Conversation retry refuses folder and symlink snapshots whose targets could have changed") {
        let folder = dir("conversation-retry-link")
        let target = folder.appendingPathComponent("target.txt"), link = folder.appendingPathComponent("link.txt")
        write("original target", target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let directory = ConversationContext(name: "Folder", files: [folder])
        let linked = ConversationContext(name: "Link", files: [link])
        return !ConversationRetryGuard(context: directory).matches(context: directory)
            && !ConversationRetryGuard(context: linked).matches(context: linked)
    }
}
