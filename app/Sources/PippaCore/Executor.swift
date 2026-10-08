import Foundation

/// Error with a short German message for the UI.
public enum PippaError: LocalizedError, Sendable, Equatable {
    case scopeMissing
    case outsideScope
    case unknownJob
    /// Undo did not fully succeed: `notRestored` says what was not restored, and why.
    case undoIncomplete(restored: Int, conflicts: Int, notRestored: [FileReason] = [])
    case unsupportedHardware(String)
    case modelUnavailable
    case modelFailed
    /// `why` is for the log only; the UI always shows the same friendly sentence.
    case downloadFailed(String)
    case checksumMismatch
    case serverMissing
    /// Not enough space for the download; `bytes` = how much more must be freed at least.
    case notEnoughSpace(bytes: Int64)
    case writeFailed(String)
    case nothingToExport
    case accessDenied(String)      // app name
    case appNotOpen(String)        // app name
    case entryFailed(String)
    case notAvailable
    /// Aborted after something had already been changed. `receipt` can be undone.
    case partial(receipt: JobReceipt, why: String)

    public var errorDescription: String? {
        switch self {
        case .scopeMissing: L("The folder is no longer there.", table: "Core")
        case .outsideScope: L("That’s outside the folder you shared.", table: "Core")
        case .unknownJob: L("I can’t find this task anymore.", table: "Core")
        case .undoIncomplete(let restored, let conflicts, let list):
            Self.undoText(restored: restored, conflicts: conflicts, first: list.first)
        case .unsupportedHardware(let why): why
        case .modelUnavailable: L("I need my knowledge for this, and it hasn’t loaded yet.", table: "Core")
        case .modelFailed: L("That didn’t work. Nothing was changed. Please try again.", table: "Core")
        case .downloadFailed: L("The download isn’t working right now. I’ll try again shortly.", table: "Core")
        case .checksumMismatch: L("The download arrived damaged. I’ll download it again.", table: "Core")
        case .serverMissing: L("Part of the app is missing. Please reinstall Pippa.", table: "Core")
        case .notEnoughSpace(let bytes):
            L("Your Mac doesn’t have enough free space. I need %@ more for my knowledge. Once you free up some space, I’ll pick up where I left off.", table: "Core", ModelDownloadSize.gigabytes(bytes))
        case .writeFailed(let why): why.isEmpty ? L("I couldn’t create anything.", table: "Core") : L("I couldn’t create anything. %@", table: "Core", why)
        case .nothingToExport: L("There’s nothing for the table.", table: "Core")
        case .accessDenied(let app): L("I don’t have access to %@ yet. You can allow it in System Settings.", table: "Core", app)
        case .appNotOpen(let app): L("%@ isn’t open right now.", table: "Core", app)
        case .entryFailed(let why): why.isEmpty ? L("That couldn’t be added.", table: "Core") : L("That couldn’t be added. %@", table: "Core", why)
        case .notAvailable: L("That isn’t possible here right now. Nothing was changed.", table: "Core")
        case .partial(let receipt, let why): L("Stopped partway through: %@ %@, and that can be undone.", table: "Core", why, receipt.summary)
        }
    }

    /// "2 steps undone, 1 not: <reason>"; without a reason, with a note that something was changed there.
    private static func undoText(restored: Int, conflicts: Int, first: FileReason?) -> String {
        let undone = restored == 1 ? L("1 step was undone", table: "Core") : L("%lld steps were undone", table: "Core", restored)
        let left = conflicts == 1 ? L("1 wasn’t", table: "Core") : L("%lld weren’t", table: "Core", conflicts)
        if let first { return L("%@, %@: %@", table: "Core", undone, left, first.why) }
        return L("%@, %@. Something has changed there in the meantime.", table: "Core", undone, left)
    }

    /// Was anything already changed before the error? Then the UI offers "Undo" (`receipt`).
    public var changedSomething: Bool {
        switch self {
        case .partial: true
        case .undoIncomplete(let restored, _, _): restored > 0
        default: false
        }
    }

    /// The undoable part when aborted midway.
    public var receipt: JobReceipt? {
        if case .partial(let r, _) = self { return r }
        return nil
    }
}

/// System error (errno, Cocoa) as a short German sentence. Never show the system's English text.
public enum SystemError {
    public static func reason(errno code: Int32) -> String {
        switch code {
        case EPERM, EACCES, EROFS: L("I don’t have access to that.", table: "Core")
        case ENOENT: L("The file is no longer there.", table: "Core")
        case EEXIST: L("There’s already a file with that name.", table: "Core")
        case EXDEV: L("It’s on a different drive.", table: "Core")
        case ENOSPC, EDQUOT: L("There’s no space left.", table: "Core")
        default: L("That didn’t work just now.", table: "Core")
        }
    }

    /// For errors from FileManager, Data.write & co.
    public static func reason(_ error: Error) -> String {
        if let p = error as? PippaError { return p.errorDescription ?? L("That didn’t work just now.", table: "Core") }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return reason(errno: Int32(ns.code)) }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            return reason(errno: Int32(under.code))
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return reason(errno: ENOENT)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return reason(errno: EACCES)
            case NSFileWriteFileExistsError: return reason(errno: EEXIST)
            case NSFileWriteOutOfSpaceError: return reason(errno: ENOSPC)
            default: break
            }
        }
        return reason(errno: 0)
    }
}

