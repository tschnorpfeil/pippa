import Foundation
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// The tray flow (App/TrayController.swift) from its pure parts, as the controller composes them:
/// tool → journal → shelf → undo, and the log rows for taking along and passing over.
/// The controller itself lives in the app module and is not reachable from here.
func runTrayFlowChecks() async {
    setenv("PIPPA_RESULTS_DIR", dir("trayflow-results").path, 1)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let noBookmark: (URL) -> Data? = { _ in nil }

    check("Native file retry belongs to the same ordered selection, never a new or empty request") {
        let a = UUID(), b = UUID(), other = UUID()
        let request = NativeFileRequest(tool: .makeOnePDF, inputIDs: [a, b])
        return request.matches([a, b]) && !request.matches([b, a]) && !request.matches([a])
            && !request.matches([a, b, other]) && !request.matches([a, other])
            && !NativeFileRequest(tool: .makeOnePDF, inputIDs: []).matches([])
    }

    check("Native file caveats remain attached to their artifact through persistence and legacy results still decode") {
        let first = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/first.pdf"))
        let second = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/second.pdf"), note: "Optional text was skipped")
        let encoded = try JSONEncoder().encode(TrayState(items: [first, second]))
        let decoded = try JSONDecoder().decode(TrayState.self, from: encoded)
        guard decoded.items[0].note == nil, decoded.items[1].note == second.note else { return false }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "note")
        let old = try JSONDecoder().decode(TrayItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        return old.id == second.id && old.note == nil
    }

    await checkAsync("Optional PDF text: a stalled recognizer is cancelled promptly and later pages cannot restart its budget") {
        let budget = FileTextBudget(seconds: 0.12)
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let calls = LockedBox(0), cancellations = LockedBox(0)
        let began = Date()
        let first: Int? = try await Task.detached {
            try budget.run(cancel: { cancellations.mutate { $0 += 1 } }, work: {
                calls.mutate { $0 += 1 }
                release.wait()
                finished.signal()
                return 42
            })
        }.value
        let elapsed = Date().timeIntervalSince(began)
        let second: Int? = try budget.run(cancel: {}, work: { calls.mutate { $0 += 1 }; return 99 })
        release.signal()
        let workerFinished = waitForFileTextFixture(finished)
        return first == nil && second == nil && budget.didSkip && calls.value == 1
            && cancellations.value == 1 && elapsed < 1 && workerFinished
    }

    await checkAsync("Optional PDF text: Stop cancels an in-flight recognizer without waiting for its deadline") {
        let budget = FileTextBudget(seconds: 5)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = LockedBox(false)
        let work = Task.detached {
            try budget.run(cancel: { cancelled.mutate { $0 = true } }, work: {
                started.signal(); release.wait(); return 42
            })
        }
        let didStart = await Task.detached { waitForFileTextFixture(started) }.value
        let began = Date()
        work.cancel()
        var threwCancellation = false
        do { _ = try await work.value } catch is CancellationError { threwCancellation = true }
        release.signal()
        return didStart && threwCancellation && cancelled.value && Date().timeIntervalSince(began) < 1
    }

    await checkAsync("Optional PDF text: prompt recognition is retained without a skipped-text notice") {
        let budget = FileTextBudget(seconds: 1)
        let result = try await Task.detached { try budget.run(cancel: {}, work: { "Recognized text" }) }.value
        return result == "Recognized text" && !budget.didSkip
    }

    await checkAsync("Native first result: PDFs combine in chosen order without a model, with originals intact and readable output") {
        let folder = dir("native-first-pdfs")
        let a = folder.appendingPathComponent("First.pdf"), b = folder.appendingPathComponent("Second.pdf")
        makePDF(["FIRST DOCUMENT 4711"], at: a)
        makePDF(["SECOND DOCUMENT 815"], at: b)
        let originals = [a, b].map { ToolFixtures.identity($0).sha }
        let output = try await OneAnswerTools.run(.makeOnePDF, inputs: [a, b])
        guard let file = output.files.first, let pdf = PDFDocument(url: file) else { return false }
        let valid = output.files.count == 1 && output.consumedInputs == [a, b] && ResultsFolder.contains(file)
            && pdf.pageCount == 2 && pdf.page(at: 0)?.string?.contains("FIRST DOCUMENT") == true
            && pdf.page(at: 1)?.string?.contains("SECOND DOCUMENT") == true
            && [a, b].map { ToolFixtures.identity($0).sha } == originals
        let engine = LocalEngine(baseDirectory: dir("native-first-pdf-journal"), modelEnabled: false)
        let receipt = try await engine.recordResult(output.files, summary: output.summary, detail: output.detailSentence ?? "")
        try await engine.undo(receipt)
        return valid && !fm.fileExists(atPath: file.path) && receipt.undoDetail != nil
            && [a, b].map { ToolFixtures.identity($0).sha } == originals
    }

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

/// This fixture waits for blocking work on a GCD queue; the production budget's caller wait is tested separately.
private func waitForFileTextFixture(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}
