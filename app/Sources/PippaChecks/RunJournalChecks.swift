import Foundation
import PippaCore
import SQLite3

/// Synthetic Calendar and Reminders for the run journal: events and reminders live in `DemoIntegrations` (so Undo,
/// read-back and "the person edited it" behave like EventKit), and `probe` runs inside each native call.
final class RunProbeWriter: HostWriting, @unchecked Sendable {
    let demo = DemoIntegrations(granted: true)
    private let lock = NSLock()
    private var containers: [String: String] = [:]
    private var probe: (@Sendable () -> Void)?
    /// The person (or a sync) edits every new entry right after it is saved.
    private var editAfterSave = false
    private var calls = 0
    var nativeCalls: Int { lock.withLock { calls } }
    func setProbe(_ action: (@Sendable () -> Void)?) { lock.withLock { probe = action } }
    func setEditAfterSave(_ on: Bool) { lock.withLock { editAfterSave = on } }

    private func enter() { let action = lock.withLock { calls += 1; return probe }; action?() }
    private func saved(_ write: HostWrite) -> HostWrite {
        if lock.withLock({ editAfterSave }) { demo.touch(write.item.identifier) }
        return write
    }

    func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite {
        enter()
        return saved(try await demo.addEvent(event))
    }
    func addReminder(_ reminder: NewReminder) async throws -> HostWrite { throw PippaError.notAvailable }
    func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget { .init(identifier: "run-list", title: "Run list") }
    func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite {
        enter()
        var write = try await demo.addReminder(reminder)
        write.containerIdentifier = target.identifier; write.container = target.title
        lock.withLock { containers[write.item.identifier] = target.identifier }
        return saved(write)
    }
    func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup { .unavailable }
    func readBack(_ item: CreatedItem) async -> CreatedItemReadBack {
        let found = await demo.readBack(item)
        guard item.integration == .reminders, case .found(let title, let start, let end, _, let fingerprint) = found else { return found }
        return .found(title: title, start: start, end: end, container: lock.withLock { containers[item.identifier] }, fingerprint: fingerprint)
    }
}

/// One answer's tools on a fresh journal.
struct RunFixture {
    let directory: URL
    let journal: Executor
    let writer = RunProbeWriter()
    var host: PippaMCPHost
    let scope: PippaMCPWriteScope
    var run: UUID { scope.turnID! }
    var tools: PippaMCPWriteTools { .init(host: host, scope: scope) }
    init(now: @escaping @Sendable () -> Date = { Date() }) throws {
        directory = root.appendingPathComponent("run-journal-" + UUID().uuidString)
        journal = try Executor(baseDirectory: directory, now: now)
        host = .demo()
        host.writer = writer; host.integrations = writer.demo; host.reminderJournal = journal; host.requiresReminderJournal = true
        scope = PippaMCPWriteScope(turnID: UUID(), origin: .init(conversationID: UUID(), requestID: UUID()))
    }
    func reopened(now: @escaping @Sendable () -> Date = { Date() }) throws -> Executor {
        try Executor(baseDirectory: directory, nativeRecoverySessionID: UUID(), now: now)
    }
    func event(_ title: String, _ hour: Int) async -> PippaMCPToolResult {
        await tools.call("calendar_add", ["title": title, "date": "tomorrow", "time": String(format: "%02d:00", hour)])
    }
}

/// Reads `journal.sqlite` over its own connection, as another process would.
func runJournalStates(_ directory: URL) -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("journal.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ["unopened"] }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT tool || ':' || state FROM run_actions ORDER BY seq", -1, &statement, nil) == SQLITE_OK else { return ["unprepared"] }
    defer { sqlite3_finalize(statement) }
    var states: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { states.append(String(cString: sqlite3_column_text(statement, 0))) }
    return states
}

private func runJSON(_ result: PippaMCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
}

