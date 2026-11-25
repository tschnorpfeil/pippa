import Foundation

public enum ProactiveRoutineStoreError: Error, Sendable, Equatable {
    case unreadable
    case unsupportedVersion
    case invalidRequest
    /// Another routine already holds this `builtInKey`.
    case builtInKeyConflict
    case unknownRoutine
    case persistenceFailed
}

public enum RoutineRunInsertResult: Sendable, Equatable {
    case recorded(RoutineRunRecord)
    /// This routine already ran for this slot (`UNIQUE(routine_id, slot_key)`); nothing was written.
    case duplicateSlot
}

/// SQLite store for routines, their runs and their diff snapshots (`Proactivity/routines.sqlite`).
/// Separate from `proactivity.sqlite`, which stays at schema version 1 for Pippa 1.1.0.
public actor ProactiveRoutineStore {
    public nonisolated let baseDirectory: URL
    public nonisolated let databaseURL: URL
    private let db: SQLiteDB

    public static let schemaVersion = 1
    static let maxSnapshotBytes = 1_048_576

    public init(baseDirectory: URL = Pippa.supportDirectory) throws {
        guard baseDirectory.isFileURL else { throw ProactiveRoutineStoreError.invalidRequest }
        self.baseDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = self.baseDirectory.appendingPathComponent("Proactivity", isDirectory: true)
        self.databaseURL = directory.appendingPathComponent("routines.sqlite")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
                  !((try? databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false)
            else {
                throw ProactiveRoutineStoreError.unreadable
            }
            db = try SQLiteDB(path: databaseURL.path)
            try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
            guard version <= 1 else { throw ProactiveRoutineStoreError.unsupportedVersion }
            try db.exec("""
                CREATE TABLE IF NOT EXISTS routines(
                    id TEXT PRIMARY KEY,
                    built_in_key TEXT UNIQUE,
                    record_json TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS routine_runs(
                    id TEXT PRIMARY KEY,
                    routine_id TEXT NOT NULL,
                    routine_title TEXT NOT NULL,
                    slot_key TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    matter_id TEXT,
                    input_hash TEXT,
                    detail TEXT,
                    started_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    UNIQUE(routine_id, slot_key)
                );
                CREATE INDEX IF NOT EXISTS idx_routine_runs_started ON routine_runs(started_at);
                CREATE TABLE IF NOT EXISTS routine_snapshots(
                    routine_id TEXT PRIMARY KEY,
                    payload_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                PRAGMA user_version=1;
                """)
        } catch let error as ProactiveRoutineStoreError {
            throw error
        } catch {
            throw ProactiveRoutineStoreError.persistenceFailed
        }
    }

    // MARK: Routines

    /// Inserts or replaces a routine by `id`. A `builtInKey` held by a different routine is refused.
    public func upsert(_ routine: ProactiveRoutine) throws {
        try validate(routine)
        let json = try Self.encode(routine)
        try transaction {
            if let key = routine.builtInKey {
                let holders = try db.query("SELECT id FROM routines WHERE built_in_key=?", [.text(key)])
                if let holder = holders.first?.first?.string, holder != routine.id.uuidString {
                    throw ProactiveRoutineStoreError.builtInKeyConflict
                }
            }
            try db.run(
                """
                INSERT INTO routines(id, built_in_key, record_json, enabled, updated_at) VALUES(?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET built_in_key=excluded.built_in_key, record_json=excluded.record_json,
                    enabled=excluded.enabled, updated_at=excluded.updated_at
                """,
                [.text(routine.id.uuidString), routine.builtInKey.map { .text($0) } ?? .null, .text(json),
                 .int(routine.enabled ? 1 : 0), .real(routine.updatedAt.timeIntervalSince1970)]
            )
        }
    }

    public func routine(id: UUID) throws -> ProactiveRoutine? {
        try readRoutines("WHERE id=?", [.text(id.uuidString)]).first
    }

    public func routine(builtInKey: String) throws -> ProactiveRoutine? {
        try readRoutines("WHERE built_in_key=?", [.text(builtInKey)]).first
    }

    /// Oldest first, so lists keep their order as routines are added.
    public func allRoutines() throws -> [ProactiveRoutine] {
        try readRoutines("", []).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    @discardableResult
    public func setEnabled(id: UUID, enabled: Bool, now: Date = Date()) throws -> ProactiveRoutine {
        try transaction {
            guard var current = try readRoutines("WHERE id=?", [.text(id.uuidString)]).first else {
                throw ProactiveRoutineStoreError.unknownRoutine
            }
            current.enabled = enabled
            current.updatedAt = now
            try db.run("UPDATE routines SET record_json=?, enabled=?, updated_at=? WHERE id=?",
                       [.text(try Self.encode(current)), .int(enabled ? 1 : 0), .real(now.timeIntervalSince1970), .text(id.uuidString)])
            return current
        }
    }

    /// Removes the routine and its snapshot. Its run history stays for the activity list.
    public func delete(id: UUID) throws {
        try transaction {
            try db.run("DELETE FROM routines WHERE id=?", [.text(id.uuidString)])
            try db.run("DELETE FROM routine_snapshots WHERE routine_id=?", [.text(id.uuidString)])
        }
    }

    // MARK: Runs

    /// Records one run; a second run for the same routine and slot is refused, never overwritten.
    public func recordRun(_ run: RoutineRunRecord) throws -> RoutineRunInsertResult {
        guard !run.slotKey.isEmpty, run.slotKey.utf8.count <= 64, !run.slotKey.contains("\0"),
              run.routineTitle.utf8.count <= 4096, (run.detail?.utf8.count ?? 0) <= 16_384,
              (run.inputHash?.utf8.count ?? 0) <= 512,
              run.startedAt.timeIntervalSince1970.isFinite, run.finishedAt.timeIntervalSince1970.isFinite
        else {
            throw ProactiveRoutineStoreError.invalidRequest
        }
        return try transaction {
            let existing = try db.query("SELECT 1 FROM routine_runs WHERE routine_id=? AND slot_key=?",
                                        [.text(run.routineID.uuidString), .text(run.slotKey)])
            guard existing.isEmpty else { return .duplicateSlot }
            try db.run(
                """
                INSERT INTO routine_runs(id, routine_id, routine_title, slot_key, outcome, matter_id, input_hash, detail, started_at, finished_at)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """,
                [.text(run.id.uuidString), .text(run.routineID.uuidString), .text(run.routineTitle), .text(run.slotKey),
                 .text(run.outcome.rawValue), run.matterID.map { .text($0.uuidString) } ?? .null,
                 run.inputHash.map { .text($0) } ?? .null, run.detail.map { .text($0) } ?? .null,
                 .real(run.startedAt.timeIntervalSince1970), .real(run.finishedAt.timeIntervalSince1970)]
            )
            return .recorded(run)
        }
    }

    public func hasRun(routineID: UUID, slotKey: String) throws -> Bool {
        !(try db.query("SELECT 1 FROM routine_runs WHERE routine_id=? AND slot_key=?",
                       [.text(routineID.uuidString), .text(slotKey)])).isEmpty
    }

    /// Newest first, across all routines.
    public func recentRuns(limit: Int = 50) throws -> [RoutineRunRecord] {
        try readRuns("ORDER BY started_at DESC, rowid DESC LIMIT ?", [.int(Int64(min(max(limit, 0), 1000)))])
    }

    /// Newest first, for one routine.
    public func runs(for routineID: UUID, limit: Int = 20) throws -> [RoutineRunRecord] {
        try readRuns("WHERE routine_id=? ORDER BY started_at DESC, rowid DESC LIMIT ?",
                     [.text(routineID.uuidString), .int(Int64(min(max(limit, 0), 1000)))])
    }

    // MARK: Snapshots

    /// The last state a watcher compared against (`CalendarRadarBuilder`), or `nil` before its first run.
    public func snapshot(for routineID: UUID) throws -> String? {
        try db.query("SELECT payload_json FROM routine_snapshots WHERE routine_id=?", [.text(routineID.uuidString)])
            .first?.first?.string
    }

    public func saveSnapshot(_ payload: String, for routineID: UUID, now: Date = Date()) throws {
        guard payload.utf8.count <= Self.maxSnapshotBytes, !payload.contains("\0") else {
            throw ProactiveRoutineStoreError.invalidRequest
        }
        try transaction {
            try db.run("INSERT OR REPLACE INTO routine_snapshots(routine_id, payload_json, updated_at) VALUES(?,?,?)",
                       [.text(routineID.uuidString), .text(payload), .real(now.timeIntervalSince1970)])
        }
    }

    // MARK: Private

    private func validate(_ routine: ProactiveRoutine) throws {
        guard !routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, routine.title.utf8.count <= 512,
              routine.instruction.utf8.count <= 8192,
              (routine.builtInKey.map { !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") } ?? true),
              (routine.lastSummary?.utf8.count ?? 0) <= 16_384,
              routine.updatedAt.timeIntervalSince1970.isFinite
        else {
            throw ProactiveRoutineStoreError.invalidRequest
        }
    }

    private func readRoutines(_ condition: String, _ arguments: [SQLiteDB.Value]) throws -> [ProactiveRoutine] {
        let rows = try db.query("SELECT id, record_json, enabled FROM routines \(condition)", arguments)
        return try rows.map { row in
            guard row.count == 3, let id = row[0].string, let json = row[1].string, let enabled = row[2].int,
                  var routine = try? JSONDecoder().decode(ProactiveRoutine.self, from: Data(json.utf8)),
                  routine.id.uuidString == id
            else {
                throw ProactiveRoutineStoreError.unreadable
            }
            routine.enabled = enabled != 0
            return routine
        }
    }

    private func readRuns(_ condition: String, _ arguments: [SQLiteDB.Value]) throws -> [RoutineRunRecord] {
        let rows = try db.query(
            """
            SELECT id, routine_id, routine_title, slot_key, outcome, matter_id, input_hash, detail, started_at, finished_at
            FROM routine_runs \(condition)
            """,
            arguments
        )
        return try rows.map { row in
            guard row.count == 10,
                  let idStr = row[0].string, let id = UUID(uuidString: idStr),
                  let routineStr = row[1].string, let routineID = UUID(uuidString: routineStr),
                  let title = row[2].string, let slot = row[3].string,
                  let outcomeStr = row[4].string, let outcome = RoutineRunOutcome(rawValue: outcomeStr),
                  let started = Self.double(row[8]), let finished = Self.double(row[9])
            else {
                throw ProactiveRoutineStoreError.unreadable
            }
            return RoutineRunRecord(id: id, routineID: routineID, routineTitle: title, slotKey: slot, outcome: outcome,
                                    matterID: row[5].string.flatMap(UUID.init(uuidString:)), inputHash: row[6].string,
                                    detail: row[7].string, startedAt: Date(timeIntervalSince1970: started),
                                    finishedAt: Date(timeIntervalSince1970: finished))
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            try db.exec("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? db.exec("ROLLBACK") } }
            let result = try body()
            try db.exec("COMMIT")
            committed = true
            return result
        } catch let error as ProactiveRoutineStoreError {
            throw error
        } catch {
            throw ProactiveRoutineStoreError.persistenceFailed
        }
    }

    private static func encode(_ routine: ProactiveRoutine) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(routine) else { throw ProactiveRoutineStoreError.invalidRequest }
        return String(decoding: data, as: UTF8.self)
    }

    private static func double(_ value: SQLiteDB.Value) -> Double? {
        switch value {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}
