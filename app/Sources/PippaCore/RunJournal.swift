import Darwin
import Foundation

// The run journal (docs/pippa-1.0.md "Journal, verification and undo for whole runs"): one row per action of an
// `undoable`, `irreversible` or `external` tool in one answer (a run), in the same `journal.sqlite` as the reminder
// journal and the file jobs. A row is `dispatched` on disk before the native call starts, is checked against the
// source afterwards, and a whole run is undone backwards, one unchanged object at a time.

extension PippaActionClass: Codable {}

/// What an action touched, by an identity that survives restarts: `kind` names the recipe (`event`, `reminder`,
/// `file.create`, a later `mail.move`, …), `fields` hold the identity (EventKit identifier and fingerprint, a file's path
/// with its `DurableFileIdentity`, a mail's account, mailbox and Message-ID).
public struct RunObject: Codable, Sendable, Equatable {
    public var kind: String
    public var fields: [String: String]
    public init(kind: String, fields: [String: String]) { self.kind = kind; self.fields = fields }

    /// The one field that names the object (EventKit identifier, path, Message-ID), stored in its own column.
    public var key: String? { fields["identifier"] ?? fields["messageID"] ?? fields["path"] }

    /// An event or reminder Pippa created, with the fingerprint and modification time Undo compares against.
    public static func created(_ item: CreatedItem) -> RunObject {
        var fields = ["identifier": item.identifier]
        fields["fingerprint"] = item.fingerprint
        fields["modified"] = item.modified.map { String($0.timeIntervalSinceReferenceDate) }
        return RunObject(kind: item.integration == .calendar ? "event" : "reminder", fields: fields)
    }

    /// A mail message: `kind` is the tool's own (for example `mail.move`); the mailbox it is in goes in before/after.
    public static func mailMessage(kind: String, account: String, mailbox: String, messageID: String) -> RunObject {
        RunObject(kind: kind, fields: ["account": account, "mailbox": mailbox, "messageID": messageID])
    }

    /// A file at `path` with its content identity, if it could be read.
    public static func file(kind: String, path: String, identity: DurableFileIdentity?, extra: [String: String] = [:]) -> RunObject {
        var fields = extra
        fields["path"] = path
        if let identity {
            fields["size"] = String(identity.size); fields["modified"] = String(identity.modified.timeIntervalSinceReferenceDate)
            fields["device"] = String(identity.device); fields["inode"] = String(identity.inode); fields["sha256"] = identity.sha256
        }
        return RunObject(kind: kind, fields: fields)
    }

    public var createdItem: CreatedItem? {
        guard let identifier = fields["identifier"], kind == "event" || kind == "reminder" else { return nil }
        return CreatedItem(integration: kind == "event" ? .calendar : .reminders, identifier: identifier,
                           modified: fields["modified"].flatMap(Double.init).map(Date.init(timeIntervalSinceReferenceDate:)),
                           fingerprint: fields["fingerprint"])
    }

    public var fileIdentity: DurableFileIdentity? {
        guard let size = fields["size"].flatMap(Int64.init), let modified = fields["modified"].flatMap(Double.init),
              let device = fields["device"].flatMap(UInt64.init), let inode = fields["inode"].flatMap(UInt64.init),
              let sha256 = fields["sha256"] else { return nil }
        return DurableFileIdentity(size: size, modified: Date(timeIntervalSinceReferenceDate: modified), device: device, inode: inode, sha256: sha256)
    }
}

/// One row of the run journal.
public struct RunAction: Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case planned, dispatched, done, unclear, undone, undoFailed = "undo_failed" }
    public let id: UUID
    /// The answer's turn id.
    public let run: UUID
    /// Order within the run, from 1.
    public let order: Int
    public let tool: String
    public let actionClass: PippaActionClass
    public var object: RunObject
    /// Where it was before and where it is after, e.g. `["mailbox": "INBOX"]` → `["mailbox": "Archive"]`.
    public var before: [String: String]?
    public var after: [String: String]?
    public var state: State
    /// The receipt's name for it ("Fri 14 Nov, 09:00 – Dentist"), for the note to the model after Undo.
    public var label: String
    /// `true`: read back and it matched; `false`: read back and it did not (the row is unclear); `nil`: not checkable.
    public var verified: Bool?
    /// unclear: mismatch, unconfirmed, interrupted. After Undo: changed (left as it is), gone, failed.
    public var note: String?
    public let created: Date
    public var updated: Date
}

