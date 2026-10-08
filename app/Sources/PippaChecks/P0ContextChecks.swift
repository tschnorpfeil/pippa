import Foundation
import PippaCore

/// Offline acceptance of the durable source boundary and real extraction path.
/// AppModel attachment routing and ConversationController callback races need native fixtures.
@MainActor private func runP0ContextStoreChecks() {
    check("P0 CTX: separate pre-question batches retain both paths and newest focus after reopening") {
        let store = try ConversationStore(directory: dir("p0-context-before-question"))
        let topic = try store.create()
        let first = URL(fileURLWithPath: "/first/report.md")
        let second = URL(fileURLWithPath: "/second/report.md")
        _ = try store.setContext(.init(name: "report.md", files: [first], focusedFiles: [first]), for: topic.id)
        let added = try store.append(.init(role: .system, text: "Added", attachments: [first]), to: topic.id)
        guard !ConversationContext.startsNewConversation(messages: added.messages) else { return false }
        _ = try store.setContext(.init(name: "2 files", files: [first, second], focusedFiles: [second]), for: topic.id)
        let loaded = try ConversationStore(directory: store.fileURL.deletingLastPathComponent()).load(topic.id)
        return loaded.context?.files == [first, second] && loaded.context?.focusedFiles == [second]
            && loaded.modelSessionRevision == nil && loaded.messages == added.messages
    }

    check("P0 CTX: explicit comparison addition preserves topic, selection and model revision") {
        let store = try ConversationStore(directory: dir("p0-context-explicit-add"))
        let topic = try store.create()
        let first = URL(fileURLWithPath: "/one/strategy.md"), second = URL(fileURLWithPath: "/two/report.md")
        _ = try store.setContext(.init(name: "Strategy", files: [first], selectedText: "Selected passage", focusedFiles: [first]), for: topic.id)
        let worked = try store.append(.init(role: .user, text: "Explain the strategy"), to: topic.id)
        guard ConversationContext.startsNewConversation(messages: worked.messages) else { return false }
        let combined = try store.setContext(.init(name: "Comparison", files: [first, second], selectedText: "Selected passage", focusedFiles: [second]), for: topic.id)
        return combined.id == topic.id && store.selectedID == topic.id && combined.messages == worked.messages
            && combined.context?.files == [first, second] && combined.modelSessionRevision == worked.modelSessionRevision
    }

    check("P0 CTX: removing newest and last source rotates session once each and preserves historical attachments") {
        let store = try ConversationStore(directory: dir("p0-context-source-removal"))
        let topic = try store.create()
        let first = URL(fileURLWithPath: "/first/report.md"), second = URL(fileURLWithPath: "/second/report.md")
        _ = try store.setContext(.init(name: "Both", files: [first, second], focusedFiles: [second]), for: topic.id)
        let message = ConversationMessage(role: .user, text: "Compare", attachments: [first, second])
        _ = try store.append(message, to: topic.id)
        let remaining = ConversationContext(name: "First", files: [first], focusedFiles: [])
        let removed = try store.setContext(remaining, for: topic.id)
        guard let revision = removed.modelSessionRevision else { return false }
        let unchanged = try store.setContext(remaining, for: topic.id)
        guard unchanged.modelSessionRevision == revision else { return false }
        let cleared = try store.setContext(nil, for: topic.id)
        guard cleared.modelSessionRevision != nil, cleared.modelSessionRevision != revision else { return false }
        let loaded = try ConversationStore(directory: store.fileURL.deletingLastPathComponent()).load(topic.id)
        return loaded.context == nil && loaded.messages == [message]
            && loaded.modelSessionRevision == cleared.modelSessionRevision
            && loaded.retiredModelSessionRevisions == [revision] && store.contextFiles().isEmpty
    }

    check("P0 CTX: replacing selected text invalidates model session without losing visible history") {
        let store = try ConversationStore(directory: dir("p0-context-selection-reset"))
        let topic = try store.create()
        _ = try store.setContext(.init(name: "Selection", selectedText: "Old selection"), for: topic.id)
        let history = try store.append(.init(role: .assistant, text: "Historical answer"), to: topic.id)
        let replaced = try store.setContext(.init(name: "Selection", selectedText: "New selection"), for: topic.id)
        guard let revision = replaced.modelSessionRevision else { return false }
        let cleared = try store.setContext(nil, for: topic.id)
        return replaced.messages == history.messages && cleared.messages == history.messages
            && cleared.modelSessionRevision != revision && cleared.retiredModelSessionRevisions == [revision]
    }

}

func runP0ContextChecks() async {
    await runP0ContextStoreChecks()
    await checkAsync("P0 CTX: same basename in distinct paths reads distinct sources and focuses only latest path") {
        let folder = dir("p0-context-same-name")
        let a = folder.appendingPathComponent("a", isDirectory: true), b = folder.appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let old = a.appendingPathComponent("report.md"), latest = b.appendingPathComponent("report.md")
        try "Strategy: launch 15 November.".write(to: old, atomically: true, encoding: .utf8)
        try "Underdog: launch 20 November.".write(to: latest, atomically: true, encoding: .utf8)
        let snapshots = try await LocalEngine.snapshots(for: .init(files: [old, latest], focusedFiles: [latest]))
        // DocumentText.capped appends a newline for each non-paged text chunk.
        // Keep exact source equality, including that production normalization.
        return snapshots.count == 2 && snapshots[0].name == snapshots[1].name
            && snapshots[0].text == "Strategy: launch 15 November.\n" && !snapshots[0].focused
            && snapshots[1].text == "Underdog: launch 20 November.\n" && snapshots[1].focused
    }

    await checkAsync("P0 CTX: unreadable latest source stays focused without borrowing same-name old contents") {
        let folder = dir("p0-context-unreadable-latest")
        let old = folder.appendingPathComponent("report.md"), missing = folder.appendingPathComponent("missing/report.md")
        try "OLD_SOURCE_SENTINEL".write(to: old, atomically: true, encoding: .utf8)
        let snapshots = try await LocalEngine.snapshots(for: .init(files: [old, missing], focusedFiles: [missing]))
        guard snapshots.count == 2 else { return false }
        return snapshots[0].text == "OLD_SOURCE_SENTINEL\n" && !snapshots[0].focused
            && snapshots[1].focused && snapshots[1].truncated
            && snapshots[1].text.contains("Ihr Inhalt wurde nicht gelesen")
            && !snapshots[1].text.contains("OLD_SOURCE_SENTINEL")
    }
}
