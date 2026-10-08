import Foundation
import PippaCore

// "Tidy my Downloads" in conversation goes like a calendar question to Pippa's native flow, not to Pi: preview as a card, one run, one
// undo for the whole job (executor + journal). Recognized in code (TidyIntent); unclear documents are sorted by
// LocalEngine with the shared llama-server (`useSharedServer`); without a model they stay in place.
// Moving or renaming individual files stays with Pi.
extension AppModel {

    /// User folder for Downloads, Documents, Desktop. In developer runs with a fake HOME (`PIPPA_PI_HOME`,
    /// as Pi sees it) its folder, otherwise the real one.
    var tidyHome: URL {
        DevEnvironment.value("PIPPA_PI_HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The folder the person is currently showing (exactly one): working place of the tray or the only folder in the conversation.
    var shownTidyFolder: URL? {
        if let ctx = context, ctx.isFolder, let folder = ctx.items.first { return folder }
        let folders = (conversations.current?.context?.files ?? []).filter { url in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }
        return folders.count == 1 ? folders[0] : nil
    }

    func tidyIntent(for text: String) -> TidyIntent? {
        TidyIntent.parse(text, shownFolder: shownTidyFolder, home: tidyHome)
    }

    /// Native tidy flow from the conversation: the message is in the history, the preview below it.
    /// The shown folder stays shown; a named everyday folder does not become the conversation's shown item.
    func answerTidy(_ question: String, intent: TidyIntent) {
        conversations.append(.user, question)
        let source = switch intent.source { case .shownFolder: "gezeigt"; case .named: "genannt"; case .found: "name" }
        DiagnosticsLog.shared.event("aufraeumen-nativ", ["quelle": source])
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: intent.folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            conversations.append(.system, T("I can’t find the folder “%@” on this Mac.", table: "App", intent.folder.lastPathComponent), notice: true)
            return
        }
        // Like "Tidy" in the overview: whole folder, first round limited (PreSort.firstRunLimit).
        proposeSort(items: nil, scope: intent.folder, limit: PreSort.firstRunLimit)
    }
}