/// A row to add: the tool names the object; the journal assigns run order and timestamps.
public struct RunActionDraft: Sendable {
    public var id: UUID
    public var tool: String
    public var actionClass: PippaActionClass
    public var object: RunObject
    public var before: [String: String]?
    public var after: [String: String]?
    public var label: String
    public init(id: UUID = UUID(), tool: String, actionClass: PippaActionClass? = nil, object: RunObject,
                before: [String: String]? = nil, after: [String: String]? = nil, label: String) {
        self.id = id; self.tool = tool; self.actionClass = actionClass ?? PippaActionClasses.of(tool) ?? .undoable
        self.object = object; self.before = before; self.after = after; self.label = label
    }
}

/// What Pippa found when she read the object back after the action.
public struct RunActionResult: Sendable {
    public var id: UUID
    /// `true` matched, `false` did not match (→ unclear), `nil` nothing to read back.
    public var verified: Bool?
    /// The identity as it is now (for example the new file's identity, or the created event's identifier).
    public var object: RunObject?
    public var after: [String: String]?
    public init(id: UUID, verified: Bool?, object: RunObject? = nil, after: [String: String]? = nil) {
        self.id = id; self.verified = verified; self.object = object; self.after = after
    }
}

/// What one undo step did. `changed`: the object was changed since Pippa touched it, so it stays.
public enum RunUndoOutcome: String, Sendable { case undone, gone, changed, failed }
/// Puts one row back, only if its object is unchanged since Pippa touched it. Supplied per kind by the tool.
public typealias RunUndoRecipe = @Sendable (RunAction) async -> RunUndoOutcome

public struct RunUndoReport: Sendable, Equatable {
    public var undone: [RunAction] = []
    public var left: [RunAction] = []
    public var failed: [RunAction] = []
}

/// Counts for the one receipt under an answer, from its rows.
public struct RunSummary: Codable, Sendable, Equatable {
    public var run: UUID
    /// Rows that did, or may have done, something.
    public var changes: Int
    public var checked: Int
    public var unclear: Int
    /// Done rows with an undo recipe that Undo has not tried yet.
    public var undoable: Int
    public var undone: Int
    /// Left by Undo because they changed since.
    public var left: Int
    public var failed: Int
    public init(run: UUID, changes: Int = 0, checked: Int = 0, unclear: Int = 0, undoable: Int = 0, undone: Int = 0, left: Int = 0, failed: Int = 0) {
        self.run = run; self.changes = changes; self.checked = checked; self.unclear = unclear; self.undoable = undoable
        self.undone = undone; self.left = left; self.failed = failed
    }

    public init(run: UUID, rows: [RunAction], canUndo: (String) -> Bool) {
        self.init(run: run)
        for row in rows where row.state != .planned {
            changes += 1
            if row.verified == true { checked += 1 }
            switch row.state {
            case .dispatched, .unclear: unclear += 1
            case .undone: undone += 1
            case .undoFailed: failed += 1
            case .done where row.note == "changed": left += 1
            case .done where canUndo(row.object.kind): undoable += 1
            default: break
            }
        }
    }

    /// Undo was pressed for this run.
    public var undoTried: Bool { undone + left + failed > 0 }
}

public enum RunJournalError: Error, Sendable { case invalidState, busy }

extension Executor {
    /// Rows older than this are pruned at open, like the backup copies (`BACKUP_DAYS` in pippa-assist.ts).
    public static let runRetentionDays = 30

    static let runActionSchema = """
        CREATE TABLE IF NOT EXISTS run_actions(
            id TEXT PRIMARY KEY, run TEXT NOT NULL, seq INTEGER NOT NULL, tool TEXT NOT NULL, class TEXT NOT NULL,
            kind TEXT NOT NULL, object_key TEXT, object TEXT NOT NULL, before TEXT, after TEXT, state TEXT NOT NULL,
            label TEXT NOT NULL, verified INTEGER, note TEXT, process_session TEXT NOT NULL, created REAL NOT NULL,
            updated REAL NOT NULL, UNIQUE(run, seq));
        CREATE INDEX IF NOT EXISTS run_actions_state ON run_actions(state);
        CREATE INDEX IF NOT EXISTS run_actions_key ON run_actions(object_key);
        """

    // MARK: Writing

