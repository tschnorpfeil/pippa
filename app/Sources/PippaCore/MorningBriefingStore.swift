import Darwin
import Foundation

/// Transactions claim an occurrence before reading, and every callback checks the persisted
/// generation. Separate windows or processes cannot duplicate a claim or overwrite a later pause.
@MainActor
public final class MorningBriefingStore {
    public struct Claim: Codable, Sendable, Equatable {
        public var id: UUID
        public var generation: UUID
        public var occurrence: MorningBriefingOccurrence
        fileprivate var ownerSession: UUID
        fileprivate var ownerPID: Int32
    }
    private struct State: Codable, Equatable {
        var schema = 1
        var configuration = MorningBriefingConfiguration()
        var generation = UUID()
        var claimedDays: [String] = []
        var active: Claim?
        var latest: MorningBriefingResult?
    }
    public enum Failure: Error { case invalidConfiguration, unsupportedStore, unreadable }
    private static let processSession = UUID()
    private let session: UUID
    private let db: SQLiteDB
    public var configuration: MorningBriefingConfiguration { (try? read()).map(\.configuration) ?? MorningBriefingConfiguration() }
    public var latest: MorningBriefingResult? { (try? read())?.latest }
    public func current() throws -> (configuration: MorningBriefingConfiguration, latest: MorningBriefingResult?) {
        let state = try read(); return (state.configuration, state.latest)
    }

    /// The session override models a dead process in checks. Production stores in one process
    /// share a session; merely constructing a second AppModel must not recover a live run.
    public init(baseDirectory: URL = Pippa.supportDirectory, processSessionID: UUID? = nil) throws {
        guard baseDirectory.isFileURL else { throw Failure.unreadable }
        let directory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("MorningBriefing", isDirectory: true)
        let file = directory.appendingPathComponent("routine.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              !((try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false) else { throw Failure.unreadable }
        session = processSessionID ?? Self.processSession
        db = try SQLiteDB(path: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
        guard version <= 1 else { throw Failure.unsupportedStore }
        try db.exec("CREATE TABLE IF NOT EXISTS morning_routine(id INTEGER PRIMARY KEY CHECK(id=1), record TEXT NOT NULL); PRAGMA user_version=1;")
        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.exec("ROLLBACK") } }
        if try db.query("SELECT id FROM morning_routine").isEmpty { try write(State()) }
        var recovered = try read()
        if let interrupted = recovered.active, interrupted.ownerSession != session {
            let alive = interrupted.ownerPID > 0 && (kill(interrupted.ownerPID, 0) == 0 || errno == EPERM)
            let syntheticRestart = processSessionID != nil && interrupted.ownerPID == getpid()
            if !alive || syntheticRestart {
                recovered.active = nil; recovered.generation = UUID()
                recovered.latest = MorningBriefingResult(occurrence: interrupted.occurrence, readAt: Date(), entries: [],
                    checkedSources: [], issues: [.init(source: nil, reason: .interrupted)])
                try write(recovered)
            }
        }
        try db.exec("COMMIT"); committed = true
    }

    public func configure(_ configuration: MorningBriefingConfiguration) throws {
        guard !configuration.enabled || configuration.isValid else { throw Failure.invalidConfiguration }
        try transaction { next in
            if Set(configuration.sources.map(\.id)) != Set(next.configuration.sources.map(\.id)) { next.latest = nil }
            next.configuration = configuration; next.generation = UUID(); next.active = nil
        }
    }

    public func delete() throws {
        try transaction { next in
            let days = next.claimedDays
            next = State()
            // Date-only dedup retains no source or result data. Remove/re-enable cannot replay today.
            next.claimedDays = days
        }
    }

    public func claim(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws -> Claim? {
        try transaction { next in
            guard next.active == nil, let occurrence = MorningBriefingSchedule.due(next.configuration, now: now, calendar: calendar),
                  !next.claimedDays.contains(occurrence.key) else { return nil }
            let claim = Claim(id: UUID(), generation: next.generation, occurrence: occurrence, ownerSession: session, ownerPID: getpid())
            next.claimedDays.append(occurrence.key); next.claimedDays = Array(next.claimedDays.suffix(400))
            next.active = claim
            return claim
        }
    }

    public func isCurrent(_ claim: Claim) -> Bool {
        guard let current = try? read() else { return false }
        return current.configuration.enabled && current.generation == claim.generation && current.active == claim
            && claim.ownerSession == session
    }

    public func allowsNotification(after claim: Claim) -> Bool {
        guard let current = try? read() else { return false }
        return current.configuration.enabled && current.configuration.notify && current.generation == claim.generation
            && current.latest?.occurrence == claim.occurrence && claim.ownerSession == session
    }

    @discardableResult public func finish(_ claim: Claim, result: MorningBriefingResult) throws -> Bool {
        try transaction { next in
            guard next.configuration.enabled, next.generation == claim.generation, next.active == claim,
                  claim.ownerSession == session, result.occurrence == claim.occurrence else { return false }
            next.active = nil; next.latest = result
            return true
        }
    }

    private func read() throws -> State {
        let rows = try db.query("SELECT record FROM morning_routine WHERE id=1")
        guard rows.count == 1, let text = rows.first?.first?.string,
              let state = try? JSONDecoder().decode(State.self, from: Data(text.utf8)) else { throw Failure.unreadable }
        guard state.schema == 1 else { throw Failure.unsupportedStore }
        guard (!state.configuration.enabled || state.configuration.isValid), state.claimedDays.count <= 400,
              state.active.map({ $0.ownerPID > 0 && $0.generation == state.generation && state.claimedDays.contains($0.occurrence.key) }) ?? true
        else { throw Failure.unreadable }
        return state
    }

    private func write(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(state), as: UTF8.self)
        try db.run("INSERT INTO morning_routine(id,record) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record", [.text(text)])
    }

    private func transaction<Value>(_ body: (inout State) throws -> Value) throws -> Value {
        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.exec("ROLLBACK") } }
        let before = try read()
        var state = before
        let value = try body(&state)
        if state != before { try write(state) }
        try db.exec("COMMIT"); committed = true
        return value
    }
}
