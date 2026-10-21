import CryptoKit
import Darwin
import Foundation

public enum DurableJobKind: String, Codable, Sendable { case filePreparation, morningBriefing }
public enum DurableJobState: String, Codable, Sendable {
    case queued, running, needsAttention, completed, failed, cancelled
}

public enum DurableJobError: Error, Sendable, Equatable {
    case unreadable, unsupportedVersion, invalidRequest, requestConflict, unknownJob, staleRevision
    case invalidTransition, sourceChanged, artifactOutsideJob, artifactChanged, persistenceFailed
}

/// Metadata and content identity are checked before and after reading. A path alone is never a saved input identity.
public struct DurableFileIdentity: Codable, Sendable, Equatable {
    public let size: Int64
    public let modified: Date
    public let device: UInt64
    public let inode: UInt64
    public let sha256: String

    public static func capture(_ url: URL) throws -> Self {
        let before = try metadata(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            digest.update(data: data)
        }
        let after = try metadata(url)
        guard before == after else { throw DurableJobError.sourceChanged }
        return .init(size: before.size, modified: before.modified, device: before.device, inode: before.inode,
                     sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct Metadata: Equatable {
        let size: Int64
        let modified: Date
        let device: UInt64
        let inode: UInt64
    }
    private static func metadata(_ url: URL) throws -> Metadata {
        guard url.isFileURL else { throw DurableJobError.invalidRequest }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw DurableJobError.invalidRequest }
        return .init(size: size.int64Value, modified: modified, device: device.uint64Value, inode: inode.uint64Value)
    }
}

/// Saved order, original location, grant and content identity belong to the request, not the current tray.
public struct DurableJobInput: Codable, Sendable, Equatable {
    public let url: URL
    public let bookmark: Data?
    public let identity: DurableFileIdentity

    public static func capture(url: URL, bookmark: Data? = nil) throws -> Self {
        guard url.isFileURL else { throw DurableJobError.invalidRequest }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        return .init(url: source,
                     bookmark: bookmark ?? (try? source.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                                    includingResourceValuesForKeys: nil, relativeTo: nil)),
                     identity: try DurableFileIdentity.capture(source))
    }

    /// Bookmark lookup never shows a dialog. A moved or edited source needs the person's attention before work resumes.
    public func resolvedURL() throws -> URL {
        var resolved = url
        if let bookmark {
            var stale = false
            if let candidate = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withSecurityScope],
                                        relativeTo: nil, bookmarkDataIsStale: &stale) {
                guard !stale else { throw DurableJobError.sourceChanged }
                resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        let accessed = resolved.startAccessingSecurityScopedResource()
        defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
        guard try DurableFileIdentity.capture(resolved) == identity else { throw DurableJobError.sourceChanged }
        return resolved
    }
}

public struct DurableJobArtifact: Codable, Sendable, Equatable {
    public let url: URL
    public let identity: DurableFileIdentity
}

public struct DurableJobRun: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let token: UUID
    public let revision: Int
}

public struct DurableJobRecord: Codable, Identifiable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let kind: DurableJobKind
    public let requestKey: String
    public let conversationID: UUID?
    public let title: String
    public let inputs: [DurableJobInput]
    public let payload: Data
    public let payloadVersion: Int
    public let created: Date
    public fileprivate(set) var updated: Date
    public fileprivate(set) var state: DurableJobState
    public fileprivate(set) var revision: Int
    public fileprivate(set) var runToken: UUID?
    public fileprivate(set) var resultData: Data?
    public fileprivate(set) var artifacts: [DurableJobArtifact]
    public fileprivate(set) var issue: String?
    fileprivate var processSession: UUID?
    fileprivate var processID: Int32?
    /// Kept after completion so a Stop already in flight can cancel only its own immediately completed attempt.
    fileprivate var lastRunToken: UUID?
}