    /// Adds rows at the end of `run` in one transaction. `dispatched: true` for a single native call that starts right
    /// after this returns: the row is on disk before it. A batch is planned first and dispatched per step.
    @discardableResult
    public func planRunActions(run: UUID, _ drafts: [RunActionDraft], dispatched: Bool = false) throws -> [RunAction] {
        try runTransaction {
            var seq = Int(try db.query("SELECT COALESCE(MAX(seq), 0) FROM run_actions WHERE run=?", [.text(run.uuidString)]).first?.first?.int ?? 0)
            let now = self.now()
            return try drafts.map { draft in
                seq += 1
                let row = RunAction(id: draft.id, run: run, order: seq, tool: draft.tool, actionClass: draft.actionClass, object: draft.object,
                                    before: draft.before, after: draft.after, state: dispatched ? .dispatched : .planned, label: draft.label,
                                    verified: nil, note: nil, created: now, updated: now)
                try db.run("""
                    INSERT INTO run_actions(id,run,seq,tool,class,kind,object_key,object,before,after,state,label,verified,note,process_session,created,updated)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL,?,?,?)
                    """, [.text(row.id.uuidString), .text(run.uuidString), .int(Int64(seq)), .text(row.tool), .text(row.actionClass.rawValue),
                          .text(row.object.kind), row.object.key.map { .text($0) } ?? .null, .text(Self.encode(row.object.fields)),
                          Self.optional(row.before), Self.optional(row.after), .text(row.state.rawValue), .text(row.label),
                          .text(nativeSessionID.uuidString), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
                return row
            }
        }
    }

    /// planned → dispatched, committed before the native calls start. A row in another state is refused as a whole.
    public func dispatchRunActions(_ ids: [UUID]) throws {
        try runTransaction {
            for id in ids {
                guard try row(id)?.state == .planned else { throw RunJournalError.invalidState }
                try setState(id, .dispatched)
            }
        }
    }

    /// After the native calls: what the read-back found. Matched or not checkable → done; a mismatch → unclear.
    @discardableResult
    public func completeRunActions(_ results: [RunActionResult]) throws -> [RunAction] {
        try runTransaction {
            try results.map { result in
                guard var row = try row(result.id), [.dispatched, .unclear].contains(row.state) else { throw RunJournalError.invalidState }
                row.verified = result.verified
                if let object = result.object { row.object = object }
                if let after = result.after { row.after = after }
                row.state = result.verified == false ? .unclear : .done
                row.note = result.verified == false ? "mismatch" : nil
                try save(row)
                return row
            }
        }
    }

    /// The native call ended without proof of its outcome: unclear, never repeated.
    public func unclearRunActions(_ ids: [UUID], note: String = "unconfirmed") throws {
        try runTransaction {
            for id in ids {
                guard var row = try row(id), [.planned, .dispatched].contains(row.state) else { continue }
                row.state = .unclear; row.note = note
                try save(row)
            }
        }
    }

    /// The call provably changed nothing (refused before dispatch, stopped, invalid): the row goes.
    public func dropRunActions(_ ids: [UUID]) throws {
        try runTransaction {
            for id in ids {
                try db.run("DELETE FROM run_actions WHERE id=? AND state IN ('planned','dispatched') AND process_session=?",
                           [.text(id.uuidString), .text(nativeSessionID.uuidString)])
            }
        }
    }

    /// File changes Pi made (`pippa-change` from pippa-assist.ts: a write with a kept copy, a new file, a move, the
    /// Trash). Pi changed them before Pippa heard of it, so each is recorded done or unclear after reading it back.
    @discardableResult
    public func recordFileChanges(run: UUID, entry json: String) throws -> [RunAction] {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let changes = record["changes"] as? [[String: Any]] else { return [] }
        let tool = record["tool"] as? String ?? "write"
        var drafts: [RunActionDraft] = [], results: [Bool] = []
        for change in changes {
            func path(_ key: String) -> String? { (change[key] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
            let kind = change["kind"] as? String
            let file: String?, extra: [String: String], before: [String: String]?
            switch kind {
            case "restore":
                guard let target = path("file"), let copy = path("copy") else { continue }
                file = target; extra = ["copy": copy]; before = ["copy": copy]
            case "create":
                file = path("file"); extra = [:]; before = nil
            case "move", "trash":
                guard let from = path("from") else { continue }
                file = path("to"); extra = ["from": from]; before = ["path": from]
            default: continue
            }
            guard let file, let kind else { continue }
            let url = URL(fileURLWithPath: file)
            let identity = try? DurableFileIdentity.capture(url)
            // Read back: the file is where Pi says, and for a move the old place is empty.
            var matched = identity != nil
            if kind == "restore", let copy = extra["copy"] { matched = matched && FileManager.default.fileExists(atPath: copy) }
            if kind == "move" || kind == "trash", let from = extra["from"] { matched = matched && !FileManager.default.fileExists(atPath: from) }
            drafts.append(RunActionDraft(tool: tool, object: .file(kind: "file." + kind, path: file, identity: identity, extra: extra),
                                         before: before, after: ["path": file], label: url.lastPathComponent))
            results.append(matched)
        }
        guard !drafts.isEmpty else { return [] }
        let rows = try planRunActions(run: run, drafts, dispatched: true)
        return try completeRunActions(zip(rows, results).map { RunActionResult(id: $0.id, verified: $1) })
    }

    /// The person's Undo on one receipt row removed this object: its run row counts as undone.
    public func markRunObjectUndone(key: String) throws {
        try runTransaction {
            for var row in try rows("WHERE object_key=? AND state='done'", [.text(key)]) {
                row.state = .undone; row.note = nil
                try save(row)
            }
        }
    }

    // MARK: Reading

    /// The run's rows in order. A row still `dispatched` by an earlier Pippa process (it died during the call) is
    /// reported, and stored, as unclear: nothing repeats it.
    public func runActions(run: UUID) throws -> [RunAction] {
        try runTransaction {
            try closeInterruptedRunActions()
            return try rows("WHERE run=? ORDER BY seq", [.text(run.uuidString)])
        }
    }

    public func runActions(runs: [UUID]) throws -> [UUID: [RunAction]] {
        var result: [UUID: [RunAction]] = [:]
        for run in Set(runs) { result[run] = try runActions(run: run) }
        return result
    }

    // MARK: Undo

    /// Goes backwards through the run's done rows. Each step runs only if its recipe finds the object unchanged since
    /// Pippa touched it; the rest of the run continues either way. One Undo per run at a time.
    public func undoRun(_ run: UUID, recipe: @Sendable (String) -> RunUndoRecipe?) async throws -> RunUndoReport {
        guard !undoingRuns.contains(run) else { throw RunJournalError.busy }
        undoingRuns.insert(run)
        defer { undoingRuns.remove(run) }
        var report = RunUndoReport()
        for row in try runActions(run: run).reversed() where row.state == .done && row.note != "changed" {
            guard let undo = recipe(row.object.kind) else { continue }
            let outcome = await undo(row)
            // Only from done: a concurrent single-row Undo may have finished it meanwhile.
            guard var current = try runTransaction({ try self.row(row.id) }), current.state == .done else { continue }
            switch outcome {
            case .undone, .gone: current.state = .undone; current.note = outcome == .gone ? "gone" : nil; report.undone.append(current)
            case .changed: current.note = "changed"; report.left.append(current)
            case .failed: current.state = .undoFailed; current.note = "failed"; report.failed.append(current)
            }
            try runTransaction { try save(current) }
        }
        return report
    }

    // MARK: Pruning

    /// Rows not touched for `runRetentionDays` go, by the journal's clock. Runs when the journal opens.
    static func pruneRunActions(_ db: SQLiteDB, now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(runRetentionDays) * 86_400)
        try db.run("DELETE FROM run_actions WHERE updated < ?", [.real(cutoff.timeIntervalSince1970)])
    }

    // MARK: Storage

    private func closeInterruptedRunActions() throws {
        for var row in try rows("WHERE state='dispatched' AND process_session!=?", [.text(nativeSessionID.uuidString)]) {
            row.state = .unclear; row.note = "interrupted"
            try save(row)
        }
    }

    private func row(_ id: UUID) throws -> RunAction? { try rows("WHERE id=?", [.text(id.uuidString)]).first }

    private func setState(_ id: UUID, _ state: RunAction.State) throws {
        try db.run("UPDATE run_actions SET state=?, updated=? WHERE id=?", [.text(state.rawValue), .real(now().timeIntervalSince1970), .text(id.uuidString)])
    }

    private func save(_ row: RunAction) throws {
        try db.run("UPDATE run_actions SET kind=?, object_key=?, object=?, after=?, state=?, verified=?, note=?, updated=? WHERE id=?",
                   [.text(row.object.kind), row.object.key.map { .text($0) } ?? .null, .text(Self.encode(row.object.fields)),
                    Self.optional(row.after), .text(row.state.rawValue), row.verified.map { .int($0 ? 1 : 0) } ?? .null,
                    row.note.map { .text($0) } ?? .null, .real(now().timeIntervalSince1970), .text(row.id.uuidString)])
    }

    private func rows(_ condition: String, _ arguments: [SQLiteDB.Value]) throws -> [RunAction] {
        try db.query("SELECT id,run,seq,tool,class,kind,object,before,after,state,label,verified,note,created,updated FROM run_actions " + condition,
                     arguments).map { r in
            guard let id = r[0].string.flatMap(UUID.init), let run = r[1].string.flatMap(UUID.init), let seq = r[2].int,
                  let tool = r[3].string, let actionClass = r[4].string.flatMap(PippaActionClass.init), let kind = r[5].string,
                  let fields = r[6].string.flatMap(Self.decode), let state = r[9].string.flatMap(RunAction.State.init),
                  let label = r[10].string, case .real(let created) = r[13], case .real(let updated) = r[14] else {
                throw NativeReminderJournalError.unreadable
            }
            return RunAction(id: id, run: run, order: Int(seq), tool: tool, actionClass: actionClass, object: RunObject(kind: kind, fields: fields),
                             before: r[7].string.flatMap(Self.decode), after: r[8].string.flatMap(Self.decode), state: state, label: label,
                             verified: r[11].int.map { $0 != 0 }, note: r[12].string,
                             created: Date(timeIntervalSince1970: created), updated: Date(timeIntervalSince1970: updated))
        }
    }

    /// Every write holds BEGIN IMMEDIATE, so tool calls on other tasks and other Executor connections (the app, `--ask`)
    /// never interleave inside one transition. Nested use from a caller already in a transaction runs inline.
    private func runTransaction<Value>(_ body: () throws -> Value) throws -> Value {
        if inRunTransaction { return try body() }
        try db.exec("BEGIN IMMEDIATE")
        inRunTransaction = true
        var committed = false
        defer { inRunTransaction = false; if !committed { try? db.exec("ROLLBACK") } }
        let result = try body()
        try db.exec("COMMIT"); committed = true
        return result
    }

    private static func encode(_ fields: [String: String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(fields)) ?? Data("{}".utf8), as: UTF8.self)
    }
    private static func decode(_ text: String) -> [String: String]? { try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) }
    private static func optional(_ fields: [String: String]?) -> SQLiteDB.Value { fields.map { .text(encode($0)) } ?? .null }
}

// MARK: Undo recipes for files

/// Undo for the file kinds Pi's changes produce. Each step first checks that the file is still exactly what Pippa
/// recorded (path, inode, hash); anything else stays and is counted as changed.
public enum RunFileRecipes {
    public static func recipe(_ kind: String) -> RunUndoRecipe? {
        switch kind {
        case "file.create": return { row in undoCreate(row) }
        case "file.restore": return { row in undoRestore(row) }
        case "file.move", "file.trash": return { row in undoMove(row) }
        default: return nil
        }
    }

