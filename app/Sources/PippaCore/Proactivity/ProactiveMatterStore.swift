import Foundation

public enum ProactiveMatterState: String, Codable, Sendable, Equatable, Hashable {
    case open
    case offered
    case snoozed
    case dismissed
    case resolved

    public var isHumanClosed: Bool {
        self == .dismissed || self == .resolved
    }
}

public enum ProactiveMatterStoreError: Error, Sendable, Equatable {
    case unreadable
    case unsupportedVersion
    case invalidRequest
    case unknownMatter
    case persistenceFailed
}

/// A proactive item prepared by a zero-token watcher or deterministic builder.
/// Background code may open or update it, while only a `PersonAction` may close or snooze it.
public struct ProactiveMatter: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: ProactiveMatterKind
    public let matterKey: String
    public var sourceRef: String
    public var sourceVersion: String
    public var title: String
    public var summary: String
    public var preparedPrompt: String
    public var preparedFiles: [String]
    public var state: ProactiveMatterState
    public var snoozedUntil: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ProactiveMatterKind,
        matterKey: String,
        sourceRef: String,
        sourceVersion: String,
        title: String,
        summary: String,
        preparedPrompt: String,
        preparedFiles: [String] = [],
        state: ProactiveMatterState = .open,
        snoozedUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.matterKey = matterKey
        self.sourceRef = sourceRef
        self.sourceVersion = sourceVersion
        self.title = title
        self.summary = summary
        self.preparedPrompt = preparedPrompt
        self.preparedFiles = preparedFiles
        self.state = state
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Background-prepared payload for creating or updating a matter without granting closure authority.
public struct ProactiveMatterDraft: Sendable, Equatable {
    public let kind: ProactiveMatterKind
    public let matterKey: String
    public let sourceRef: String
    public let sourceVersion: String
    public let title: String
    public let summary: String
    public let preparedPrompt: String
    public let preparedFiles: [String]

    public init(
        kind: ProactiveMatterKind,
        matterKey: String,
        sourceRef: String,
        sourceVersion: String,
        title: String,
        summary: String,
        preparedPrompt: String,
        preparedFiles: [String] = []
    ) {
        self.kind = kind
        self.matterKey = matterKey
        self.sourceRef = sourceRef
        self.sourceVersion = sourceVersion
        self.title = title
        self.summary = summary
        self.preparedPrompt = preparedPrompt
        self.preparedFiles = preparedFiles
    }
}

/// Explicit UI-originated human action required to resolve, dismiss, or snooze a matter.
/// Intentionally not `Decodable` so untrusted text or model output can never construct one.
public struct PersonAction: Sendable, Equatable {
    public enum Intent: Sendable, Equatable {
        case resolve
        case dismiss
        case snooze(until: Date)
    }

    public enum Surface: String, Sendable, Equatable {
        case island
        case panel
        case settings
        case check
    }

    public let intent: Intent
    public let actedAt: Date
    public let surface: Surface

    private init(intent: Intent, actedAt: Date, surface: Surface) {
        self.intent = intent
        self.actedAt = actedAt
        self.surface = surface
    }

    public static func resolve(at date: Date = Date(), surface: Surface = .island) -> PersonAction {
        PersonAction(intent: .resolve, actedAt: date, surface: surface)
    }

    public static func dismiss(at date: Date = Date(), surface: Surface = .island) -> PersonAction {
        PersonAction(intent: .dismiss, actedAt: date, surface: surface)
    }

    public static func snooze(until: Date, at date: Date = Date(), surface: Surface = .island) -> PersonAction {
        PersonAction(intent: .snooze(until: until), actedAt: date, surface: surface)
    }
}

public struct ProactiveClosure: Codable, Sendable, Equatable {
    public let matterKey: String
    public let state: ProactiveMatterState
    public let sourceVersion: String
    public let closedAt: Date
}

public struct NudgeLogEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let dayKey: String
    public let matterID: UUID
    public let kind: ProactiveMatterKind
    public let shownAt: Date
}

public struct WatchedFileRecord: Codable, Sendable, Equatable {
    public let path: String
    public let identity: DurableFileIdentity
    public let seenAt: Date

    /// Compares file metadata and SHA-256 identity with sub-millisecond timestamp tolerance.
    public func matches(_ other: DurableFileIdentity) -> Bool {
        matchesContent(other)
            && identity.device == other.device
            && identity.inode == other.inode
            && abs(identity.modified.timeIntervalSince1970 - other.modified.timeIntervalSince1970) < 0.001
    }