func runRunJournalChecks() async {
    await checkAsync("Run journal: one row per classed action with run, order, tool, class, identity, before/after, state and timestamps") {
        let f = try RunFixture()
        _ = await f.event("Run fixture event", 9)
        _ = await f.tools.call("reminder_add", ["title": "Run fixture reminder", "date": "tomorrow"])
        _ = await f.tools.call("mail_draft", ["body": "Hello", "subject": "Run fixture mail", "to": "a@example.invalid"])
        let rows = try await f.journal.runActions(run: f.run)
        guard rows.count == 3 else { return false }
        let (event, reminder, draft) = (rows[0], rows[1], rows[2])
        return rows.map(\.order) == [1, 2, 3] && rows.allSatisfy { $0.run == f.run && $0.state == .done && $0.actionClass == .undoable && $0.updated >= $0.created }
            && event.tool == "calendar_add" && event.object.kind == "event" && event.object.createdItem?.identifier.hasPrefix("demo-") == true
            && event.object.fields["fingerprint"] != nil && event.after?["calendar"] != nil && event.verified == true
            && reminder.tool == "reminder_add" && reminder.object.kind == "reminder" && reminder.object.fields["marker"]?.hasPrefix("pippa://operation/") == true
            && reminder.after?["list"] == "Run list" && reminder.verified == true
            && draft.tool == "mail_draft" && draft.object.kind == "mail.draft" && draft.object.fields["subject"] == "Run fixture mail" && draft.verified == nil
            && RunObject.mailMessage(kind: "mail.move", account: "Work", mailbox: "INBOX", messageID: "<a@b>").key == "<a@b>"
    }

    await checkAsync("Run journal: an older journal.sqlite (no run table, no bookmark column) opens with its reminder records and takes run rows") {
        let directory = root.appendingPathComponent("run-journal-legacy-" + UUID().uuidString)
        let origin = PippaMCPOrigin(conversationID: UUID(), requestID: UUID())
        do {
            let old = try Executor(baseDirectory: directory)
            _ = try await old.beginNativeReminder(id: UUID(), origin: origin, turnID: UUID(), requestHash: "legacy", reminder: NewReminder(title: "Legacy fixture"), label: "Legacy")
        }
        // The layout before the run journal: drop what this version adds.
        try reminderFixtureSQL(directory, "DROP TABLE run_actions; ALTER TABLE jobs DROP COLUMN bookmark;")
        let reopened = try Executor(baseDirectory: directory, nativeRecoverySessionID: UUID())
        let records = try await reopened.nativeReminderRecords(conversationID: origin.conversationID)
        let run = UUID()
        let rows = try await reopened.planRunActions(run: run, [RunActionDraft(tool: "calendar_add", object: RunObject(kind: "event", fields: [:]), label: "x")])
        let stored = try await reopened.runActions(run: run)
        return records.count == 1 && records[0].reminder.title == "Legacy fixture" && records[0].phase == .notDispatched
            && rows.first?.order == 1 && stored.count == 1
    }

    await checkAsync("Run journal: the row is dispatched on disk before the native call starts (read from another connection inside the call)") {
        let f = try RunFixture()
        let seen = LockedBox<[[String]]>([])
        let directory = f.directory
        f.writer.setProbe { seen.mutate { $0.append(runJournalStates(directory)) } }
        _ = await f.event("Dispatch probe", 10)
        _ = await f.tools.call("reminder_add", ["title": "Dispatch probe reminder"])
        return seen.value == [["calendar_add:dispatched"], ["calendar_add:done", "reminder_add:dispatched"]]
            && runJournalStates(directory) == ["calendar_add:done", "reminder_add:done"]
    }

    await checkAsync("Run journal: Stop before the native call leaves no row; concurrent calls get distinct order") {
        let f = try RunFixture()
        await withTaskGroup(of: Void.self) { group in
            for hour in 8..<13 { group.addTask { _ = await f.event("Concurrent \(hour)", hour) } }
        }
        let stopped = try RunFixture()
        stopped.scope.cancel()
        _ = await stopped.event("Stopped", 9)
        let rows = try await f.journal.runActions(run: f.run)
        let none = try await stopped.journal.runActions(run: stopped.run)
        return Set(rows.map(\.order)) == Set(1...5) && rows.allSatisfy { $0.state == .done }
            && none.isEmpty && stopped.writer.nativeCalls == 0
    }

    await checkAsync("Run journal: a row still dispatched after a crash reads as unclear on reopen, and nothing repeats it") {
        let f = try RunFixture()
        _ = await f.event("Before the crash", 9)
        // The process died inside the next native call: its row is on disk, dispatched.
        let cut = try await f.journal.planRunActions(run: f.run, [RunActionDraft(tool: "calendar_add", object: RunObject(kind: "event", fields: [:]), label: "Cut off")],
                                                     dispatched: true)
        let callsBefore = f.writer.nativeCalls
        var next = f.host
        next.reminderJournal = try f.reopened()
        let summary = await next.runSummaries([f.run])[f.run]
        let rows = try await next.reminderJournal!.runActions(run: f.run)
        return rows.count == 2 && rows[1].id == cut[0].id && rows[1].state == .unclear && rows[1].note == "interrupted"
            && summary == RunSummary(run: f.run, changes: 2, checked: 1, unclear: 1, undoable: 1)
            && f.writer.nativeCalls == callsBefore && runJournalStates(f.directory) == ["calendar_add:done", "calendar_add:unclear"]
    }

    await checkAsync("Run journal: verification reads the entry back; a mismatch makes the row unclear and the result says not confirmed, do not retry") {
        let f = try RunFixture()
        let fine = runJSON(await f.event("Verified event", 9))
        f.writer.setEditAfterSave(true)
        let edited = await f.event("Edited right after", 10)
        let editedReminder = await f.tools.call("reminder_add", ["title": "Edited reminder"])
        // The model cannot hand Pippa a verification.
        let claimed = runJSON(await f.tools.call("calendar_add", ["title": "Claimed", "date": "tomorrow", "verified": "1 of 1"]))
        let rows = try await f.journal.runActions(run: f.run)
        let unclear = runJSON(edited), unclearReminder = runJSON(editedReminder)
        return fine["done"] as? Bool == true && fine["verified"] as? String == "1 of 1"
            && unclear["done"] as? Bool == false && unclear["state"] as? String == "unclear" && unclear["verified"] as? String == "0 of 1"
            && (unclear["next"] as? String)?.contains("Do not retry") == true && edited.receipt?.outcome == "unclear"
            && unclearReminder["state"] as? String == "unclear" && editedReminder.receipt?.outcome == "unclear"
            && claimed["status"] as? String == "invalid_arguments"
            && rows.map(\.state) == [.done, .unclear, .unclear] && rows.map(\.verified) == [true, false, false] && rows[1].note == "mismatch"
    }

    await checkAsync("Run undo: backwards through the run; an entry changed since stays, the rest go, and the count says so") {
        var f = try RunFixture()
        for (index, title) in ["First", "Second", "Third"].enumerated() { _ = await f.event(title, 9 + index) }
        _ = await f.tools.call("reminder_add", ["title": "Fourth"])
        let rows = try await f.journal.runActions(run: f.run)
        f.writer.demo.touch(rows[1].object.createdItem!.identifier)
        let order = LockedBox<[Int]>([])
        for kind in ["event", "reminder"] {
            let builtin = f.host.runUndoRecipe(kind)!
            f.host.runRecipes[kind] = { row in order.mutate { $0.append(row.order) }; return await builtin(row) }
        }
        let before = await f.host.runSummaries([f.run])[f.run]
        let report = try await f.host.undoRun(f.run)
        let after = await f.host.runSummaries([f.run])[f.run]
        let again = try await f.host.undoRun(f.run)
        return before == RunSummary(run: f.run, changes: 4, checked: 4, undoable: 4)
            && order.value == [4, 3, 2, 1] && report.undone.map(\.order) == [4, 3, 1] && report.left.map(\.order) == [2] && report.failed.isEmpty
            && after == RunSummary(run: f.run, changes: 4, checked: 4, undoable: 0, undone: 3, left: 1)
            && f.writer.demo.createdCount == 1 && again.undone.isEmpty && again.left.isEmpty
    }

    await checkAsync("Run undo: a run without undoable rows offers no Undo; one Undo of a single receipt counts in the run") {
        let f = try RunFixture()
        _ = await f.tools.call("mail_draft", ["body": "Hi", "subject": "Draft only", "to": "a@example.invalid"])
        let draftOnly = await f.host.runSummaries([f.run])[f.run]
        let g = try RunFixture()
        let added = await g.event("Single undo", 9)
        let single = await g.host.undo(added.receipt!, run: g.run)
        let report = try await g.host.undoRun(g.run)
        let counted = await g.host.runSummaries([g.run])[g.run]
        return draftOnly == RunSummary(run: f.run, changes: 1, checked: 0, undoable: 0)
            && single.undo == "removed" && report.undone.isEmpty && report.failed.isEmpty
            && counted == RunSummary(run: g.run, changes: 1, checked: 1, undone: 1)
    }

    await checkAsync("Run journal: Pi's file changes (kept copy, new file, move, Trash) join the run, are read back, and the run Undo puts them back") {
        let f = try RunFixture()
        let folder = dir("run-files-" + UUID().uuidString)
        let edited = folder.appendingPathComponent("Notes.txt"), copy = folder.appendingPathComponent("Notes.backup.txt")
        write("old text", copy); write("new text", edited)
        let created = folder.appendingPathComponent("New.txt"); write("brand new", created)
        let movedFrom = folder.appendingPathComponent("Inbox/Letter.pdf"), movedTo = folder.appendingPathComponent("Archive/Letter.pdf")
        try FileManager.default.createDirectory(at: movedTo.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("letter", movedTo)
        let trashedFrom = folder.appendingPathComponent("Old.txt"), trashedTo = folder.appendingPathComponent("Trash/Old.txt")
        try FileManager.default.createDirectory(at: trashedTo.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("old", trashedTo)
        let missing = folder.appendingPathComponent("Missing.txt")
        let entry: [String: Any] = ["v": 1, "tool": "move_files", "changes": [
            ["kind": "restore", "file": edited.path, "copy": copy.path], ["kind": "create", "file": created.path],
            ["kind": "move", "from": movedFrom.path, "to": movedTo.path], ["kind": "trash", "from": trashedFrom.path, "to": trashedTo.path],
            ["kind": "create", "file": missing.path], ["kind": "create", "file": "relative.txt"],
        ]]
        _ = await f.event("Event in the same run", 9)
        let rows = try await f.journal.recordFileChanges(run: f.run, entry: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self))
        // The new file was changed after Pi made it: Undo leaves it.
        write("brand new, edited by the person", created)
        let report = try await f.host.undoRun(f.run)
        let text = { (url: URL) in try? String(contentsOf: url, encoding: .utf8) }
        let all = try await f.journal.runActions(run: f.run)
        // The version Pi wrote went to the checks' own Trash, never the person's.
        let checkTrash = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PIPPA_CHECK_TRASH"]!)
        let trashed = (FileManager.default.enumerator(at: checkTrash, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "Notes.txt" }.compactMap(text)
        return trashed.contains("new text")
            && rows.map(\.object.kind) == ["file.restore", "file.create", "file.move", "file.trash", "file.create"]
            && rows.map(\.verified) == [true, true, true, true, false] && rows.map(\.state) == [.done, .done, .done, .done, .unclear]
            && rows.allSatisfy { $0.tool == "move_files" && $0.run == f.run } && rows[0].object.fileIdentity?.sha256.count == 64
            && all.map(\.order) == [1, 2, 3, 4, 5, 6]
            && text(edited) == "old text" && text(movedFrom) == "letter" && !FileManager.default.fileExists(atPath: movedTo.path)
            && text(trashedFrom) == "old" && text(created) == "brand new, edited by the person"
            && report.undone.map(\.object.kind) == ["file.trash", "file.move", "file.restore", "event"] && report.left.map(\.object.kind) == ["file.create"]
    }

    await checkAsync("Run undo: a file the person deleted or moved away since stays as it is; nothing is recreated or counted as undone") {
        let f = try RunFixture()
        let folder = dir("run-gone-" + UUID().uuidString)
        let edited = folder.appendingPathComponent("Notes.txt"), copy = folder.appendingPathComponent("Notes.backup.txt")
        write("old text", copy); write("new text", edited)
        let movedFrom = folder.appendingPathComponent("Letter.pdf"), movedTo = folder.appendingPathComponent("Archive/Letter.pdf")
        let trashedFrom = folder.appendingPathComponent("Old.txt"), trashedTo = folder.appendingPathComponent("Trash/Old.txt")
        for url in [movedTo, trashedTo] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        write("letter", movedTo); write("old", trashedTo)
        let entry: [String: Any] = ["v": 1, "tool": "move_files", "changes": [
            ["kind": "restore", "file": edited.path, "copy": copy.path], ["kind": "move", "from": movedFrom.path, "to": movedTo.path],
            ["kind": "trash", "from": trashedFrom.path, "to": trashedTo.path],
        ]]
        _ = try await f.journal.recordFileChanges(run: f.run, entry: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self))
        // The person deletes the edited file, moves the letter on, and empties the Trash.
        try FileManager.default.removeItem(at: edited)
        try FileManager.default.moveItem(at: movedTo, to: folder.appendingPathComponent("Elsewhere.pdf"))
        try FileManager.default.removeItem(at: trashedTo)
        let report = try await f.host.undoRun(f.run)
        let summary = await f.host.runSummaries([f.run])[f.run]
        return report.undone.isEmpty && report.failed.isEmpty && report.left.count == 3
            && ![edited, movedFrom, trashedFrom].contains { FileManager.default.fileExists(atPath: $0.path) }
            && summary == RunSummary(run: f.run, changes: 3, checked: 3, undoable: 0, left: 3)
    }

    await checkAsync("Run journal: a moved folder and a case-only rename are verified and put back by the run Undo") {
        let f = try RunFixture()
        let folder = dir("run-folders-" + UUID().uuidString)
        let from = folder.appendingPathComponent("Inbox/Taxes"), to = folder.appendingPathComponent("Archive/Taxes")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("receipt", from.appendingPathComponent("2026.txt"))
        try FileManager.default.moveItem(at: from, to: to)
        let lower = folder.appendingPathComponent("report.txt"), upper = folder.appendingPathComponent("Report.txt")
        write("report", lower)
        guard rename(lower.path, upper.path) == 0 else { return false }
        let entry: [String: Any] = ["v": 1, "tool": "move_files", "changes": [
            ["kind": "move", "from": from.path, "to": to.path], ["kind": "move", "from": lower.path, "to": upper.path],
        ]]
        let rows = try await f.journal.recordFileChanges(run: f.run, entry: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self))
        let report = try await f.host.undoRun(f.run)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return rows.map(\.state) == [.done, .done] && rows.map(\.verified) == [true, true] && report.undone.count == 2
            && (try? String(contentsOf: from.appendingPathComponent("2026.txt"), encoding: .utf8)) == "receipt"
            && !FileManager.default.fileExists(atPath: to.path) && names.contains("report.txt") && !names.contains("Report.txt")
    }

    await checkAsync("Run undo: one lock per answer for both Undo kinds; each sees the other's outcome, marked in its own run only") {
        let f = try RunFixture()
        let first = await f.event("Single one", 9), second = await f.event("Single two", 10)
        // Undo of one receipt: the run still offers the other change, and its receipt reads so.
        let single = await f.host.undo(first.receipt!, run: f.run)
        let partly = await f.host.runSummaries([f.run])[f.run]!
        // While Undo of the whole answer runs, a receipt's Undo does nothing.
        try await f.journal.beginRunUndo(f.run)
        let busy = await f.host.undo(second.receipt!, run: f.run)
        await f.journal.endRunUndo(f.run)
        // Changed since: the receipt's Undo leaves it, and the run Undo then does not try it again.
        f.writer.demo.touch(second.receipt!.created!.identifier)
        let changed = await f.host.undo(second.receipt!, run: f.run)
        let report = try await f.host.undoRun(f.run)
        let after = await f.host.runSummaries([f.run])[f.run]
        // The same object key in another run stays as it is.
        let other = UUID(), key = "/fixture/Ready.pdf"
        let draft = { RunActionDraft(tool: "prepare_files", object: .file(kind: "file.prepared", path: key, identity: nil), label: "Ready") }
        let a = try await f.journal.planRunActions(run: f.run, [draft()], dispatched: true)
        let b = try await f.journal.planRunActions(run: other, [draft()], dispatched: true)
        try await f.journal.completeRunActions([.init(id: a[0].id, verified: true), .init(id: b[0].id, verified: true)])
        try await f.journal.markRunObject(run: f.run, key: key, .undone)
        let mine = try await f.journal.runActions(run: f.run).last, theirs = try await f.journal.runActions(run: other).first
        return single.undo == "removed" && partly == RunSummary(run: f.run, changes: 2, checked: 2, undoable: 1, undone: 1)
            && partly.undoTried && !partly.undoFinished
            && busy.undo == nil && changed.undo == "changed" && report.undone.isEmpty && report.left.isEmpty
            && after == RunSummary(run: f.run, changes: 2, checked: 2, undoable: 0, undone: 1, left: 1) && after?.undoFinished == true
            && mine?.state == .undone && theirs?.state == .done
    }

    check("Run receipt: shown whenever the run can undo something the single receipts do not offer, and stays after its Undo") {
        let run = UUID()
        let one = RunSummary(run: run, changes: 1, checked: 1, undoable: 1)
        let failed = PippaMCPWriteReceipt(action: "calendarAdd", outcome: "failed", name: "Not added")
        let added = PippaMCPWriteReceipt(action: "calendarAdd", outcome: "done", name: "Added",
                                         created: CreatedItem(integration: .calendar, identifier: "x", modified: nil))
        var undoneReceipt = added; undoneReceipt.undo = "removed"
        return one.shows(beside: [failed]) && !one.shows(beside: [added]) && one.shows(beside: [])
            && !RunSummary(run: run, changes: 1, checked: 1).shows(beside: [failed])
            && RunSummary(run: run, changes: 1, checked: 1, undone: 1).shows(beside: [failed])
            && RunSummary(run: run, changes: 1, checked: 1, left: 1).shows(beside: [failed])
            && !RunSummary(run: run, changes: 1, checked: 1, undone: 1).shows(beside: [undoneReceipt])
    }

    await checkAsync("Run journal: a shell command allowed online becomes an external row without Undo") {
        let f = try RunFixture()
        let entry: [String: Any] = ["v": 1, "tool": "bash", "changes": [["kind": "external", "label": "curl -sO https://example.org/a.pdf"]]]
        let rows = try await f.journal.recordFileChanges(run: f.run, entry: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self))
        let summary = await f.host.runSummaries([f.run])[f.run]
        return rows.count == 1 && rows[0].actionClass == .external && rows[0].tool == "bash" && rows[0].state == .done
            && rows[0].label == "curl -sO https://example.org/a.pdf" && summary == RunSummary(run: f.run, changes: 1, undoable: 0)
    }

    await checkAsync("Run journal: an online shell command that failed or was stopped leaves an unclear external row") {
        let f = try RunFixture()
        let entry: [String: Any] = ["v": 1, "tool": "bash", "changes": [["kind": "external", "label": "curl -sO https://example.org/a.pdf", "unclear": true]]]
        let rows = try await f.journal.recordFileChanges(run: f.run, entry: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self))
        let summary = await f.host.runSummaries([f.run])[f.run]
        return rows.count == 1 && rows[0].actionClass == .external && rows[0].state == .unclear
            && summary == RunSummary(run: f.run, changes: 1, unclear: 1)
    }

    await checkAsync("Run journal: rows older than 30 days are pruned at open, by the journal's clock") {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let f = try RunFixture(now: { clock.value })
        let draft = { (label: String) in RunActionDraft(tool: "calendar_add", object: RunObject(kind: "event", fields: [:]), label: label) }
        try await f.journal.planRunActions(run: f.run, [draft("Old")], dispatched: true)
        clock.mutate { $0 += 20 * 86_400 }
        let other = UUID()
        try await f.journal.planRunActions(run: other, [draft("Recent")], dispatched: true)
        clock.mutate { $0 += 11 * 86_400 }
        let later = try f.reopened(now: { clock.value })
        let old = try await later.runActions(run: f.run), recent = try await later.runActions(run: other)
        return old.isEmpty && recent.map(\.label) == ["Recent"]
    }

    await checkAsync("Run journal API for batches: a fake mail move is planned, dispatched, verified per message and undone through its own recipe") {
        var f = try RunFixture()
        let mailbox = LockedBox<[String: String]>(["<1@x>": "INBOX", "<2@x>": "INBOX", "<3@x>": "INBOX"])
        let ids = ["<1@x>", "<2@x>", "<3@x>"]
        let drafts = ids.map { id in
            RunActionDraft(tool: "mail_move", actionClass: .undoable, object: .mailMessage(kind: "mail.move", account: "Work", mailbox: "INBOX", messageID: id),
                           before: ["mailbox": "INBOX"], after: ["mailbox": "Archive"], label: id)
        }
        let planned = try await f.journal.planRunActions(run: f.run, drafts)
        try await f.journal.dispatchRunActions(planned.map(\.id))
        // The move itself; the third message ends up somewhere else.
        mailbox.mutate { $0["<1@x>"] = "Archive"; $0["<2@x>"] = "Archive"; $0["<3@x>"] = "Other" }
        let checked = try await f.journal.completeRunActions(planned.map { row in
            RunActionResult(id: row.id, verified: mailbox.value[row.object.fields["messageID"]!] == row.after?["mailbox"])
        })
        f.host.runRecipes["mail.move"] = { row in
            guard let id = row.object.fields["messageID"], let back = row.before?["mailbox"] else { return .failed }
            guard mailbox.value[id] == row.after?["mailbox"] else { return .changed }
            mailbox.mutate { $0[id] = back }
            return .undone
        }
        var refused = false
        do { try await f.journal.dispatchRunActions([planned[0].id]) } catch { refused = true }
        let summary = await f.host.runSummaries([f.run])[f.run]
        let report = try await f.host.undoRun(f.run)
        return planned.allSatisfy { $0.state == .planned } && checked.map(\.state) == [.done, .done, .unclear] && refused
            && summary == RunSummary(run: f.run, changes: 3, checked: 2, unclear: 1, undoable: 2, mailMoves: 3)
            && report.undone.map(\.label) == ["<2@x>", "<1@x>"] && mailbox.value == ["<1@x>": "INBOX", "<2@x>": "INBOX", "<3@x>": "Other"]
    }
}