/// Result of an execution.
public struct ExecutionReport: Sendable {
    public var receipt: JobReceipt
    public var done: [UUID]                       // executed PlanOp IDs
    public var skipped: [(url: URL, why: String)]
    public var createdFolders: [URL]
}

public struct UndoReport: Sendable {
    public var restored: Int
    public var conflicts: [(url: URL, why: String)]
}

/// Executes approved plans. Writes each operation to the journal (SQLite) before running it
/// and marks it done afterwards. Never deletes anything: identical copies go to the Trash, and undo brings them back.
public actor Executor {
    let db: SQLiteDB
    let fm = FileManager.default
    /// Jobs begun before this launch and still running are interrupted.
    private let openedAt = Date().timeIntervalSince1970

    public init(baseDirectory: URL = Pippa.supportDirectory) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: baseDirectory.appendingPathComponent("journal.sqlite").path)
        try db.exec("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, kind TEXT, scope TEXT, summary TEXT, detail TEXT,
                reveal TEXT, state TEXT, plan TEXT, created REAL);
            CREATE TABLE IF NOT EXISTS ops(job TEXT, seq INTEGER, op_id TEXT, kind TEXT, source TEXT, target TEXT,
                state TEXT, fp TEXT, note TEXT, PRIMARY KEY(job, seq));
            """)
        // Older journals: the folder grant (bookmark) is missing; jobs without it continue with the path.
        let columns = try db.query("PRAGMA table_info(jobs)").compactMap { $0.count > 1 ? $0[1].string : nil }
        if !columns.contains("bookmark") { try db.exec("ALTER TABLE jobs ADD COLUMN bookmark TEXT") }
    }

    // MARK: Grants across restarts

    /// From the App Sandbox era: the drop zone and Open dialog granted a folder only until quit. For
    /// undo and resume after a restart, the job remembers the grant (security-scoped bookmark, base64);
    /// without a sandbox this is harmless and keeps old jobs readable.
    static func bookmark(_ url: URL) -> String? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString()
    }

    /// Runs `body` with the job's remembered grant. Without a bookmark (old jobs), just runs it.
    private func withScope<T>(_ job: UUID, _ body: () throws -> T) rethrows -> T {
        var scoped: URL?
        if let text = (try? db.query("SELECT bookmark FROM jobs WHERE id=?", [.text(job.uuidString)]))?.first?.first?.string,
           let data = Data(base64Encoded: text) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                scoped = url
                if stale, let fresh = Self.bookmark(url) {
                    try? db.run("UPDATE jobs SET bookmark=? WHERE id=?", [.text(fresh), .text(job.uuidString)])
                }
            }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        return try body()
    }

    /// For checks only: does the job have a remembered grant?
    public func hasBookmark(jobID: UUID) -> Bool {
        (try? db.query("SELECT bookmark FROM jobs WHERE id=?", [.text(jobID.uuidString)]))?.first?.first?.string != nil
    }

    /// Same file (device and inode, symlinks not resolved)? On a case-sensitive volume,
    /// "a.txt" → "A.txt" is otherwise a different file that a plain `rename` would overwrite.
    public static func isSameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a, &sa) == 0, lstat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    // MARK: Journal

    private func nextSeq(_ job: UUID) throws -> Int64 {
        (try db.query("SELECT COALESCE(MAX(seq), 0) FROM ops WHERE job=?", [.text(job.uuidString)]).first?.first?.int ?? 0) + 1
    }

    @discardableResult
    private func journalStart(_ job: UUID, opID: UUID?, kind: String, source: URL?, target: URL, fp: FileFingerprint?) throws -> Int64 {
        let seq = try nextSeq(job)
        let fpText = fp.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        try db.run("INSERT INTO ops(job, seq, op_id, kind, source, target, state, fp) VALUES(?,?,?,?,?,?,'started',?)",
                   [.text(job.uuidString), .int(seq), opID.map { .text($0.uuidString) } ?? .null, .text(kind),
                    source.map { .text($0.path) } ?? .null, .text(target.path), fpText.map { .text($0) } ?? .null])
        return seq
    }

    private func journalMark(_ job: UUID, _ seq: Int64, _ state: String, note: String? = nil) throws {
        try db.run("UPDATE ops SET state=?, note=COALESCE(?, note) WHERE job=? AND seq=?",
                   [.text(state), note.map { .text($0) } ?? .null, .text(job.uuidString), .int(seq)])
    }

    private func journalSkip(_ job: UUID, op: PlanOp, why: String) throws {
        let seq = try nextSeq(job)
        try db.run("INSERT INTO ops(job, seq, op_id, kind, source, target, state, note) VALUES(?,?,?,?,?,?,'skipped',?)",
                   [.text(job.uuidString), .int(seq), .text(op.id.uuidString), .text(op.kind.rawValue),
                    op.source.map { .text($0.path) } ?? .null, .text(op.target.path), .text(why)])
    }

    private func createJob(_ id: UUID, kind: String, scope: URL, plan: String?) throws {
        try db.run("INSERT INTO jobs(id, kind, scope, state, plan, created, bookmark) VALUES(?,?,?,'running',?,?,?)",
                   [.text(id.uuidString), .text(kind), .text(scope.path), plan.map { .text($0) } ?? .null, .real(Date().timeIntervalSince1970),
                    Self.bookmark(scope).map { .text($0) } ?? .null])
    }

    private func finishJob(_ id: UUID, state: String, summary: String? = nil, detail: String? = nil, reveal: URL? = nil) throws {
        try db.run("UPDATE jobs SET state=?, summary=COALESCE(?, summary), detail=COALESCE(?, detail), reveal=COALESCE(?, reveal) WHERE id=?",
                   [.text(state), summary.map { .text($0) } ?? .null, detail.map { .text($0) } ?? .null,
                    reveal.map { .text($0.path) } ?? .null, .text(id.uuidString)])
    }

    // MARK: Apply

    struct StoredPlan: Codable { var ops: [PlanOp]; var excluded: [UUID] }

    public func apply(_ plan: Plan, excluding: Set<UUID> = []) throws -> ExecutionReport {
        let job = UUID()
        let json = String(decoding: try JSONEncoder().encode(StoredPlan(ops: plan.ops, excluded: Array(excluding))), as: UTF8.self)
        try createJob(job, kind: "sort", scope: plan.scope, plan: json)
        return try run(job: job, scope: plan.scope, ops: Self.selected(plan.ops, excluding: excluding), alreadyDone: [])
    }

    /// Only the selected preview rows. A new folder stays only if a selected file still goes into it:
    /// deselecting all files of a folder also yields no empty folder.
    public static func selected(_ ops: [PlanOp], excluding: Set<UUID>) -> [PlanOp] {
        let moves = ops.filter { $0.kind != .mkdir && !excluding.contains($0.id) }
        let targets = moves.map { $0.target.standardizedFileURL.path }
        return ops.filter { op in
            guard op.kind == .mkdir else { return !excluding.contains(op.id) }
            let folder = op.target.standardizedFileURL.path + "/"
            return !excluding.contains(op.id) && targets.contains { $0.hasPrefix(folder) }
        }
    }

    /// Resumes an interrupted job (after a crash).
    public func resume(jobID: UUID) throws -> ExecutionReport {
        try withScope(jobID) { try resumeScoped(jobID: jobID) }
    }

    private func resumeScoped(jobID: UUID) throws -> ExecutionReport {
        guard let row = try db.query("SELECT scope, plan FROM jobs WHERE id=? AND state='running'", [.text(jobID.uuidString)]).first,
              let scopePath = row[0].string, let planText = row[1].string,
              let stored = try? JSONDecoder().decode(StoredPlan.self, from: Data(planText.utf8)) else { throw PippaError.unknownJob }
        // Begun operations: done if the target exists and the source is gone.
        var doneIDs = Set<UUID>()
        for r in try db.query("SELECT seq, op_id, source, target, state, kind FROM ops WHERE job=?", [.text(jobID.uuidString)]) {
            guard let idText = r[1].string, let id = UUID(uuidString: idText) else { continue }
            let state = r[4].string
            if state == "done" || state == "skipped" { doneIDs.insert(id); continue }
            if state == "started", let target = r[3].string, let seq = r[0].int {
                let srcGone = r[2].string.map { !fm.fileExists(atPath: $0) } ?? true
                if fm.fileExists(atPath: target) && srcGone {
                    try journalMark(jobID, seq, "done"); doneIDs.insert(id)
                } else {
                    try journalMark(jobID, seq, "skipped", note: L("interrupted", table: "Core"))
                }
            }
        }
        return try run(job: jobID, scope: URL(fileURLWithPath: scopePath, isDirectory: true),
                       ops: Self.selected(stored.ops, excluding: Set(stored.excluded)), alreadyDone: doneIDs)
    }

    private func run(job: UUID, scope: URL, ops: [PlanOp], alreadyDone: Set<UUID>) throws -> ExecutionReport {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: scope.path, isDirectory: &isDir), isDir.boolValue else {
            try finishJob(job, state: "failed")
            throw PippaError.scopeMissing
        }
        let guardrail = PathGuard(scope: scope)
        var skipped: [(url: URL, why: String)] = []
        var stayed: [FileReason] = []         // files only, not folders
        var created: [URL] = []
        var done: [UUID] = []
        var taken = Set<String>()
        var targetFolders = Set<String>()
        var trashed = 0
        let mkdirs = ops.filter { $0.kind == .mkdir }.sorted { $0.target.pathComponents.count < $1.target.pathComponents.count }

        func receipt() -> JobReceipt {
            let files = done.count - mkdirs.filter { done.contains($0.id) }.count
            let summary = files == 1 ? L("1 file tidied", table: "Core") : L("%lld files tidied", table: "Core", files)
            return JobReceipt(id: job, summary: summary, detail: Self.detail(folders: targetFolders.count, stayed: stayed.count, trashed: trashed),
                              revealURL: scope, stayed: stayed, date: Date())
        }

        do {
        for op in mkdirs where !alreadyDone.contains(op.id) {
            do {
                created += try ensureDirectory(op.target, job: job, guardrail: guardrail, opID: op.id)
                done.append(op.id)
            } catch {
                skipped.append((op.target, Self.reason(error)))
                try journalSkip(job, op: op, why: Self.reason(error))
            }
        }

        for op in ops where op.kind != .mkdir && !alreadyDone.contains(op.id) {
            guard let source = op.source else { continue }
            func skip(_ why: String) throws {
                skipped.append((source, why)); stayed.append(FileReason(name: source.lastPathComponent, why: why))
                try journalSkip(job, op: op, why: why)
            }

            guard guardrail.contains(source), guardrail.contains(op.target) else { try skip(L("It’s outside the folder, so it stays where it is.", table: "Core")); continue }
            guard let current = FileFingerprint.of(source) else { try skip(L("The file is no longer there.", table: "Core")); continue }
            if let expected = op.fingerprint, !expected.matches(current) {
                try skip(L("It changed since the preview, so it stays where it is.", table: "Core")); continue
            }
            if FileFacts.isCloudPlaceholder(source) { try skip(L("It’s only in the cloud, and I don’t download anything.", table: "Core")); continue }
            if op.kind == .trash {
                // The Trash location is known only afterwards; until then the journal names the file itself.
                let seq = try journalStart(job, opID: op.id, kind: "trash", source: source, target: source, fp: current)
                do {
                    let inTrash = try moveToTrash(source)
                    try db.run("UPDATE ops SET target=? WHERE job=? AND seq=?", [.text(inTrash.path), .text(job.uuidString), .int(seq)])
                    try journalMark(job, seq, "done")
                    done.append(op.id)
                    trashed += 1
                } catch {
                    let why = SystemError.reason(error)
                    try journalMark(job, seq, "failed", note: why)
                    skipped.append((source, why)); stayed.append(FileReason(name: source.lastPathComponent, why: why))
                }
                continue
            }
            let parent = op.target.deletingLastPathComponent()
            do { created += try ensureDirectory(parent, job: job, guardrail: guardrail, opID: nil) }
            catch { try skip(Self.reason(error)); continue }
            guard let parentFP = FileFingerprint.of(parent), parentFP.device == current.device else {
                try skip(L("It’s on a different drive. I can’t move it there yet.", table: "Core")); continue
            }
            var target = op.target
            if target.standardizedFileURL.path == source.standardizedFileURL.path { continue }
            // Only the same file with different capitalization; a different file with this name is a collision.
            let sameFileCaseChange = target.path.lowercased() == source.path.lowercased() && Self.isSameFile(source.path, target.path)
            if !sameFileCaseChange && (fm.fileExists(atPath: target.path) || taken.contains(target.path.lowercased())) {
                target = Naming.unique(target.lastPathComponent, in: parent, taken: &taken)
            } else {
                taken.insert(target.path.lowercased())
            }
            let seq = try journalStart(job, opID: op.id, kind: op.kind.rawValue, source: source, target: target, fp: current)
            let rc = sameFileCaseChange ? rename(source.path, target.path) : renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
            if rc != 0 {
                let why = SystemError.reason(errno: errno)
                try journalMark(job, seq, "failed", note: why)
                skipped.append((source, why)); stayed.append(FileReason(name: source.lastPathComponent, why: why))
                continue
            }
            try journalMark(job, seq, "done")
            done.append(op.id)
            targetFolders.insert(parent.standardizedFileURL.path)
        }
        } catch {
            // Aborted midway (e.g. journal not writable): what already happened stays undoable.
            let r = receipt()
            try? finishJob(job, state: "done", summary: r.summary, detail: r.detail, reveal: scope)
            if done.isEmpty { throw PippaError.writeFailed(SystemError.reason(error)) }
            throw PippaError.partial(receipt: r, why: SystemError.reason(error))
        }

        let r = receipt()
        try finishJob(job, state: "done", summary: r.summary, detail: r.detail, reveal: scope)
        return ExecutionReport(receipt: r, done: done, skipped: skipped, createdFolders: created)
    }

    /// "In 4 folders · 2 in the Trash · 1 stays"; parts with 0 are dropped.
    public static func detail(folders: Int, stayed: Int, trashed: Int = 0) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? L("In 1 folder", table: "Core") : L("In %lld folders", table: "Core", folders)) }
        if trashed > 0 { parts.append(trashed == 1 ? L("1 in the Trash", table: "Core") : L("%lld in the Trash", table: "Core", trashed)) }
        if stayed > 0 { parts.append(stayed == 1 ? L("1 stays put", table: "Core") : L("%lld stay put", table: "Core", stayed)) }
        return parts.isEmpty ? L("Nothing changed", table: "Core") : parts.joined(separator: " · ")
    }

    /// Moves a file to the Trash and returns where it now lies (for undo). Debug builds with `PIPPA_CHECK_TRASH` use that
    /// folder instead, so checks never touch the person's real Trash.
    private func moveToTrash(_ url: URL) throws -> URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["PIPPA_CHECK_TRASH"] {
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken = Set<String>()
            let target = Naming.unique(url.lastPathComponent, in: folder, taken: &taken)
            try fm.moveItem(at: url, to: target)
            return target
        }
        #endif
        var resulting: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    struct GuardError: Error { let why: String }
    static func reason(_ error: Error) -> String { (error as? GuardError)?.why ?? SystemError.reason(error) }

    /// Creates missing folders up to `dir`, each one in the journal. Returns the newly created ones.
    private func ensureDirectory(_ dir: URL, job: UUID, guardrail: PathGuard, opID: UUID?) throws -> [URL] {
        guard guardrail.contains(dir, allowRoot: true) else { throw GuardError(why: L("It’s outside the folder.", table: "Core")) }
        var missing: [URL] = []
        var cursor = dir.standardizedFileURL
        while !fm.fileExists(atPath: cursor.path) {
            missing.insert(cursor, at: 0)
            cursor = cursor.deletingLastPathComponent()
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cursor.path, isDirectory: &isDir), isDir.boolValue else {
            throw GuardError(why: L("There’s a file where the folder should be.", table: "Core"))
        }
        var made: [URL] = []
        for url in missing {
            guard guardrail.contains(url) else { throw GuardError(why: L("It’s outside the folder.", table: "Core")) }
            let seq = try journalStart(job, opID: url == missing.last ? opID : nil, kind: "mkdir", source: nil, target: url, fp: nil)
            if mkdir(url.path, 0o755) != 0 {
                let why = SystemError.reason(errno: errno)
                try journalMark(job, seq, "failed", note: why)
                throw GuardError(why: L("I couldn’t create the folder “%@”. %@", table: "Core", url.lastPathComponent, why))
            }
            try journalMark(job, seq, "done")
            made.append(url)
        }
        return made
    }

    // MARK: New file (export)

    /// Creates a new file (never overwriting) and remembers it for undo.
    public func createFile(_ data: Data, named name: String, in folder: URL, summary: @Sendable (URL) -> String, detail: String) throws -> JobReceipt {
        let job = UUID()
        try createJob(job, kind: "export", scope: folder, plan: nil)
        let tmp = folder.appendingPathComponent(".pippa-\(job.uuidString).tmp")
        do { try data.write(to: tmp, options: .withoutOverwriting) } catch {
            try? fm.removeItem(at: tmp) // only our own, half-written temp file
            try finishJob(job, state: "failed")
            throw PippaError.writeFailed(SystemError.reason(error))
        }
        var taken = Set<String>()
        var target = Naming.unique(name, in: folder, taken: &taken)
        let seq = try journalStart(job, opID: nil, kind: "create", source: nil, target: target, fp: FileFingerprint.of(tmp))
        var attempts = 0
        while renamex_np(tmp.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            attempts += 1
            guard errno == EEXIST, attempts < 20 else {
                let why = SystemError.reason(errno: errno)
                try? fm.removeItem(at: tmp) // only our own temp file
                try journalMark(job, seq, "failed", note: why)
                try finishJob(job, state: "failed")
                throw PippaError.writeFailed(why)
            }
            target = Naming.unique(name, in: folder, taken: &taken)
            try db.run("UPDATE ops SET target=? WHERE job=? AND seq=?", [.text(target.path), .text(job.uuidString), .int(seq)])
        }
        try journalMark(job, seq, "done")
        let text = summary(target)
        try finishJob(job, state: "done", summary: text, detail: detail, reveal: target)
        return JobReceipt(id: job, summary: text, detail: detail, revealURL: target, date: Date())
    }

    // MARK: Tool results (cache)

    /// Remembers already written tool result files (`ResultsFolder`) for undo: a job of kind "result",
    /// one "result" step per file with a fingerprint. Inputs never appear here; they stay as they are.
    public func recordResult(_ files: [URL], summary: String, detail: String) throws -> JobReceipt {
        guard !files.isEmpty else { throw PippaError.writeFailed("") }
        let job = UUID()
        // Without a bookmark: the cache belongs to Pippa and needs no grant across restarts.
        try db.run("INSERT INTO jobs(id, kind, scope, state, created) VALUES(?,?,?,'running',?)",
                   [.text(job.uuidString), .text("result"), .text(ResultsFolder.directory.path), .real(Date().timeIntervalSince1970)])
        for file in files {
            let seq = try journalStart(job, opID: nil, kind: "result", source: nil, target: file, fp: FileFingerprint.of(file))
            try journalMark(job, seq, "done")
        }
        try finishJob(job, state: "done", summary: summary, detail: detail, reveal: files[0])
        return JobReceipt(id: job, summary: summary, detail: detail, revealURL: files[0],
                          undoDetail: L("Removed.", table: "TrayCore"), date: Date())
    }

    /// Undo a result file: in the cache simply remove it (with the empty `Results/<uuid>`), otherwise only move it to the Trash if unchanged.
    /// `true` if the file is gone.
    private func removeResult(_ target: URL, fp: FileFingerprint?) throws -> Bool {
        if ResultsFolder.contains(target) {
            try fm.removeItem(at: target)
            let parent = target.deletingLastPathComponent()
            if parent.standardizedFileURL.path != ResultsFolder.directory.standardizedFileURL.path, ResultsFolder.contains(parent) {
                _ = removeIfEmpty(parent)
            }
            return true
        }
        guard let fp, fp.matches(FileFingerprint.of(target)) else { return false }
        try fm.trashItem(at: target, resultingItemURL: nil)
        return true
    }

    // MARK: Entries in other apps (Reminders, Calendar)

    /// Kinds of jobs that concern entries in other apps rather than files.
    public static let externalKinds: Set<String> = ["reminders", "calendar"]

    /// An entry created by Pippa, from the journal.
    public struct ExternalItem: Sendable {
        public var seq: Int64
        public var item: CreatedItem
    }

    /// Write-ahead: job and step are in the journal before writing to the other app.
    public func beginExternal(_ integration: Integration, label: String) throws -> (job: UUID, seq: Int64) {
        let job = UUID()
        try db.run("INSERT INTO jobs(id, kind, scope, state, plan, created) VALUES(?,?,?,'running',?,?)",
                   [.text(job.uuidString), .text(integration.rawValue), .text(integration.appName), .text(label), .real(Date().timeIntervalSince1970)])
        let seq = try nextSeq(job)
        try db.run("INSERT INTO ops(job, seq, kind, target, state) VALUES(?,?,?,?,'started')",
                   [.text(job.uuidString), .int(seq), .text(integration.rawValue), .text("")])
        return (job, seq)
    }

    /// Entry is created: remember identifier and modification time (for undo).
    public func completeExternal(job: UUID, seq: Int64, item: CreatedItem, summary: String, detail: String) throws -> JobReceipt {
        let fp = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        try db.run("UPDATE ops SET target=?, fp=?, state='done' WHERE job=? AND seq=?",
                   [.text(item.identifier), .text(fp), .text(job.uuidString), .int(seq)])
        try finishJob(job, state: "done", summary: summary, detail: detail)
        return JobReceipt(id: job, summary: summary, detail: detail, revealURL: nil, date: Date())
    }

    public func failExternal(job: UUID, seq: Int64, why: String) throws {
        try journalMark(job, seq, "failed", note: why)
        try finishJob(job, state: "failed")
    }

    /// Created entries of a job, or `nil` if the job concerns files.
    public func externalItems(jobID: UUID) throws -> [ExternalItem]? {
        guard let kind = try db.query("SELECT kind FROM jobs WHERE id=?", [.text(jobID.uuidString)]).first?.first?.string else {
            throw PippaError.unknownJob
        }
        guard Self.externalKinds.contains(kind) else { return nil }
        return try db.query("SELECT seq, fp FROM ops WHERE job=? AND state='done' ORDER BY seq DESC", [.text(jobID.uuidString)]).compactMap { r in
            guard let seq = r[0].int, let text = r[1].string,
                  let item = try? JSONDecoder().decode(CreatedItem.self, from: Data(text.utf8)) else { return nil }
            return ExternalItem(seq: seq, item: item)
        }
    }

    /// Record the result of undo for an entry.
    public func markExternal(job: UUID, seq: Int64, undone: Bool, note: String? = nil) throws {
        try journalMark(job, seq, undone ? "undone" : "done", note: note)
    }

    public func finishExternalUndo(job: UUID, complete: Bool) throws {
        try finishJob(job, state: complete ? "undone" : "partly-undone")
    }

    // MARK: Undo

    /// Reverts a job in reverse order. Overwrites nothing.
    @discardableResult
    public func undo(jobID: UUID) throws -> UndoReport {
        try withScope(jobID) { try undoScoped(jobID: jobID) }
    }

    private func undoScoped(jobID: UUID) throws -> UndoReport {
        guard try db.query("SELECT state FROM jobs WHERE id=?", [.text(jobID.uuidString)]).first?.first?.string != nil else {
            throw PippaError.unknownJob
        }
        let rows = try db.query("SELECT seq, kind, source, target, state, fp FROM ops WHERE job=? AND state IN ('done','started') ORDER BY seq DESC",
                                [.text(jobID.uuidString)])
        var restored = 0
        var conflicts: [(url: URL, why: String)] = []
        var keptFolders: [URL] = []
        for r in rows {
            guard let seq = r[0].int, let kind = r[1].string, let targetPath = r[3].string, let state = r[4].string else { continue }
            let target = URL(fileURLWithPath: targetPath)
            do {
            let fp = r[5].string.flatMap { try? JSONDecoder().decode(FileFingerprint.self, from: Data($0.utf8)) }
            switch kind {
            case "mkdir":
                // Mark as undone only what is really gone; otherwise the step stays open.
                if removeIfEmpty(target) { restored += 1 }
                if fm.fileExists(atPath: target.path) { keptFolders.append(target); continue }
                try journalMark(jobID, seq, "undone")
            case "create":
                guard fm.fileExists(atPath: target.path) else { try journalMark(jobID, seq, "undone"); continue }
                guard let fp, fp.matches(FileFingerprint.of(target)) else {
                    conflicts.append((target, L("The file has changed since then, so it stays.", table: "Core"))); continue
                }
                try fm.trashItem(at: target, resultingItemURL: nil)
                try journalMark(jobID, seq, "undone")
                restored += 1
            case "trash":
                // Back from the Trash to the old place, only unchanged and only if that place is free.
                guard let sourcePath = r[2].string else { continue }
                let source = URL(fileURLWithPath: sourcePath)
                let sourceThere = fm.fileExists(atPath: source.path)
                if state == "started" && sourceThere { try journalMark(jobID, seq, "undone"); continue } // was never executed
                guard target.path != source.path, fm.fileExists(atPath: target.path) else {
                    conflicts.append((source, L("It’s no longer in the Trash.", table: "Core"))); continue
                }
                guard let fp, fp.matches(FileFingerprint.of(target)) else {
                    conflicts.append((target, L("The file has changed since then, so it stays.", table: "Core"))); continue
                }
                guard !sourceThere else { conflicts.append((source, L("Something else is in the old place now.", table: "Core"))); continue }
                try fm.moveItem(at: target, to: source)
                try journalMark(jobID, seq, "undone")
                restored += 1
            case "result":
                guard fm.fileExists(atPath: target.path) else { try journalMark(jobID, seq, "undone"); continue }
                guard try removeResult(target, fp: fp) else {
                    conflicts.append((target, L("The file has changed since then, so it stays.", table: "Core"))); continue
                }
                try journalMark(jobID, seq, "undone")
                restored += 1
            default: // rename, move
                guard let sourcePath = r[2].string else { continue }
                let source = URL(fileURLWithPath: sourcePath)
                let targetThere = fm.fileExists(atPath: target.path)
                let sourceThere = fm.fileExists(atPath: source.path)
                if state == "started" && !(targetThere && !sourceThere) {
                    try journalMark(jobID, seq, "undone"); continue // was never executed
                }
                guard targetThere else { conflicts.append((target, L("The file is no longer there.", table: "Core"))); continue }
                guard let fp, fp.matches(FileFingerprint.of(target)) else {
                    conflicts.append((target, L("The file has changed since then, so it stays.", table: "Core"))); continue
                }
                let caseOnly = source.path.lowercased() == target.path.lowercased() && Self.isSameFile(target.path, source.path)
                guard caseOnly || !sourceThere else { conflicts.append((source, L("Something else is in the old place now.", table: "Core"))); continue }
                let rc = caseOnly ? rename(target.path, source.path) : renamex_np(target.path, source.path, UInt32(RENAME_EXCL))
                guard rc == 0 else { conflicts.append((target, SystemError.reason(errno: errno))); continue }
                try journalMark(jobID, seq, "undone")
                restored += 1
            }
            } catch {
                // A single step fails (Trash, journal): continue with the rest, reason in German.
                conflicts.append((target, SystemError.reason(error)))
            }
        }
        // A folder that stays because something else is in it. If the reason is already in the list, don't name it twice.
        for folder in keptFolders where !conflicts.contains(where: { $0.url.path.hasPrefix(folder.path + "/") || $0.url.path == folder.path }) {
            conflicts.append((folder, L("Something else is in it now, so the folder stays.", table: "Core")))
        }
        try? finishJob(jobID, state: conflicts.isEmpty ? "undone" : "partly-undone")
        return UndoReport(restored: restored, conflicts: conflicts)
    }

    // MARK: History

    /// Completed jobs that can still be undone, newest first.
    /// Old Notes jobs (the integration no longer exists) don't appear: undo is no longer possible there.
    public func recentJobs(limit: Int = 20) -> [JobReceipt] {
        let rows = (try? db.query("""
            SELECT id, kind, summary, detail, reveal, created FROM jobs
            WHERE state IN ('done','partly-undone') AND summary IS NOT NULL AND kind != 'notes' ORDER BY created DESC LIMIT ?
            """, [.int(Int64(max(0, limit)))])) ?? []
        return rows.compactMap { r in
            guard let idText = r[0].string, let id = UUID(uuidString: idText), let kind = r[1].string, let summary = r[2].string else { return nil }
            let integration = Integration(rawValue: kind)
            var receipt = JobReceipt(id: id, summary: summary, detail: r[3].string ?? "", revealURL: r[4].string.map { URL(fileURLWithPath: $0) },
                                     integration: (Self.externalKinds.contains(kind) || kind == "mail") ? integration : nil,
                                     date: r[5].double.map { Date(timeIntervalSince1970: $0) })
            switch integration {
            case .reminders: receipt.undoDetail = L("The reminder is gone again.", table: "Core")
            case .calendar: receipt.undoDetail = L("The event is gone again.", table: "Core")
            default: break
            }
            if kind == "result" { receipt.undoDetail = L("Removed.", table: "TrayCore") }
            if kind == "sort" {
                let left = (try? db.query("SELECT source, note FROM ops WHERE job=? AND state IN ('skipped','failed') AND kind!='mkdir' AND source IS NOT NULL ORDER BY seq",
                                          [.text(idText)])) ?? []
                receipt.stayed = left.compactMap { o in
                    o[0].string.map { FileReason(name: URL(fileURLWithPath: $0).lastPathComponent, why: o[1].string ?? L("That didn’t work just now.", table: "Core")) }
                }
            }
            return receipt
        }
    }

    /// Removes a folder created by Pippa if it is empty (.DS_Store doesn't count).
    private func removeIfEmpty(_ dir: URL) -> Bool {
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        guard items.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        if items.contains(".DS_Store") { unlink(dir.appendingPathComponent(".DS_Store").path) }
        return rmdir(dir.path) == 0
    }

    // MARK: Recovery

    /// Jobs that were begun but not completed.
    public func pendingRecovery() -> [JobReceipt] {
        closeUnrecoverable()
        // Only organize jobs can be resumed; entries in other apps are a single step.
        let rows = (try? db.query("SELECT id, kind, scope FROM jobs WHERE state='running' AND kind='sort' ORDER BY created")) ?? []
        return rows.compactMap { r in
            guard let idText = r[0].string, let id = UUID(uuidString: idText), let scope = r[2].string else { return nil }
            let counts = (try? db.query("SELECT SUM(state='done' AND kind!='mkdir'), COUNT(*) FROM ops WHERE job=?", [.text(idText)]).first) ?? []
            let doneCount = counts.first?.int ?? 0
            let name = URL(fileURLWithPath: scope).lastPathComponent
            let detail = doneCount == 1 ? L("1 file already done", table: "Core") : L("%lld files already done", table: "Core", Int(doneCount))
            return JobReceipt(id: id, summary: L("Interrupted: tidying “%@”", table: "Core", name),
                              detail: detail, revealURL: URL(fileURLWithPath: scope))
        }
    }

    /// Cleanly close interrupted jobs that cannot be resumed (only those from before this launch).
    /// Sheet: remove own temp file `.pippa-<id>.tmp`; if the new file already existed, it stays undoable.
    /// Entries in other apps: without an identifier nothing can be matched, the job counts as aborted.
    private func closeUnrecoverable() {
        let rows = (try? db.query("SELECT id, kind, scope FROM jobs WHERE state='running' AND kind!='sort' AND created<?", [.real(openedAt)])) ?? []
        for r in rows {
            guard let idText = r[0].string, let id = UUID(uuidString: idText), let kind = r[1].string else { continue }
            guard kind == "export", let scope = r[2].string else { try? finishJob(id, state: "abandoned"); continue }
            withScope(id) {
                try? fm.removeItem(at: URL(fileURLWithPath: scope).appendingPathComponent(".pippa-\(idText).tmp")) // only our own temp file
                let op = (try? db.query("SELECT seq, target, fp FROM ops WHERE job=? AND kind='create' AND state='started'", [.text(idText)]))?.first
                if let op, let seq = op[0].int, let path = op[1].string,
                   let fp = op[2].string.flatMap({ try? JSONDecoder().decode(FileFingerprint.self, from: Data($0.utf8)) }),
                   fp.matches(FileFingerprint.of(URL(fileURLWithPath: path))) {
                    let url = URL(fileURLWithPath: path)
                    try? journalMark(id, seq, "done")
                    try? finishJob(id, state: "done", summary: L("New file: %@", table: "Core", url.lastPathComponent), detail: "", reveal: url)
                } else {
                    if let seq = op?[0].int { try? journalMark(id, seq, "failed", note: L("interrupted", table: "Core")) }
                    try? finishJob(id, state: "failed")
                }
            }
        }
    }

    /// Marks an interrupted job as done without changing anything.
    public func dismissRecovery(jobID: UUID) throws {
        try finishJob(jobID, state: "abandoned")
    }

    /// For checks only: raw state of a job's operations.
    public func opStates(jobID: UUID) throws -> [String] {
        try db.query("SELECT state FROM ops WHERE job=? ORDER BY seq", [.text(jobID.uuidString)]).compactMap { $0.first?.string }
    }

    /// For checks only: crash while creating a sheet, after the temp file, before the rename.
    public func simulateExportCrash(in folder: URL, named name: String) throws -> UUID {
        let job = UUID()
        try createJob(job, kind: "export", scope: folder, plan: nil)
        let tmp = folder.appendingPathComponent(".pippa-\(job.uuidString).tmp")
        try Data("halb".utf8).write(to: tmp)
        try journalStart(job, opID: nil, kind: "create", source: nil, target: folder.appendingPathComponent(name), fp: FileFingerprint.of(tmp))
        return job
    }

    /// For checks only: state of a job.
    public func jobState(jobID: UUID) -> String? {
        (try? db.query("SELECT state FROM jobs WHERE id=?", [.text(jobID.uuidString)]))?.first?.first?.string
    }

    /// For checks only: simulates a crash in the middle of an operation.
    public func simulateCrash(scope: URL, source: URL, target: URL) throws -> UUID {
        let job = UUID()
        let op = PlanOp(kind: .move, source: source, target: target, reason: "", certainty: .sure, fingerprint: FileFingerprint.of(source))
        let json = String(decoding: try JSONEncoder().encode(StoredPlan(ops: [op], excluded: [])), as: UTF8.self)
        try createJob(job, kind: "sort", scope: scope, plan: json)
        try journalStart(job, opID: op.id, kind: "move", source: source, target: target, fp: FileFingerprint.of(source))
        return job
    }
}