    /// True when file size and SHA-256 content are identical, even if mtime or inode changed (e.g. atomic save or sync touch).
    public func matchesContent(_ other: DurableFileIdentity) -> Bool {
        identity.size == other.size && identity.sha256 == other.sha256
    }
}

public enum UpsertMatterResult: Sendable, Equatable {
    case created(ProactiveMatter)
    case updated(ProactiveMatter)
    case reopened(ProactiveMatter)
    case keptClosed(ProactiveMatter?)

    public var matter: ProactiveMatter? {
        switch self {
        case .created(let m), .updated(let m), .reopened(let m): return m
        case .keptClosed(let m): return m
        }
    }
}

public enum DeliveryRecordResult: Sendable, Equatable {
    case recorded(NudgeLogEntry)
    case capReached(used: Int, cap: Int)
    case matterNotFound
    case matterClosed
    case staleSource
}

/// SQLite-backed store for Pippa's opt-in proactivity state (`Proactivity/proactivity.sqlite`).
/// Enforces human-closed permanence, atomic daily cap accounting, and watched-file deduplication.
public actor ProactiveMatterStore {
    public nonisolated let baseDirectory: URL
    public nonisolated let databaseURL: URL
    private let db: SQLiteDB

    public init(baseDirectory: URL = Pippa.supportDirectory) throws {
        guard baseDirectory.isFileURL else { throw ProactiveMatterStoreError.invalidRequest }
        self.baseDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = self.baseDirectory.appendingPathComponent("Proactivity", isDirectory: true)
        self.databaseURL = directory.appendingPathComponent("proactivity.sqlite")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
                  !((try? databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false)
            else {
                throw ProactiveMatterStoreError.unreadable
            }
            db = try SQLiteDB(path: databaseURL.path)
            try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
            guard version <= 1 else { throw ProactiveMatterStoreError.unsupportedVersion }
            try db.exec("""
                CREATE TABLE IF NOT EXISTS matters(
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    matter_key TEXT UNIQUE NOT NULL,
                    source_ref TEXT NOT NULL,
                    source_version TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    prepared_prompt TEXT NOT NULL,
                    prepared_files_json TEXT NOT NULL,
                    state TEXT NOT NULL,
                    snoozed_until REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS closures(
                    matter_key TEXT PRIMARY KEY,
                    state TEXT NOT NULL,
                    source_version TEXT NOT NULL,
                    closed_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS nudge_log(
                    id TEXT PRIMARY KEY,
                    day_key TEXT NOT NULL,
                    matter_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    shown_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_nudge_log_day_key ON nudge_log(day_key);
                CREATE TABLE IF NOT EXISTS watched_files(
                    path TEXT PRIMARY KEY,
                    size INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    device INTEGER NOT NULL,
                    inode INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    seen_at REAL NOT NULL
                );
                PRAGMA user_version=1;
                """)
        } catch let error as ProactiveMatterStoreError {
            throw error
        } catch {
            throw ProactiveMatterStoreError.persistenceFailed
        }
    }

    /// Formats a local calendar day key (`YYYY-MM-DD`) in `calendar`'s time zone.
    public nonisolated static func dayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - Matters & Human-Closed Invariant

    /// Creates or updates a prepared matter from background scanning/building.
    /// Never reopens a `dismissed` or `resolved` matter (or a recorded closure) unless `sourceVersion` has changed.
    @discardableResult
    public func upsertPrepared(_ draft: ProactiveMatterDraft, now: Date = Date()) throws -> UpsertMatterResult {
        try validate(draft)
        let filesJSON = try Self.encodeFiles(draft.preparedFiles)
        let timestamp = now.timeIntervalSince1970

        return try transaction {
            let existing = try readMatter(condition: "WHERE matter_key=?", arguments: [.text(draft.matterKey)])
            if let closure = try readClosure(matterKey: draft.matterKey),
               closure.sourceVersion == draft.sourceVersion {
                return .keptClosed(existing)
            }

            if var current = existing {
                if current.state.isHumanClosed {
                    if current.sourceVersion == draft.sourceVersion {
                        return .keptClosed(current)
                    }
                    // Source genuinely changed and was not closed at this version: reopen as open.
                    current.sourceRef = draft.sourceRef
                    current.sourceVersion = draft.sourceVersion
                    current.title = draft.title
                    current.summary = draft.summary
                    current.preparedPrompt = draft.preparedPrompt
                    current.preparedFiles = draft.preparedFiles
                    current.state = .open
                    current.snoozedUntil = nil
                    current.updatedAt = now
                    try updateMatterRow(current, filesJSON: filesJSON)
                    return .reopened(current)
                }

                let versionChanged = current.sourceVersion != draft.sourceVersion
                current.sourceRef = draft.sourceRef
                current.sourceVersion = draft.sourceVersion
                current.title = draft.title
                current.summary = draft.summary
                current.preparedPrompt = draft.preparedPrompt
                current.preparedFiles = draft.preparedFiles
                if versionChanged {
                    current.state = .open
                    current.snoozedUntil = nil
                }
                current.updatedAt = now
                try updateMatterRow(current, filesJSON: filesJSON)
                return .updated(current)
            }

            let created = ProactiveMatter(
                id: UUID(),
                kind: draft.kind,
                matterKey: draft.matterKey,
                sourceRef: draft.sourceRef,
                sourceVersion: draft.sourceVersion,
                title: draft.title,
                summary: draft.summary,
                preparedPrompt: draft.preparedPrompt,
                preparedFiles: draft.preparedFiles,
                state: .open,
                snoozedUntil: nil,
                createdAt: now,
                updatedAt: now
            )
            try db.run(
                """
                INSERT INTO matters(
                    id, kind, matter_key, source_ref, source_version,
                    title, summary, prepared_prompt, prepared_files_json,
                    state, snoozed_until, created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text(created.id.uuidString),
                    .text(created.kind.rawValue),
                    .text(created.matterKey),
                    .text(created.sourceRef),
                    .text(created.sourceVersion),
                    .text(created.title),
                    .text(created.summary),
                    .text(created.preparedPrompt),
                    .text(filesJSON),
                    .text(created.state.rawValue),
                    .null,
                    .real(timestamp),
                    .real(timestamp),
                ]
            )
            return .created(created)
        }
    }

    /// Applies an explicit human action (`resolve`, `dismiss`, or `snooze`) to a matter by ID.
    @discardableResult
    public func apply(_ action: PersonAction, to matterID: UUID) throws -> ProactiveMatter {
        try transaction {
            guard var current = try readMatter(condition: "WHERE id=?", arguments: [.text(matterID.uuidString)]) else {
                throw ProactiveMatterStoreError.unknownMatter
            }
            try applyActionLocked(action, to: &current)
            return current
        }
    }

    /// Applies an explicit human action (`resolve`, `dismiss`, or `snooze`) to a matter by `matterKey`.
    @discardableResult
    public func apply(_ action: PersonAction, toMatterKey matterKey: String) throws -> ProactiveMatter {
        try transaction {
            guard var current = try readMatter(condition: "WHERE matter_key=?", arguments: [.text(matterKey)]) else {
                throw ProactiveMatterStoreError.unknownMatter
            }
            try applyActionLocked(action, to: &current)
            return current
        }
    }

    public func matter(id: UUID) throws -> ProactiveMatter? {
        try readMatter(condition: "WHERE id=?", arguments: [.text(id.uuidString)])
    }

    public func matter(key: String) throws -> ProactiveMatter? {
        try readMatter(condition: "WHERE matter_key=?", arguments: [.text(key)])
    }

    public func matters(states: Set<ProactiveMatterState>? = nil) throws -> [ProactiveMatter] {
        let all = try readMatters()
        guard let states else { return all }
        return all.filter { states.contains($0.state) }
    }

    public func closure(forMatterKey matterKey: String) throws -> ProactiveClosure? {
        try readClosure(matterKey: matterKey)
    }

    // MARK: - Freshness Check

    /// Verifies before delivery that the matter still exists, is not human-closed, and matches `expectedSourceVersion`.
    public func isFresh(matterID: UUID, expectedSourceVersion: String) throws -> Bool {
        guard let current = try matter(id: matterID) else { return false }
        guard !current.state.isHumanClosed else { return false }
        return current.sourceVersion == expectedSourceVersion
    }

    /// Verifies before delivery by querying a live source version for `matter.sourceRef`.
    public func isFresh(
        matterID: UUID,
        currentSourceVersion: @Sendable (String) async throws -> String?
    ) async throws -> Bool {
        guard let current = try matter(id: matterID), !current.state.isHumanClosed else {
            return false
        }
        guard let liveVersion = try await currentSourceVersion(current.sourceRef) else {
            return false
        }
        return liveVersion == current.sourceVersion
    }

    // MARK: - Strict Daily Cap Accounting

    /// Atomically checks the daily cap (strictly bounded to `<= 2`) and logs a nudge delivery in `BEGIN IMMEDIATE`.
    /// Marks the matter as `.offered` in the same transaction. Never exceeds the daily budget.
    public func recordDelivery(
        matterID: UUID,
        kind: ProactiveMatterKind,
        dayKey: String,
        cap: Int,
        expectedSourceVersion: String? = nil,
        shownAt: Date = Date()
    ) throws -> DeliveryRecordResult {
        guard !dayKey.isEmpty, dayKey.utf8.count <= 32, !dayKey.contains("\0") else {
            throw ProactiveMatterStoreError.invalidRequest
        }
        let hardCap = min(max(cap, 0), ProactivitySettings.validDailyCapRange.upperBound)

        return try transaction {
            guard var current = try readMatter(condition: "WHERE id=?", arguments: [.text(matterID.uuidString)]) else {
                return .matterNotFound
            }
            guard !current.state.isHumanClosed else {
                return .matterClosed
            }
            if let expectedSourceVersion, current.sourceVersion != expectedSourceVersion {
                return .staleSource
            }

            let countRows = try db.query(
                "SELECT COUNT(*) FROM nudge_log WHERE day_key=?",
                [.text(dayKey)]
            )
            let used = Int(countRows.first?.first?.int ?? 0)
            guard used < hardCap else {
                return .capReached(used: used, cap: hardCap)
            }

            let entry = NudgeLogEntry(
                id: UUID(),
                dayKey: dayKey,
                matterID: matterID,
                kind: current.kind,
                shownAt: shownAt
            )
            let ts = shownAt.timeIntervalSince1970
            try db.run(
                "INSERT INTO nudge_log(id, day_key, matter_id, kind, shown_at) VALUES(?,?,?,?,?)",
                [
                    .text(entry.id.uuidString),
                    .text(entry.dayKey),
                    .text(entry.matterID.uuidString),
                    .text(entry.kind.rawValue),
                    .real(ts),
                ]
            )

            current.state = .offered
            current.snoozedUntil = nil
            current.updatedAt = shownAt
            try db.run(
                "UPDATE matters SET state=?, snoozed_until=NULL, updated_at=? WHERE id=?",
                [.text(current.state.rawValue), .real(ts), .text(current.id.uuidString)]
            )
            return .recorded(entry)
        }
    }

    public func deliveredCount(forDayKey dayKey: String) throws -> Int {
        let rows = try db.query("SELECT COUNT(*) FROM nudge_log WHERE day_key=?", [.text(dayKey)])
        return Int(rows.first?.first?.int ?? 0)
    }

    public func nudgeLog(forDayKey dayKey: String) throws -> [NudgeLogEntry] {
        let rows = try db.query(
            "SELECT id, day_key, matter_id, kind, shown_at FROM nudge_log WHERE day_key=? ORDER BY shown_at ASC, rowid ASC",
            [.text(dayKey)]
        )
        return try rows.map { row in
            guard row.count == 5,
                  let idStr = row[0].string, let id = UUID(uuidString: idStr),
                  let day = row[1].string,
                  let matterStr = row[2].string, let matterID = UUID(uuidString: matterStr),
                  let kindStr = row[3].string, let kind = ProactiveMatterKind(rawValue: kindStr),
                  let shown = Self.doubleValue(row[4])
            else {
                throw ProactiveMatterStoreError.unreadable
            }
            return NudgeLogEntry(
                id: id,
                dayKey: day,
                matterID: matterID,
                kind: kind,
                shownAt: Date(timeIntervalSince1970: shown)
            )
        }
    }

    // MARK: - Watched Files Deduplication

    public func watchedFile(atPath path: String) throws -> WatchedFileRecord? {
        let rows = try db.query(
            "SELECT path, size, modified, device, inode, sha256, seen_at FROM watched_files WHERE path=?",
            [.text(path)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decodeWatchedFile(row)
    }

    public func upsertWatchedFile(path: String, identity: DurableFileIdentity, seenAt: Date = Date()) throws {
        guard !path.isEmpty, !path.contains("\0"), identity.sha256.count == 64 else {
            throw ProactiveMatterStoreError.invalidRequest
        }
        try transaction {
            try db.run(
                """
                INSERT OR REPLACE INTO watched_files(path, size, modified, device, inode, sha256, seen_at)
                VALUES(?,?,?,?,?,?,?)
                """,
                [
                    .text(path),
                    .int(identity.size),
                    .real(identity.modified.timeIntervalSince1970),
                    .int(Int64(bitPattern: identity.device)),
                    .int(Int64(bitPattern: identity.inode)),
                    .text(identity.sha256),
                    .real(seenAt.timeIntervalSince1970),
                ]
            )
        }
    }

    public func removeWatchedFile(atPath path: String) throws {
        try transaction {
            try db.run("DELETE FROM watched_files WHERE path=?", [.text(path)])
        }
    }

    public func allWatchedFiles() throws -> [WatchedFileRecord] {
        let rows = try db.query(
            "SELECT path, size, modified, device, inode, sha256, seen_at FROM watched_files ORDER BY path ASC"
        )
        return try rows.map(Self.decodeWatchedFile)
    }

    // MARK: - Private Helpers

    private func applyActionLocked(_ action: PersonAction, to matter: inout ProactiveMatter) throws {
        let actedTs = action.actedAt.timeIntervalSince1970
        switch action.intent {
        case .resolve:
            matter.state = .resolved
            matter.snoozedUntil = nil
            matter.updatedAt = action.actedAt
            try db.run(
                "UPDATE matters SET state=?, snoozed_until=NULL, updated_at=? WHERE id=?",
                [.text(matter.state.rawValue), .real(actedTs), .text(matter.id.uuidString)]
            )
            try db.run(
                "INSERT OR REPLACE INTO closures(matter_key, state, source_version, closed_at) VALUES(?,?,?,?)",
                [.text(matter.matterKey), .text(matter.state.rawValue), .text(matter.sourceVersion), .real(actedTs)]
            )
        case .dismiss:
            matter.state = .dismissed
            matter.snoozedUntil = nil
            matter.updatedAt = action.actedAt
            try db.run(
                "UPDATE matters SET state=?, snoozed_until=NULL, updated_at=? WHERE id=?",
                [.text(matter.state.rawValue), .real(actedTs), .text(matter.id.uuidString)]
            )
            try db.run(
                "INSERT OR REPLACE INTO closures(matter_key, state, source_version, closed_at) VALUES(?,?,?,?)",
                [.text(matter.matterKey), .text(matter.state.rawValue), .text(matter.sourceVersion), .real(actedTs)]
            )
        case .snooze(let until):
            guard !matter.state.isHumanClosed else { throw ProactiveMatterStoreError.invalidRequest }
            let untilTs = until.timeIntervalSince1970
            guard untilTs.isFinite else { throw ProactiveMatterStoreError.invalidRequest }
            matter.state = .snoozed
            matter.snoozedUntil = until
            matter.updatedAt = action.actedAt
            try db.run(
                "UPDATE matters SET state=?, snoozed_until=?, updated_at=? WHERE id=?",
                [.text(matter.state.rawValue), .real(untilTs), .real(actedTs), .text(matter.id.uuidString)]
            )
        }
    }

    private func updateMatterRow(_ matter: ProactiveMatter, filesJSON: String) throws {
        let snoozedValue: SQLiteDB.Value = matter.snoozedUntil.map { .real($0.timeIntervalSince1970) } ?? .null
        try db.run(
            """
            UPDATE matters
            SET source_ref=?, source_version=?, title=?, summary=?, prepared_prompt=?,
                prepared_files_json=?, state=?, snoozed_until=?, updated_at=?
            WHERE id=?
            """,
            [
                .text(matter.sourceRef),
                .text(matter.sourceVersion),
                .text(matter.title),
                .text(matter.summary),
                .text(matter.preparedPrompt),
                .text(filesJSON),
                .text(matter.state.rawValue),
                snoozedValue,
                .real(matter.updatedAt.timeIntervalSince1970),
                .text(matter.id.uuidString),
            ]
        )
    }

    private func validate(_ draft: ProactiveMatterDraft) throws {
        guard !draft.matterKey.isEmpty, draft.matterKey.utf8.count <= 1024, !draft.matterKey.contains("\0"),
              !draft.sourceRef.isEmpty, draft.sourceRef.utf8.count <= 4096, !draft.sourceRef.contains("\0"),
              !draft.sourceVersion.isEmpty, draft.sourceVersion.utf8.count <= 512, !draft.sourceVersion.contains("\0"),
              !draft.title.isEmpty, draft.title.utf8.count <= 4096,
              draft.summary.utf8.count <= 16_384,
              draft.preparedPrompt.utf8.count <= 8192,
              draft.preparedFiles.count <= 100
        else {
            throw ProactiveMatterStoreError.invalidRequest
        }
    }

    private func readMatter(condition: String, arguments: [SQLiteDB.Value]) throws -> ProactiveMatter? {
        try readMatters(condition: condition, arguments: arguments).first
    }

    private func readMatters(condition: String = "ORDER BY updated_at DESC, rowid DESC", arguments: [SQLiteDB.Value] = []) throws -> [ProactiveMatter] {
        let rows = try db.query(
            """
            SELECT id, kind, matter_key, source_ref, source_version,
                   title, summary, prepared_prompt, prepared_files_json,
                   state, snoozed_until, created_at, updated_at
            FROM matters \(condition)
            """,
            arguments
        )
        return try rows.map(Self.decodeMatter)
    }

    private func readClosure(matterKey: String) throws -> ProactiveClosure? {
        let rows = try db.query(
            "SELECT matter_key, state, source_version, closed_at FROM closures WHERE matter_key=?",
            [.text(matterKey)]
        )
        guard let row = rows.first else { return nil }
        guard row.count == 4,
              let key = row[0].string,
              let stateStr = row[1].string, let state = ProactiveMatterState(rawValue: stateStr), state.isHumanClosed,
              let version = row[2].string,
              let closedAt = Self.doubleValue(row[3])
        else {
            throw ProactiveMatterStoreError.unreadable
        }
        return ProactiveClosure(
            matterKey: key,
            state: state,
            sourceVersion: version,
            closedAt: Date(timeIntervalSince1970: closedAt)
        )
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
        } catch let error as ProactiveMatterStoreError {
            throw error
        } catch {
            throw ProactiveMatterStoreError.persistenceFailed
        }
    }

    private static func encodeFiles(_ files: [String]) throws -> String {
        let data = try JSONEncoder().encode(files)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeMatter(_ row: [SQLiteDB.Value]) throws -> ProactiveMatter {
        guard row.count == 13,
              let idStr = row[0].string, let id = UUID(uuidString: idStr),
              let kindStr = row[1].string, let kind = ProactiveMatterKind(rawValue: kindStr),
              let matterKey = row[2].string,
              let sourceRef = row[3].string,
              let sourceVersion = row[4].string,
              let title = row[5].string,
              let summary = row[6].string,
              let preparedPrompt = row[7].string,
              let filesJSON = row[8].string,
              let files = try? JSONDecoder().decode([String].self, from: Data(filesJSON.utf8)),
              let stateStr = row[9].string, let state = ProactiveMatterState(rawValue: stateStr),
              let createdAt = doubleValue(row[11]),
              let updatedAt = doubleValue(row[12])
        else {
            throw ProactiveMatterStoreError.unreadable
        }
        let snoozedUntil: Date?
        if case .null = row[10] {
            snoozedUntil = nil
        } else if let ts = doubleValue(row[10]) {
            snoozedUntil = Date(timeIntervalSince1970: ts)
        } else {
            throw ProactiveMatterStoreError.unreadable
        }
        return ProactiveMatter(
            id: id,
            kind: kind,
            matterKey: matterKey,
            sourceRef: sourceRef,
            sourceVersion: sourceVersion,
            title: title,
            summary: summary,
            preparedPrompt: preparedPrompt,
            preparedFiles: files,
            state: state,
            snoozedUntil: snoozedUntil,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func decodeWatchedFile(_ row: [SQLiteDB.Value]) throws -> WatchedFileRecord {
        guard row.count == 7,
              let path = row[0].string,
              let size = row[1].int,
              let modified = doubleValue(row[2]),
              let device = row[3].int,
              let inode = row[4].int,
              let sha256 = row[5].string,
              let seenAt = doubleValue(row[6])
        else {
            throw ProactiveMatterStoreError.unreadable
        }
        let identity = DurableFileIdentity(
            size: size,
            modified: Date(timeIntervalSince1970: modified),
            device: UInt64(bitPattern: device),
            inode: UInt64(bitPattern: inode),
            sha256: sha256
        )
        return WatchedFileRecord(path: path, identity: identity, seenAt: Date(timeIntervalSince1970: seenAt))
    }

    private static func doubleValue(_ value: SQLiteDB.Value) -> Double? {
        switch value {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}
