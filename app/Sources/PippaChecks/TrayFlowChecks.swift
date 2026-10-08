import Foundation
import PippaCore
import UniformTypeIdentifiers

/// The tray flow (App/TrayController.swift) from its pure parts, as the controller composes them:
/// tool → journal → shelf → undo, and the log rows for taking along and passing over.
/// The controller itself lives in the app module and is not reachable from here.
func runTrayFlowChecks() async {
    setenv("PIPPA_RESULTS_DIR", dir("trayflow-results").path, 1)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let noBookmark: (URL) -> Data? = { _ in nil }

    check("Tray: a run's results sit at the front in order, skipped items stay; undo brings the sources back") {
        let a = URL(fileURLWithPath: "/Users/test/Desktop/A.heic")
        let b = URL(fileURLWithPath: "/Users/test/Desktop/B.heic")
        let v = URL(fileURLWithPath: "/Users/test/Desktop/Film.mov")
        var s = TrayRules.adding([a, b, v], origin: "Desktop", to: TrayState(), now: now, bookmark: noBookmark)
        // Like TrayController.finish: successful sources by URL, not by file name.
        let consumed: Set<URL> = [a, b]
        let used = s.items.filter { consumed.contains($0.url) }
        let usedIDs = used.map(\.id)
        let receipt = UUID()
        let files = [URL(fileURLWithPath: "/tmp/Results/r/A.jpg"), URL(fileURLWithPath: "/tmp/Results/r/B.jpg")]
        var results: [TrayItem] = []
        for file in files.reversed() {
            let made = TrayItem(role: .result, url: file, addedAt: now, receipt: receipt, sources: usedIDs, tool: .asJPEG)
            s = TrayRules.consumed(results.isEmpty ? usedIDs : [], by: made, in: s)
            results.insert(made, at: 0)
        }
        let afterRun = s.items.map(\.url.lastPathComponent) == ["A.jpg", "B.jpg", "Film.mov"]
            && TrayRules.peek(s).first?.url.lastPathComponent == "A.jpg"
        // Undo on either result reverts both (one job) and brings A and B back.
        let undone = TrayRules.undone(results[1].id, in: s, restoring: used)
        let names = Set(undone.items.map(\.url.lastPathComponent))
        let back = names == ["Film.mov", "A.heic", "B.heic"] && undone.items.count == 3 && !undone.items.contains { $0.role == .result }
        return afterRun && back
    }

    await checkAsync("Tray: tool, journal and undo without a model; the original stays, the result goes") {
        let input = dir("trayflow-input").appendingPathComponent("Foto.jpg")
        guard ToolFixtures.writeImage(ToolFixtures.textImage(["Pippa 4711"], width: 600, height: 400), type: .jpeg, to: input) else { return false }
        let before = ToolFixtures.identity(input)
        let output = try await OneAnswerTools.run(.asPNG, inputs: [input])
        let engine = LocalEngine(baseDirectory: dir("trayflow-support"), modelEnabled: false)
        let receipt = try await engine.recordResult(output.files, summary: output.summary, detail: output.skippedSentence ?? "")
        let made = output.files.count == 1 && output.files.allSatisfy { ResultsFolder.contains($0) && fm.fileExists(atPath: $0.path) }
        try await engine.undo(receipt)
        let gone = output.files.allSatisfy { !fm.fileExists(atPath: $0.path) }
        let after = ToolFixtures.identity(input)
        return made && gone && before.sha == after.sha && output.skippedSentence == nil && receipt.undoDetail != nil
    }

    await checkAsync("Tray: taking along records the target and counts result_left; passed-over items appear in the log without a choice") {
        let log = try TaskLog(path: ":memory:")
        let id = try await log.record(TaskRecord(kind: .scans, offered: ["make-one-pdf", "make-smaller"], chosen: "make-one-pdf"))
        try await log.setTarget(TaskTarget(kind: .dragged), for: id)
        try await log.log(.resultLeft)
        try await log.record(TaskRecord(kind: .scans, offered: ["make-one-pdf"], chosen: nil))
        let rows = try await log.records(limit: 500)
        let left = try await log.count(.resultLeft)
        return left == 1 && rows.count == 2
            && rows.contains { $0.chosen == "make-one-pdf" && $0.target?.kind == .dragged }
            && rows.contains { $0.chosen == nil && $0.offered == ["make-one-pdf"] }
    }
}
