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
    /// The Mac is under critical memory pressure: the model is not loaded, so the Mac stays usable.
    case notEnoughMemory
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
        case .modelUnavailable: L("I need my AI for this, and it hasn’t loaded yet.", table: "Core")
        case .modelFailed: L("That didn’t work. Nothing was changed. Please try again.", table: "Core")
        case .downloadFailed: L("The download isn’t working right now. I’ll try again shortly.", table: "Core")
        case .checksumMismatch: L("The download arrived damaged. I’ll download it again.", table: "Core")
        case .serverMissing: L("Part of the app is missing. Please reinstall Pippa.", table: "Core")
        case .notEnoughSpace(let bytes):
            L("Your Mac doesn’t have enough free space. I need %@ more for my AI. Once you free up some space, I’ll pick up where I left off.", table: "Core", ModelDownloadSize.gigabytes(bytes))
        case .notEnoughMemory: L("Your Mac is short on memory right now. Close a few apps or browser windows, then try again.", table: "Core")
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

public struct UndoReport: Sendable {
    public var restored: Int
    public var conflicts: [(url: URL, why: String)]
}

/// Executes approved plans. Writes each operation to the journal (SQLite) before running it
/// and marks it done afterwards. Never deletes anything: identical copies go to the Trash, and undo brings them back.
public actor Executor {
    let db: SQLiteDB
    let fm = FileManager.default
    private let supportDirectory: URL
    static let nativeProcessSession = UUID()
    let nativeSessionID: UUID
    /// The run journal's clock (timestamps, pruning after `runRetentionDays`); checks inject one.
    let now: @Sendable () -> Date
    var undoingRuns: Set<UUID> = []
    var inRunTransaction = false

    /// `nativeRecoverySessionID` lets synthetic checks simulate an app restart without creating native items.
    public init(baseDirectory: URL = Pippa.supportDirectory, nativeRecoverySessionID: UUID? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        supportDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        nativeSessionID = nativeRecoverySessionID ?? Self.nativeProcessSession
        self.now = now
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: baseDirectory.appendingPathComponent("journal.sqlite").path)
        try db.exec("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, kind TEXT, scope TEXT, summary TEXT, detail TEXT,
                reveal TEXT, state TEXT, plan TEXT, created REAL);
            CREATE TABLE IF NOT EXISTS ops(job TEXT, seq INTEGER, op_id TEXT, kind TEXT, source TEXT, target TEXT,
                state TEXT, fp TEXT, note TEXT, PRIMARY KEY(job, seq));
            """)
        try db.exec(Self.nativeReminderSchema)
        try db.exec(Self.runActionSchema)
        try Self.pruneRunActions(db, now: now())
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

    private func finishJob(_ id: UUID, state: String, summary: String? = nil, detail: String? = nil, reveal: URL? = nil) throws {
        try db.run("UPDATE jobs SET state=?, summary=COALESCE(?, summary), detail=COALESCE(?, detail), reveal=COALESCE(?, reveal) WHERE id=?",
                   [.text(state), summary.map { .text($0) } ?? .null, detail.map { .text($0) } ?? .null,
                    reveal.map { .text($0.path) } ?? .null, .text(id.uuidString)])
    }

    /// "In 4 folders · 2 in the Trash · 1 stays"; parts with 0 are dropped.
    public static func detail(folders: Int, stayed: Int, trashed: Int = 0) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? L("In 1 folder", table: "Core") : L("In %lld folders", table: "Core", folders)) }
        if trashed > 0 { parts.append(trashed == 1 ? L("1 in the Trash", table: "Core") : L("%lld in the Trash", table: "Core", trashed)) }
        if stayed > 0 { parts.append(stayed == 1 ? L("1 stays put", table: "Core") : L("%lld stay put", table: "Core", stayed)) }
        return parts.isEmpty ? L("Nothing changed", table: "Core") : parts.joined(separator: " · ")
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

    /// Undo of a changed file: the old version comes back; what is there now goes to the Trash (never deleted).
    private func restore(_ target: URL, from copy: URL, fp: FileFingerprint?) throws -> String? {
        guard fm.fileExists(atPath: copy.path) else { return L("The old version is no longer there.", table: "Core") }
        if fm.fileExists(atPath: target.path) {
            guard let fp, fp.matches(FileFingerprint.of(target)) else { return L("The file has changed since then, so it stays.", table: "Core") }
            try RunFileRecipes.moveToTrash(target)
        }
        try fm.copyItem(at: copy, to: target)
        return nil
    }

    /// Expiring cache files keep their original Undo behavior. Durable results must still match the journal
    /// before deletion: opening a retained PDF in another app may have changed it since preparation.
    /// `true` if the file is gone.
    private func removeResult(_ target: URL, fp: FileFingerprint?) throws -> Bool {
        let cache = ResultsFolder.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if target.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(cache) {
            try fm.removeItem(at: target)
            let parent = target.deletingLastPathComponent()
            if parent.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(cache) {
                _ = removeIfEmpty(parent)
            }
            return true
        }
        guard let fp, fp.matches(FileFingerprint.of(target)) else { return false }
        if ResultsFolder.contains(target, durableBaseDirectory: supportDirectory) {
            guard (try fm.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType == .typeRegular else { return false }
            // unlink never recursively removes a directory swapped into the result's place.
            guard unlink(target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            _ = rmdir(target.deletingLastPathComponent().path)
            return true
        }
        try RunFileRecipes.moveToTrash(target)
        return true
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
                try RunFileRecipes.moveToTrash(target)
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
            case "restore":
                guard let sourcePath = r[2].string else { continue }
                if let why = try restore(target, from: URL(fileURLWithPath: sourcePath), fp: fp) { conflicts.append((target, why)); continue }
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

    /// Removes a folder created by Pippa if it is empty (.DS_Store doesn't count).
    private func removeIfEmpty(_ dir: URL) -> Bool {
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        guard items.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        if items.contains(".DS_Store") { unlink(dir.appendingPathComponent(".DS_Store").path) }
        return rmdir(dir.path) == 0
    }

    // MARK: Recovery

}
