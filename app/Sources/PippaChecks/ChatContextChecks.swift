import Foundation
import PippaCore

func runChatContextChecks() {
    check("Pi context: existing initialisation keeps an empty work state") {
        let context = ChatContext(selectedText: "Auswahl")
        return context.workflowSummary.isEmpty && context.maximumFileCount == 19
    }
    check("Pi context: selection and work state each reserve a document slot") {
        let files = (0..<18).map { URL(fileURLWithPath: "/tmp/context-\($0)") }
        let context = ChatContext(files: files, selectedText: "Auswahl", workflowSummary: "Vorschau: noch nicht angewendet")
        try context.validate()
        return context.maximumFileCount == 18 && context.workflowSummary == "Vorschau: noch nicht angewendet"
    }
    check("Pi context: 19 files plus selection and work state are rejected before reading") {
        let files = (0..<19).map { URL(fileURLWithPath: "/tmp/context-\($0)") }
        do {
            try ChatContext(files: files, selectedText: "Auswahl", workflowSummary: "Arbeitsstand").validate()
            return false
        } catch { return true }
    }
    check("Pi context: without inline context 20 files remain possible") {
        let files = (0..<20).map { URL(fileURLWithPath: "/tmp/context-\($0)") }
        try ChatContext(files: files).validate()
        return ChatContext(files: files).maximumFileCount == 20
    }
}

func runChatContextReadingChecks() async {
    await checkAsync("Pi context: newest attachment is the focus, comparison sources are kept") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("strategy.md"), latest = folder.appendingPathComponent("underdog.md")
        try "Strategy source".write(to: old, atomically: true, encoding: .utf8)
        try "Underdog source".write(to: latest, atomically: true, encoding: .utf8)
        let snapshots = try await LocalEngine.snapshots(for: .init(files: [old, latest], focusedFiles: [latest]))
        let unreadable = try await LocalEngine.snapshots(for: .init(files: [old, folder.appendingPathComponent("missing.md")], focusedFiles: [folder.appendingPathComponent("missing.md")]))
        return snapshots.count == 2 && snapshots[0].text == "Strategy source"
            && snapshots[1].focused && snapshots[1].text.contains("Underdog source")
            && unreadable[1].focused && unreadable[1].truncated
    }

    await checkAsync("Pi context: a moved source blocks neither the evidence nor other documents") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("Vorhanden.txt")
        try "Dieses Dokument ist vorhanden und enthält weiterhin lesbaren Text.".write(to: existing, atomically: true, encoding: .utf8)
        let missing = folder.appendingPathComponent("Verschoben.txt")
        let snapshots = try await LocalEngine.snapshots(for: ChatContext(files: [missing, existing], workflowSummary: "Bestätigter Beleg: Verschoben.txt wurde nach Dokumente verschoben."))
        return snapshots.count == 3
            && snapshots[0].text.contains("Bestätigter Beleg")
            && snapshots[1].text.contains("Ihr Inhalt wurde nicht gelesen") && snapshots[1].truncated
            && snapshots[2].text.contains("weiterhin lesbaren Text")
    }
}