    private static func unchanged(_ row: RunAction) -> RunUndoOutcome? {
        guard let path = row.object.fields["path"] else { return .failed }
        guard FileManager.default.fileExists(atPath: path) else { return .gone }
        guard let expected = row.object.fileIdentity, (try? DurableFileIdentity.capture(URL(fileURLWithPath: path))) == expected else { return .changed }
        return nil
    }

    static func undoCreate(_ row: RunAction) -> RunUndoOutcome {
        if let stop = unchanged(row) { return stop }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: row.object.fields["path"]!), resultingItemURL: nil); return .undone }
        catch { return .failed }
    }

    /// The old version comes back from the kept copy; the version Pi wrote goes to the Trash (never deleted).
    static func undoRestore(_ row: RunAction) -> RunUndoOutcome {
        guard let copy = row.object.fields["copy"], FileManager.default.fileExists(atPath: copy) else { return .failed }
        if let stop = unchanged(row), stop != .gone { return stop }
        let target = URL(fileURLWithPath: row.object.fields["path"]!)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: copy), to: target)
            return .undone
        } catch { return .failed }
    }

    /// Back to the old place, only if it is free; never overwrites.
    static func undoMove(_ row: RunAction) -> RunUndoOutcome {
        if let stop = unchanged(row) { return stop }
        guard let from = row.object.fields["from"], let path = row.object.fields["path"] else { return .failed }
        guard !FileManager.default.fileExists(atPath: from) else { return .changed }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: from).deletingLastPathComponent(), withIntermediateDirectories: true)
        return renamex_np(path, from, UInt32(RENAME_EXCL)) == 0 ? .undone : .failed
    }
}
