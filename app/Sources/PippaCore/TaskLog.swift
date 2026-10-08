import Foundation

/// Kind of the thing an action was chosen for. By the thing, not by the action.
public enum TaskKind: String, Sendable, Codable, CaseIterable {
    case scans, letter, mail, table, form, text, folder, invoices, lookup

    /// Classification by kind and extension, without reading the file. Several images or PDFs are scans.
    /// Nil for links, mixed and unknown: there is no habit for those.
    public static func guess(for kind: DropKind, fileExtension: String? = nil, count: Int = 1) -> TaskKind? {
        let ext = fileExtension?.lowercased() ?? ""
        switch kind {
        case .folder: return .folder
        case .mail: return .mail
        case .pdf, .image: return count > 1 ? .scans : .letter
        case .text: return ["csv", "tsv"].contains(ext) ? .table : .text
        case .office: return ["xlsx", "xls", "ods", "numbers"].contains(ext) ? .table : .text
        case .link, .mixed, .other: return nil
        }
    }

    /// Position of the capability buttons in the conversation (`PippaSkill.Place`) as a kind. The empty conversation has none.
    public init?(place: PippaSkill.Place) {
        switch place {
        case .brief: self = .letter
        case .text, .dokument: self = .text
        case .tabelle: self = .table
        case .immer: return nil
        }
    }
}

/// How a chosen action turned out.
public enum TaskOutcome: String, Sendable, Codable { case kept, edited, undone }

/// Where the result went: kind and short name ("Rechnungen 2026", "Mail"). Never a path, never document text.
public struct TaskTarget: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case folder, table, file, inserted, dragged, calendar }
    public var kind: Kind
    public var label: String?
    public init(kind: Kind, label: String? = nil) { self.kind = kind; self.label = label }
}

/// A line in the task log: what was offered, what was chosen, how it turned out.
/// No document text, no amounts, no addresses.
public struct TaskRecord: Sendable, Hashable {
    public var id: Int64?
    public var at: Date
    public var kind: TaskKind
    /// Short derived name of the source (sender, issuer, website), else nil.
    public var sourceLabel: String?
    /// Identifiers of the shown actions (skill names or `Action.rawValue`), in display order.
    public var offered: [String]
    /// Chosen action; nil = skipped.
    public var chosen: String?
    public var target: TaskTarget?
    public var outcome: TaskOutcome?
    /// "Nicht merken": only the kind is stored, without names of source and target.
    public var isPrivate: Bool

    public init(id: Int64? = nil, at: Date = Date(), kind: TaskKind, sourceLabel: String? = nil, offered: [String], chosen: String? = nil,
                target: TaskTarget? = nil, outcome: TaskOutcome? = nil, isPrivate: Bool = false) {
        self.id = id; self.at = at; self.kind = kind; self.sourceLabel = sourceLabel; self.offered = offered; self.chosen = chosen
        self.target = target; self.outcome = outcome; self.isPrivate = isPrivate
    }
}

/// Events for the counts (without content).
public enum TaskEvent: String, Sendable, CaseIterable {
    case permissionAsked = "permission_asked", granted, declined, resultLeft = "result_left"
}