/// A durable journal for local workflows. It schedules no work and grants no authority to an agent.
/// SQLite transactions fence independent connections; run tokens fence callbacks after Stop, retry or restart.
public actor DurableJobStore {
    private static let processSession = UUID()
    public nonisolated let baseDirectory: URL
    public nonisolated let databaseURL: URL
    private let db: SQLiteDB
    private let session: UUID

    public nonisolated static func artifactsDirectory(baseDirectory: URL = Pippa.supportDirectory) -> URL {
        baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("DurableJobs/Artifacts", isDirectory: true)
    }

    /// `processSessionID` is a synthetic restart hook for checks; production instances share the process session.
    public init(baseDirectory: URL = Pippa.supportDirectory, processSessionID: UUID? = nil) throws {
        guard baseDirectory.isFileURL else { throw DurableJobError.invalidRequest }
        self.baseDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = self.baseDirectory.appendingPathComponent("DurableJobs", isDirectory: true)
        self.databaseURL = directory.appendingPathComponent("jobs.sqlite")
        self.session = processSessionID ?? Self.processSession
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
                  !((try? databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false)
            else { throw DurableJobError.unreadable }
            db = try SQLiteDB(path: databaseURL.path)
            try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
            guard version <= 1 else { throw DurableJobError.unsupportedVersion }
            try db.exec("""
                CREATE TABLE IF NOT EXISTS durable_jobs(
                    id TEXT PRIMARY KEY, request_key TEXT UNIQUE NOT NULL, state TEXT NOT NULL,
                    revision INTEGER NOT NULL, record TEXT NOT NULL);
                PRAGMA user_version=1;
                """)
            try db.exec("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? db.exec("ROLLBACK") } }
            let records = try Self.readRows(db)
            for var record in records where record.state == .running && record.processSession != self.session {
                // Another live process may own the run. Do not manufacture a restart or steal its token.
                let ownerIsAlive = record.processID.map { kill($0, 0) == 0 || errno == EPERM } ?? false
                let syntheticRestart = processSessionID != nil && record.processID == getpid()
                guard !ownerIsAlive || syntheticRestart else { continue }
                record.state = .needsAttention; record.runToken = nil; record.processSession = nil; record.processID = nil
                record.issue = "interrupted"; record.updated = Date()
                try Self.write(&record, db: db)
            }
            try db.exec("COMMIT"); committed = true
        } catch let error as DurableJobError { throw error }
        catch { throw DurableJobError.persistenceFailed }
    }

    public func records() throws -> [DurableJobRecord] { try Self.readRows(db) }

    public func record(id: UUID) throws -> DurableJobRecord {
        guard let record = try Self.readRows(db, condition: "WHERE id=?", arguments: [.text(id.uuidString)]).first
        else { throw DurableJobError.unknownJob }
        return record
    }

    public func record(requestKey: String) throws -> DurableJobRecord? {
        try Self.readRows(db, condition: "WHERE request_key=?", arguments: [.text(requestKey)]).first
    }

    /// A cancelled or failed producer may discard only its unchanged unpublished copies, never another attempt's files.
    public func discardUnpublishedArtifacts(_ artifacts: [DurableJobArtifact], run: DurableJobRun) throws {
        try transaction {
            let record = try record(id: run.jobID)
            guard record.lastRunToken == run.token, [.cancelled, .failed, .needsAttention].contains(record.state) else {
                throw DurableJobError.staleRevision
            }
            for artifact in artifacts {
                try verifyArtifact(artifact, run: run)
                if unlink(artifact.url.path) != 0 && errno != ENOENT { throw DurableJobError.persistenceFailed }
            }
        }
    }

    /// Request keys are supplied by the UI/routine, never inferred from model text. Reusing one with new inputs fails.
    public func create(kind: DurableJobKind, requestKey: String, conversationID: UUID? = nil, title: String,
                       inputs: [DurableJobInput] = [], payload: Data = Data(), payloadVersion: Int = 1) throws -> DurableJobRecord {
        guard !requestKey.isEmpty, requestKey.utf8.count <= 1024, !requestKey.contains("\0"),
              !title.isEmpty, title.utf8.count <= 4096, payloadVersion > 0,
              payload.count <= 16_777_216, inputs.count <= 1000,
              inputs.allSatisfy({ $0.url.isFileURL && $0.identity.sha256.count == 64 }) else { throw DurableJobError.invalidRequest }
        return try transaction {
            if let existing = try Self.readRows(db, condition: "WHERE request_key=?", arguments: [.text(requestKey)]).first {
                // Bookmarks can differ byte-for-byte for the same input; stable URL + identity define the request.
                let sameInputs = existing.inputs.count == inputs.count && zip(existing.inputs, inputs).allSatisfy {
                    $0.url == $1.url && $0.identity == $1.identity
                }
                guard existing.kind == kind, existing.conversationID == conversationID, sameInputs,
                      existing.payloadVersion == payloadVersion, existing.payload == payload else { throw DurableJobError.requestConflict }
                return existing
            }
            let now = Date()
            let record = DurableJobRecord(version: 1, id: UUID(), kind: kind, requestKey: requestKey,
                conversationID: conversationID, title: title, inputs: inputs, payload: payload, payloadVersion: payloadVersion,
                created: now, updated: now, state: .queued, revision: 0, runToken: nil, resultData: nil, artifacts: [],
                issue: nil, processSession: nil, processID: nil, lastRunToken: nil)
            try db.run("INSERT INTO durable_jobs(id,request_key,state,revision,record) VALUES(?,?,?,?,?)",
                       [.text(record.id.uuidString), .text(requestKey), .text(record.state.rawValue), .int(0), .text(try Self.encode(record))])
            return record
        }
    }

    public func start(id: UUID, expectedRevision: Int) throws -> DurableJobRun {
        try transaction {
            var record = try checked(id, expectedRevision)
            guard record.state == .queued else { throw DurableJobError.invalidTransition }
            record.state = .running; record.runToken = UUID(); record.processSession = session; record.processID = getpid()
            record.lastRunToken = record.runToken
            record.issue = nil; record.updated = Date()
            try Self.write(&record, db: db)
            return .init(jobID: id, token: record.runToken!, revision: record.revision)
        }
    }

    /// Only a still-current running attempt can publish results. Failed persistence never reports completion.
    @discardableResult public func finish(run: DurableJobRun, state: DurableJobState, resultData: Data? = nil,
                                         artifacts: [DurableJobArtifact] = [], issue: String? = nil) throws -> DurableJobRecord {
        guard [.completed, .needsAttention, .failed].contains(state), (resultData?.count ?? 0) <= 16_777_216,
              (issue?.utf8.count ?? 0) <= 4096 else { throw DurableJobError.invalidTransition }
        return try transaction {
            var record = try running(run)
            for artifact in artifacts { try verifyArtifact(artifact, run: run) }
            guard Set(artifacts.map(\.url)).count == artifacts.count else { throw DurableJobError.invalidRequest }
            record.state = state; record.resultData = resultData; record.artifacts = artifacts
            record.issue = issue; record.updated = Date(); record.runToken = nil; record.processSession = nil; record.processID = nil
            try Self.write(&record, db: db)
            return record
        }
    }

    /// Stop also dismisses a completed card. Recorded results remain auditable but are never automatically resurfaced.
    @discardableResult public func cancel(id: UUID, expectedRevision: Int) throws -> DurableJobRecord {
        try transaction {
            var record = try checked(id, expectedRevision)
            if record.state == .cancelled { return record }
            record.state = .cancelled; record.runToken = nil; record.processSession = nil; record.processID = nil
            record.issue = "stopped"; record.updated = Date()
            try Self.write(&record, db: db)
            return record
        }
    }

    /// Stop may arrive while completion is being delivered to the UI. Allow that one adjacent transition,
    /// retaining token provenance; a retried or newer attempt is never cancelled by an old Stop.
    @discardableResult public func cancel(run: DurableJobRun) throws -> DurableJobRecord {
        try transaction {
            var record = try record(id: run.jobID)
            let running = record.state == .running && record.revision == run.revision && record.runToken == run.token
            let justFinished = run.revision >= 0 && run.revision < Int.max && record.revision == run.revision + 1
                && [.completed, .needsAttention, .failed, .cancelled].contains(record.state)
            guard record.lastRunToken == run.token, running || justFinished else { throw DurableJobError.staleRevision }
            if record.state == .cancelled { return record }
            record.state = .cancelled; record.runToken = nil; record.processSession = nil; record.processID = nil
            record.issue = "stopped"; record.updated = Date()
            try Self.write(&record, db: db)
            return record
        }
    }

    /// The UI must explicitly offer this. A restored record is never itself permission to execute again.
    @discardableResult public func retry(id: UUID, expectedRevision: Int) throws -> DurableJobRecord {
        try transaction {
            var record = try checked(id, expectedRevision)
            guard [.needsAttention, .failed, .cancelled].contains(record.state) else { throw DurableJobError.invalidTransition }
            record.state = .queued; record.issue = nil; record.updated = Date()
            try Self.write(&record, db: db)
            return record
        }
    }

    public func artifactDirectory(for run: DurableJobRun) throws -> URL {
        _ = try running(run)
        var directory = baseDirectory
        for component in ["DurableJobs", "Artifacts", run.jobID.uuidString, run.token.uuidString] {
            directory.appendPathComponent(component, isDirectory: true)
            // Check before mkdir as well, so an existing link cannot redirect creation outside the job.
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw DurableJobError.artifactOutsideJob }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch {
                guard (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else { throw error }
            }
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw DurableJobError.artifactOutsideJob }
        }
        return directory
    }

    public func makeArtifact(url: URL, run: DurableJobRun) throws -> DurableJobArtifact {
        _ = try running(run)
        try checkArtifactLocation(url, run: run)
        return .init(url: url.standardizedFileURL, identity: try DurableFileIdentity.capture(url))
    }

    /// Promote a temporary tool result into Application Support before storing a completed result. No existing file is replaced.
    public func retainArtifact(from source: URL, run: DurableJobRun) throws -> DurableJobArtifact {
        let directory = try artifactDirectory(for: run)
        if source.deletingLastPathComponent().standardizedFileURL.path == directory.path { return try makeArtifact(url: source, run: run) }
        let sourceIdentity = try DurableFileIdentity.capture(source)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let artifact = try makeArtifact(url: destination, run: run)
            guard artifact.identity.size == sourceIdentity.size, artifact.identity.sha256 == sourceIdentity.sha256,
                  try DurableFileIdentity.capture(source) == sourceIdentity else { throw DurableJobError.artifactChanged }
            return artifact
        } catch {
            // This exact newly copied path is ours; never remove the source or a pre-existing destination.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Readback is also required when restoring a completed result after a relaunch.
    public func verifiedArtifacts(id: UUID) throws -> [DurableJobArtifact] {
        let record = try record(id: id)
        for artifact in record.artifacts {
            let parent = artifact.url.deletingLastPathComponent()
            guard let token = UUID(uuidString: parent.lastPathComponent) else { throw DurableJobError.artifactOutsideJob }
            try verifyArtifact(artifact, run: .init(jobID: id, token: token, revision: record.revision))
        }
        return record.artifacts
    }

    /// Retired internal copies have the same grace period as temporary results, including drag promises.
    /// Call only after collecting tray and conversation references. Visible completed jobs are never candidates.
    /// The transaction prevents another connection from retrying a cancelled job while its files are examined.
    @discardableResult public func pruneCancelledArtifacts(keeping: [URL], maxAge: TimeInterval = 86_400,
                                                           now: Date = Date()) throws -> Int {
        guard maxAge.isFinite, maxAge >= 86_400, now.timeIntervalSinceReferenceDate.isFinite else { throw DurableJobError.invalidRequest }
        let cutoff = now.addingTimeInterval(-maxAge)
        let kept = keeping.filter(\.isFileURL).map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let root = Self.artifactsDirectory(baseDirectory: baseDirectory)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path else { throw DurableJobError.artifactOutsideJob }
        return try transaction {
            var removed = 0
            for record in try Self.readRows(db) where record.state == .cancelled && record.updated < cutoff {
                let jobDirectory = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
                guard Self.isOwnedDirectory(jobDirectory) else { continue }
                let runs = try FileManager.default.contentsOfDirectory(at: jobDirectory, includingPropertiesForKeys: nil)
                for directory in runs {
                    guard let token = UUID(uuidString: directory.lastPathComponent), Self.isOwnedDirectory(directory) else { continue }
                    let run = DurableJobRun(jobID: record.id, token: token, revision: record.revision)
                    // Directory enumeration may return /private/var while a bookmark resolves to /var.
                    let canonical = directory.standardizedFileURL.resolvingSymlinksInPath().path
                    let protected = kept.contains { $0 == canonical || $0.hasPrefix(canonical + "/") || canonical.hasPrefix($0 + "/") }
                    guard !protected else { continue }
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    var eligible = true
                    for file in files {
                        do {
                            try checkArtifactLocation(file, run: run)
                            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                            guard let modified = attributes[.modificationDate] as? Date, modified < cutoff else { eligible = false; break }
                            if let recorded = record.artifacts.first(where: { $0.url.standardizedFileURL.path == file.standardizedFileURL.path }) {
                                try verifyArtifact(recorded, run: run)
                            }
                        } catch { eligible = false; break }
                    }
                    guard eligible else { continue }
                    for file in files {
                        // unlink cannot recursively delete a directory swapped into a file's place.
                        if unlink(file.path) == 0 { removed += 1 }
                        else if errno != ENOENT { throw DurableJobError.persistenceFailed }
                    }
                    // rmdir is empty-only, including when another actor creates a file after the check.
                    _ = rmdir(directory.path)
                }
                _ = rmdir(jobDirectory.path)
            }
            return removed
        }
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        return true
    }

    private func verifyArtifact(_ artifact: DurableJobArtifact, run: DurableJobRun) throws {
        try checkArtifactLocation(artifact.url, run: run)
        guard try DurableFileIdentity.capture(artifact.url) == artifact.identity else { throw DurableJobError.artifactChanged }
    }

    private func checkArtifactLocation(_ url: URL, run: DurableJobRun) throws {
        let expected = Self.artifactsDirectory(baseDirectory: baseDirectory).appendingPathComponent(run.jobID.uuidString, isDirectory: true)
            .appendingPathComponent(run.token.uuidString, isDirectory: true)
        let clean = url.standardizedFileURL
        guard url.isFileURL, clean.deletingLastPathComponent().path == expected.path,
              clean.path == clean.resolvingSymlinksInPath().standardizedFileURL.path else { throw DurableJobError.artifactOutsideJob }
        let attributes = try FileManager.default.attributesOfItem(atPath: clean.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw DurableJobError.artifactOutsideJob }
    }

    private func checked(_ id: UUID, _ revision: Int) throws -> DurableJobRecord {
        let record = try record(id: id)
        guard record.revision == revision else { throw DurableJobError.staleRevision }
        return record
    }

    private func running(_ run: DurableJobRun) throws -> DurableJobRecord {
        let record = try checked(run.jobID, run.revision)
        guard record.state == .running, record.runToken == run.token, record.processSession == session else {
            throw DurableJobError.staleRevision
        }
        return record
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            try db.exec("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? db.exec("ROLLBACK") } }
            _ = try Self.readRows(db)
            let result = try body()
            try db.exec("COMMIT"); committed = true
            return result
        } catch let error as DurableJobError { throw error }
        catch { throw DurableJobError.persistenceFailed }
    }

    private static func readRows(_ db: SQLiteDB, condition: String = "ORDER BY rowid", arguments: [SQLiteDB.Value] = []) throws -> [DurableJobRecord] {
        try db.query("SELECT id,request_key,state,revision,record FROM durable_jobs " + condition, arguments).map { row in
            guard row.count == 5, let text = row[4].string,
                  let record = try? JSONDecoder().decode(DurableJobRecord.self, from: Data(text.utf8)) else { throw DurableJobError.unreadable }
            guard record.version == 1 else { throw DurableJobError.unsupportedVersion }
            guard row[0].string == record.id.uuidString, row[1].string == record.requestKey,
                  row[2].string == record.state.rawValue, row[3].int == Int64(record.revision), record.revision >= 0,
                  record.payloadVersion > 0, !record.requestKey.isEmpty,
                  record.state == .running
                    ? (record.runToken != nil && record.processSession != nil && (record.processID ?? 0) > 0 && record.lastRunToken == record.runToken)
                    : (record.runToken == nil && record.processSession == nil && record.processID == nil),
                  record.inputs.allSatisfy({ $0.url.isFileURL && $0.identity.size >= 0 && $0.identity.sha256.count == 64 })
            else { throw DurableJobError.unreadable }
            return record
        }
    }

    private static func encode(_ record: DurableJobRecord) throws -> String { String(decoding: try JSONEncoder().encode(record), as: UTF8.self) }

    private static func write(_ record: inout DurableJobRecord, db: SQLiteDB) throws {
        guard record.revision < Int.max else { throw DurableJobError.invalidTransition }
        record.revision += 1
        try db.run("UPDATE durable_jobs SET state=?,revision=?,record=? WHERE id=?",
                   [.text(record.state.rawValue), .int(Int64(record.revision)), .text(try encode(record)), .text(record.id.uuidString)])
    }
}
