import Foundation
import PippaCore

/// The tray at the pill (Tray.swift) and the journal for tool results (Executor.recordResult, undo).
func runTrayChecks() async {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
    let a = URL(fileURLWithPath: "/Users/test/Downloads/Scan 1.jpg")
    let b = URL(fileURLWithPath: "/Users/test/Downloads/Scan 2.jpg")
    let c = URL(fileURLWithPath: "/Users/test/Desktop/Vertrag.pdf")
    let noBookmark: (URL) -> Data? = { _ in nil }

    check("Tray: saving and loading yield the same tray, a broken file yields an empty one") {
        let store = TrayStore(directory: dir("tray-store"))
        var s = TrayRules.adding([a, b], origin: "Downloads", to: TrayState(), now: now, bookmark: { _ in Data([1, 2, 3]) })
        let result = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/Results/x/Scans.pdf"), addedAt: now,
                              receipt: UUID(), sources: s.items.map(\.id), tool: .makeOnePDF)
        s = TrayRules.consumed(s.items.map(\.id), by: result, in: s)
        try store.save(s)
        let loaded = store.load()
        let broken = TrayStore(directory: dir("tray-broken"))
        write("{ kaputt", dir("tray-broken").appendingPathComponent(TrayStore.fileName))
        let missing = TrayStore(directory: dir("tray-missing"))
        // Field by field instead of `==`: URL equality after JSON depends on spelling, not on the path.
        func sameItem(_ x: TrayItem, _ y: TrayItem) -> Bool {
            guard x.id == y.id, x.role == y.role, x.url.path == y.url.path, x.bookmark == y.bookmark, x.name == y.name else { return false }
            guard x.origin == y.origin, x.addedAt == y.addedAt, x.receipt == y.receipt else { return false }
            return x.sources == y.sources && x.tool == y.tool
        }
        var same = loaded.version == s.version && loaded.items.count == s.items.count
        for (x, y) in zip(loaded.items, s.items) where !sameItem(x, y) { same = false }
        return same && loaded.items.first?.tool == .makeOnePDF && loaded.items.first?.sources.count == 2
            && broken.load().items.isEmpty && missing.load() == TrayState()
    }
    check("Tray: same path is not added twice but counts as freshly touched; order as dropped") {
        let s1 = TrayRules.adding([a, b], origin: "Downloads", to: TrayState(), now: hoursAgo(5), bookmark: noBookmark)
        let again = URL(fileURLWithPath: "/Users/test/Downloads/./Scan 1.jpg")
        let s2 = TrayRules.adding([again, c, c], origin: "Desktop", to: s1, now: now, bookmark: noBookmark)
        return s2.items.map(\.url.path) == [a.path, b.path, c.path] && s2.items[0].touchedAt == now
            && s2.items[0].origin == "Downloads" && s2.items[2].origin == "Desktop" && s2.items[2].name == "Vertrag.pdf"
    }
    check("Tray: given items fade after 24 hours, results stay, touched items stay") {
        var s = TrayRules.adding([a], origin: nil, to: TrayState(), now: hoursAgo(25), bookmark: noBookmark)
        s = TrayRules.adding([b], origin: nil, to: s, now: hoursAgo(30), bookmark: noBookmark)
        s.items[1].touchedAt = hoursAgo(2)
        s.items.append(TrayItem(role: .result, url: c, addedAt: hoursAgo(48)))
        let p = TrayRules.pruned(s, now: now, exists: { _ in true })
        return p.items.map(\.url) == [b, c]
    }
    check("Tray: missing files drop out, results too") {
        var s = TrayRules.adding([a, b], origin: nil, to: TrayState(), now: now, bookmark: noBookmark)
        s.items.append(TrayItem(role: .result, url: c, addedAt: now))
        let p = TrayRules.pruned(s, now: now, exists: { $0 == b })
        return p.items.map(\.url) == [b]
    }
    check("Tray: consumed items go, result in front; undo brings them back and removes results of the same job") {
        let s = TrayRules.adding([a, b, c], origin: nil, to: TrayState(), now: now, bookmark: noBookmark)
        let used = Array(s.items.prefix(2))
        let receipt = UUID()
        let r1 = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/r/Scan 1.png"), addedAt: now, receipt: receipt, sources: used.map(\.id), tool: .asPNG)
        let r2 = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/r/Scan 2.png"), addedAt: now, receipt: receipt, sources: used.map(\.id), tool: .asPNG)
        var after = TrayRules.consumed(used.map(\.id), by: r1, in: s)
        after = TrayRules.consumed(used.map(\.id), by: r2, in: after)
        let order: [UUID] = [r2.id, r1.id, s.items[2].id]
        let consumedOK = after.items.map(\.id) == order
        let undone = TrayRules.undone(r1.id, in: after, restoring: used)
        let twice = TrayRules.undone(r1.id, in: undone, restoring: used)
        let expected: [UUID] = [s.items[2].id, used[0].id, used[1].id]
        return consumedOK && undone.items.map(\.id) == expected && twice == undone
    }
    check("Tray: at rest results first, newest first, at most three") {
        var s = TrayState()
        let g1 = TrayItem(role: .given, url: a, addedAt: hoursAgo(3))
        let g2 = TrayItem(role: .given, url: b, addedAt: hoursAgo(1))
        let g3 = TrayItem(role: .given, url: c, addedAt: hoursAgo(2))
        let r1 = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/r1.pdf"), addedAt: hoursAgo(4))
        let r2 = TrayItem(role: .result, url: URL(fileURLWithPath: "/tmp/r2.pdf"), addedAt: hoursAgo(0.5))
        s.items = [g1, g2, r1, g3, r2]
        let expected: [UUID] = [r2.id, r1.id, g2.id]
        return TrayRules.peek(s).map(\.id) == expected && TrayRules.peek(TrayState()).isEmpty
    }
    check("Tray: origin is the folder name, Pippa's own tray copies have none") {
        let inbox = URL(fileURLWithPath: "/Users/test/Library/Caches/Pippa/Inbox", isDirectory: true)
        return TrayRules.origin(for: a, inbox: inbox) == "Downloads"
            && TrayRules.origin(for: inbox.appendingPathComponent("1234/Mail.eml"), inbox: inbox) == nil
    }
    check("Tray: without a bookmark the URL applies, a missing file yields nil") {
        let file = dir("tray-resolve").appendingPathComponent("da.txt")
        write("da", file)
        let here = TrayStore.resolve(TrayItem(role: .given, url: file))
        let gone = TrayStore.resolve(TrayItem(role: .given, url: dir("tray-resolve").appendingPathComponent("weg.txt")))
        return here?.url == file && here?.scoped == false && gone == nil
    }

    // MARK: Journal for results

    await checkAsync("Result in journal: undo removes the file in the cache along with its folder, inputs stay unchanged") {
        let input = dir("result-input").appendingPathComponent("Scan.jpg")
        write("Bilddaten", input)
        let before = FileFingerprint.of(input)
        let folder = try ResultsFolder.fresh()
        let output = folder.appendingPathComponent("Scans.pdf")
        write("%PDF-1.4 Ergebnis", output)
        let ex = try Executor(baseDirectory: dir("result-support"))
        let receipt = try await ex.recordResult([output], summary: "Scans.pdf", detail: "")
        let listed = await ex.recentJobs().first { $0.id == receipt.id }
        let doneState = await ex.jobState(jobID: receipt.id)
        try await ex.undo(jobID: receipt.id)
        let state = await ex.jobState(jobID: receipt.id)
        let ops = try await ex.opStates(jobID: receipt.id)
        let afterUndo = await ex.recentJobs().contains { $0.id == receipt.id }
        let removed = L("Removed.", table: "TrayCore")
        return doneState == "done" && listed?.undoDetail == removed && receipt.undoDetail == removed && receipt.revealURL == output
            && state == "undone" && ops == ["undone"] && !afterUndo
            && !FileManager.default.fileExists(atPath: output.path) && !FileManager.default.fileExists(atPath: folder.path)
            && FileManager.default.fileExists(atPath: ResultsFolder.directory.path)
            && before?.matches(FileFingerprint.of(input)) == true
    }
    await checkAsync("Result in journal: an already removed file counts as undone, empty list is rejected") {
        let folder = try ResultsFolder.fresh()
        let output = folder.appendingPathComponent("weg.jpg")
        write("x", output)
        let ex = try Executor(baseDirectory: dir("result-gone-support"))
        let receipt = try await ex.recordResult([output], summary: "weg.jpg", detail: "")
        try? FileManager.default.removeItem(at: folder)
        let report = try await ex.undo(jobID: receipt.id)
        let state = await ex.jobState(jobID: receipt.id)
        var refused = false
        do { _ = try await ex.recordResult([], summary: "", detail: "") } catch { refused = true }
        return report.conflicts.isEmpty && state == "undone" && refused
    }
    await checkAsync("Result via LocalEngine without model: record and undo") {
        let engine = LocalEngine(baseDirectory: dir("result-engine"), modelEnabled: false)
        let folder = try ResultsFolder.fresh()
        let first = folder.appendingPathComponent("Scan 1.png"), second = folder.appendingPathComponent("Scan 2.png")
        write("1", first); write("2", second)
        let receipt = try await engine.recordResult([first, second], summary: "2", detail: "")
        try await engine.undo(receipt)
        return !FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path)
            && !FileManager.default.fileExists(atPath: folder.path)
    }
    await checkAsync("Result: StubEngine does not offer it") {
        do { _ = try await StubEngine(delay: 0).recordResult([], summary: "", detail: ""); return false } catch { return true }
    }
}