/// Task log: `tasklog.sqlite` in Application Support, one line per action.
/// Stays on the Mac. Lines older than twelve months drop out on open; "Alles vergessen" clears both tables.
public actor TaskLog {
    let db: SQLiteDB

    /// Retention in months.
    public static let keepMonths = 12
    public static let fileName = "tasklog.sqlite"

    public init(baseDirectory: URL = Pippa.supportDirectory, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try self.init(path: baseDirectory.appendingPathComponent(Self.fileName).path, now: now)
    }

    /// `":memory:"` for tests.
    public init(path: String, now: Date = Date()) throws {
        db = try SQLiteDB(path: path)
        try db.exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS actions(
                id INTEGER PRIMARY KEY, at REAL NOT NULL,
                kind TEXT NOT NULL,
                source_label TEXT,
                offered TEXT NOT NULL,
                chosen TEXT,
                target_kind TEXT,
                target_label TEXT,
                outcome TEXT,
                private INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS actions_kind_at ON actions(kind, at);
            CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, at REAL, name TEXT);
            """)
        try Self.prune(db, now: now)
    }

    /// Edge of the rolling window: everything before it is deleted.
    public static func cutoff(now: Date) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: -keepMonths, to: now) ?? now.addingTimeInterval(-365 * 86_400)
    }

    private static func prune(_ db: SQLiteDB, now: Date) throws {
        let limit = SQLiteDB.Value.real(cutoff(now: now).timeIntervalSince1970)
        try db.run("DELETE FROM actions WHERE at < ?", [limit])
        try db.run("DELETE FROM events WHERE at < ?", [limit])
    }

    /// Writes a row and returns its identifier (for `setOutcome`).
    @discardableResult
    public func record(_ record: TaskRecord) throws -> Int64 {
        let offered = String(decoding: try JSONEncoder().encode(record.offered), as: UTF8.self)
        func text(_ s: String?) -> SQLiteDB.Value { if let s { return .text(s) }; return .null }
        let rows = try db.query("""
            INSERT INTO actions(at, kind, source_label, offered, chosen, target_kind, target_label, outcome, private)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
            """, [.real(record.at.timeIntervalSince1970), .text(record.kind.rawValue),
                  record.isPrivate ? .null : text(record.sourceLabel), .text(offered), text(record.chosen),
                  text(record.target?.kind.rawValue), record.isPrivate ? .null : text(record.target?.label),
                  text(record.outcome?.rawValue), .int(record.isPrivate ? 1 : 0)])
        guard let id = rows.first?.first?.int else { throw SQLiteDB.DBError(description: "tasklog insert") }
        return id
    }

    /// Fill in the outcome later (kept, edited, undone).
    public func setOutcome(_ outcome: TaskOutcome, for id: Int64) throws {
        try db.run("UPDATE actions SET outcome = ? WHERE id = ?", [.text(outcome.rawValue), .int(id)])
    }

    /// Fill in the target once it is known (e.g. after filing). With "Nicht merken" without names.
    public func setTarget(_ target: TaskTarget, for id: Int64) throws {
        try db.run("UPDATE actions SET target_kind = ?, target_label = CASE WHEN private = 1 THEN NULL ELSE ? END WHERE id = ?",
                   [.text(target.kind.rawValue), target.label.map(SQLiteDB.Value.text) ?? .null, .int(id)])
    }

    /// Rows, newest first; optionally only one kind.
    public func records(kind: TaskKind? = nil, limit: Int = 500) throws -> [TaskRecord] {
        let columns = "id, at, kind, source_label, offered, chosen, target_kind, target_label, outcome, private"
        let filter = kind == nil ? "" : "WHERE kind = ? "
        var args: [SQLiteDB.Value] = []
        if let kind { args.append(.text(kind.rawValue)) }
        args.append(.int(Int64(limit)))
        let rows = try db.query("SELECT \(columns) FROM actions \(filter)ORDER BY at DESC, id DESC LIMIT ?", args)
        return rows.compactMap { row in
            guard row.count == 10, let kind = row[2].string.flatMap(TaskKind.init(rawValue:)) else { return nil }
            let offered = row[4].string.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            let target = row[6].string.flatMap(TaskTarget.Kind.init(rawValue:)).map { TaskTarget(kind: $0, label: row[7].string) }
            return TaskRecord(id: row[0].int, at: Date(timeIntervalSince1970: row[1].double ?? 0), kind: kind, sourceLabel: row[3].string,
                              offered: offered, chosen: row[5].string, target: target,
                              outcome: row[8].string.flatMap(TaskOutcome.init(rawValue:)), isPrivate: row[9].int == 1)
        }
    }

    public func log(_ event: TaskEvent, at: Date = Date()) throws {
        try db.run("INSERT INTO events(at, name) VALUES(?, ?)", [.real(at.timeIntervalSince1970), .text(event.rawValue)])
    }

    public func count(_ event: TaskEvent) throws -> Int {
        let rows = try db.query("SELECT COUNT(*) FROM events WHERE name = ?", [.text(event.rawValue)])
        return Int(rows.first?.first?.int ?? 0)
    }

    /// "Alles vergessen": clears both tables.
    public func forgetEverything() throws {
        try db.exec("DELETE FROM actions; DELETE FROM events; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
}
