import Darwin
import Foundation

/// "Undo" for entries of the Pippa guard (runtime/pippa-guard), native in Swift. Same rules as
/// `runtime/pippa-guard/restore.mjs`; the two change only together (checks: guard.test.mjs and PiPivotChecks):
///
/// - `moves` (rename, move, Trash): `to` goes back to `from`, never over anything existing.
/// - `entries` with `existed`: the saved copy comes back (as an APFS clone); whatever stands there now goes
///   to the Trash first.
/// - `entries` without `existed` (Pi created the file): never delete, move to the Trash instead.
/// - Trash: `FileManager.trashItem`, for tests `PIPPA_TRASH_DIR` (flat, on a name clash "2 Name" …), like
///   restore.mjs.
/// - `folders` (plain `mkdir`): every new top-level folder goes to the Trash as long as it holds nothing
///   except the new folders from `created` (and `.DS_Store`); otherwise it stays (`notEmpty`).
/// - `restorable: false` (bash log): nothing to restore.
/// - `createdItem` (event or reminder from Pippa's MCP server, PippaMCPWrite.swift): `restoreCreated` removes
///   the entry via `AppIntegrations.remove`, only if unchanged since creation (fingerprint); otherwise
///   it stays (`changed`). restore.mjs cannot do this (no EventKit) and says so.
/// - If everything went well, `restored.json` is left in the entry folder; a second click changes nothing.
///
/// Only entries under `root` (Pippa's undo folder) are touched: the path comes from the history, and a
/// stray entry must not move files elsewhere.
public enum PiUndo {
    public enum Status: String, Sendable, Equatable {
        /// Everything restored.
        case restored
        /// At least one part failed (gone, spot taken); the rest is restored.
        case partial
        /// bash log without backup.
        case notRestorable
        /// Already restored once (`restored.json`).
        case alreadyRestored
        /// No readable manifest.json.
        case missing
        /// Not in Pippa's undo folder.
        case outsideRoot
    }

    public struct Failure: Sendable, Equatable {
        /// "gone" (`to` is gone), "occupied" (`from` taken again), "notEmpty" (new folder has content), "error"
        public var reason: String
        public var path: String
    }

    public struct Result: Sendable, Equatable {
        public var status: Status
        public var failures: [Failure] = []
        /// Lines like restore.mjs, for log and debugging.
        public var log: [String] = []
    }

    struct Manifest: Decodable {
        struct Entry: Decodable { var path: String; var existed: Bool; var snapshot: String? }
        struct Move: Decodable { var from: String; var to: String }
        var tool: String?
        var entries: [Entry]?
        var moves: [Move]?
        /// mkdir: top-level new folders and all new ones (including in-between ones with `-p`).
        var folders: [String]?
        var created: [String]?
        var restorable: Bool?
        var command: String?
    }

    /// Entry cleaned up by the guard (older than 7 days or over 500 MB, runtime/pippa-guard/policy.ts)?
    public static func isPruned(_ entry: URL) -> Bool {
        !FileManager.default.fileExists(atPath: entry.appendingPathComponent("manifest.json").path)
    }

    /// Trash like restore.mjs: `PIPPA_TRASH_DIR` (tests) or the real one. Returns the new location.
    public static func defaultTrash(_ url: URL) throws -> URL? {
        let fm = FileManager.default
        if let fake = ProcessInfo.processInfo.environment["PIPPA_TRASH_DIR"] {
            let folder = URL(fileURLWithPath: fake, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(n) \(url.lastPathComponent)"); n += 1 }
            try fm.moveItem(at: url, to: target)
            return target
        }
        var result: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public static func isRestored(_ entry: URL) -> Bool {
        FileManager.default.fileExists(atPath: entry.appendingPathComponent("restored.json").path)
    }

    /// Is `entry` inside `root`? (Symlinks resolved so `..` or links can't lead outside.)
    public static func isInside(_ entry: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = entry.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    public static func restore(_ entry: URL, root: URL, trash: (URL) throws -> URL? = defaultTrash) -> Result {
        let fm = FileManager.default
        guard isInside(entry, root: root) else { return Result(status: .outsideRoot) }
        if isRestored(entry) { return Result(status: .alreadyRestored) }
        guard let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return Result(status: .missing) }
        if manifest.restorable == false {
            return Result(status: .notRestorable, log: ["Nicht wiederherstellbar (\(manifest.tool ?? "?")): \(manifest.command ?? "")"])
        }
        var result = Result(status: .restored)
        func present(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        func fail(_ reason: String, _ path: String, _ line: String) {
            result.failures.append(Failure(reason: reason, path: path)); result.log.append(line)
        }
        for move in manifest.moves ?? [] {
            guard present(move.to) else { fail("gone", move.to, "nicht mehr da: \(move.to)"); continue }
            guard !present(move.from) else { fail("occupied", move.from, "schon wieder belegt, nichts überschrieben: \(move.from)"); continue }
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: move.from).deletingLastPathComponent(), withIntermediateDirectories: true)
                guard Darwin.rename(move.to, move.from) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                result.log.append("zurückgeholt: \(move.to) → \(move.from)")
            } catch { fail("error", move.from, "\(move.from): \(error.localizedDescription)") }
        }
        for folder in manifest.folders ?? [] {
            guard present(folder) else { result.log.append("schon weg: \(folder)"); continue }
            guard stillEmpty(folder, created: Set(manifest.created ?? [folder])) else {
                fail("notEmpty", folder, "nicht leer, bleibt: \(folder)"); continue
            }
            do {
                let moved = try trash(URL(fileURLWithPath: folder, isDirectory: true))
                result.log.append("neu angelegter Ordner in den Papierkorb: \(folder) → \(moved?.path ?? "Papierkorb")")
            } catch { fail("error", folder, "\(folder): \(error.localizedDescription)") }
        }
        for item in manifest.entries ?? [] {
            let url = URL(fileURLWithPath: item.path)
            do {
                if item.existed {
                    guard let snapshot = item.snapshot, present(snapshot) else { fail("gone", item.snapshot ?? item.path, "Sicherung fehlt: \(item.path)"); continue }
                    if present(item.path) {
                        let moved = try trash(url)
                        result.log.append("jetziger Stand in den Papierkorb: \(item.path) → \(moved?.path ?? "Papierkorb")")
                    }
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copy(snapshot, item.path)
                    result.log.append("zurückgespielt: \(item.path)")
                } else {
                    guard present(item.path) else { result.log.append("schon weg: \(item.path)"); continue }
                    let moved = try trash(url)
                    result.log.append("neu angelegte Datei in den Papierkorb: \(item.path) → \(moved?.path ?? "Papierkorb")")
                }
            } catch { fail("error", item.path, "\(item.path): \(error.localizedDescription)") }
        }
        if !result.failures.isEmpty { result.status = .partial; return result }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? Data("{\"restoredAt\":\"\(stamp)\",\"by\":\"Pippa\"}\n".utf8).write(to: entry.appendingPathComponent("restored.json"))
        return result
    }

    /// Is there nothing in `folder` except folders from `created` (and .DS_Store)? Like `stillEmpty` in restore.mjs.
    static func stillEmpty(_ folder: String, created: Set<String>) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return false }
        for name in names where name != ".DS_Store" {
            let path = (folder as NSString).appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard created.contains(path), fm.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue,
                  stillEmpty(path, created: created) else { return false }
        }
        return true
    }

    /// Like restore.mjs: APFS clone (`clonefile`, like `cp -c`), otherwise an ordinary copy. `destination` does not exist.
    static func copy(_ source: String, _ destination: String) throws {
        if clonefile(source, destination, 0) == 0 { return }
        guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: Events and reminders

    struct CreatedManifest: Decodable { var createdItem: CreatedItem? }

    /// The created entry, if `entry` is such an entry in `root` (otherwise `nil`: then `restore` applies).
    public static func createdItem(_ entry: URL, root: URL) -> CreatedItem? {
        guard isInside(entry, root: root), let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")) else { return nil }
        return (try? JSONDecoder().decode(CreatedManifest.self, from: data))?.createdItem
    }

    /// Removes an event or reminder created by Pippa, only if unchanged since creation.
    /// `remove`: `AppIntegrations.remove` of the same integration that created it. Nothing without a fingerprint (otherwise
    /// "unchanged" could not be checked). Removed → `restored.json`, a second click changes nothing.
    public static func restoreCreated(_ entry: URL, root: URL, remove: @Sendable (CreatedItem) async throws -> RemoveResult) async -> Result {
        guard isInside(entry, root: root) else { return Result(status: .outsideRoot) }
        if isRestored(entry) { return Result(status: .alreadyRestored) }
        guard let item = createdItem(entry, root: root) else { return Result(status: .missing) }
        guard item.fingerprint != nil else { return Result(status: .notRestorable, log: ["ohne Fingerabdruck: \(item.identifier)"]) }
        do {
            switch try await remove(item) {
            case .removed:
                let stamp = ISO8601DateFormatter().string(from: Date())
                try? Data("{\"restoredAt\":\"\(stamp)\",\"by\":\"Pippa\"}\n".utf8).write(to: entry.appendingPathComponent("restored.json"))
                return Result(status: .restored, log: ["entfernt: \(item.integration.rawValue) \(item.identifier)"])
            case .gone:
                return Result(status: .partial, failures: [Failure(reason: "gone", path: item.identifier)], log: ["nicht mehr da: \(item.identifier)"])
            case .changed:
                return Result(status: .partial, failures: [Failure(reason: "changed", path: item.identifier)],
                              log: ["inzwischen geändert, bleibt: \(item.identifier)"])
            }
        } catch {
            return Result(status: .partial, failures: [Failure(reason: "error", path: item.identifier)], log: ["\(item.identifier): \(error)"])
        }
    }

    /// Restore one receipt line: created entries (event, reminder) via `remove`, everything else via `restore`.
    public static func undo(_ item: ActionReceipt.Item, root: URL, trash: @escaping @Sendable (URL) throws -> URL? = defaultTrash,
                            remove: @Sendable (CreatedItem) async throws -> RemoveResult) async -> ActionReceipt.Item {
        guard let entry = item.undoEntry else { return receipt(for: item, Result(status: .missing)) }
        let url = URL(fileURLWithPath: entry, isDirectory: true)
        let result: Result
        if createdItem(url, root: root) != nil {
            result = await restoreCreated(url, root: root, remove: remove)
        } else {
            result = await Task.detached { restore(url, root: root, trash: trash) }.value
        }
        return receipt(for: item, result)
    }

    /// "Undo all": every restorable line of an answer, bottom to top (last change first,
    /// so e.g. files from a new folder are back before the folder is set aside). One line per
    /// result, in that order; what fails appears as its own line and doesn't stop the rest.
    public static func undoAll(_ receipt: ActionReceipt, root: URL, trash: @escaping @Sendable (URL) throws -> URL? = defaultTrash,
                               remove: @Sendable (CreatedItem) async throws -> RemoveResult) async -> [ActionReceipt.Item] {
        var lines: [ActionReceipt.Item] = []
        for item in receipt.undoAllItems { lines.append(await undo(item, root: root, trash: trash, remove: remove)) }
        return lines
    }

    /// The receipt line for restoring. `item`: the original line (action and name).
    public static func receipt(for item: ActionReceipt.Item, _ result: Result) -> ActionReceipt.Item {
        let action = item.action == "create" || item.action == "createFolder" ? "setAside"
            : ActionReceipt.Item.appActions.contains(item.action) ? "remove" : "restore"
        switch result.status {
        case .restored: return ActionReceipt.Item(action: action, outcome: "done", name: item.name)
        case .alreadyRestored: return ActionReceipt.Item(action: action, outcome: "failed", name: item.name, reason: "already")
        case .notRestorable, .missing, .outsideRoot:
            return ActionReceipt.Item(action: action, outcome: "failed", name: item.name, reason: "notRestorable")
        case .partial:
            return ActionReceipt.Item(action: action, outcome: "failed", name: item.name, reason: result.failures.first?.reason ?? "error")
        }
    }
}

/// Pi's session files in Pippa's session folder (`--session-dir`): `<time>_<id>.jsonl`, first line
/// `{"type":"session","id":…,"cwd":…}` (Pi docs, session-format.md).
///
/// Pi finds `--session-id` with its own `--session-dir` only among sessions with the **same working folder**
/// (`SessionManager.findById`, Pi 1.0.4); with another folder it creates a second file with the same id. Pippa
/// therefore pins the working folder to the session: if the session exists, Pi starts in its folder
/// (`pinnedWorkingDirectory`). The session file stays the one source; Pippa needs no table of its own.
public enum PiSessionFiles {
    public struct File: Sendable, Equatable {
        public var url: URL
        public var cwd: String?
        public var modified: Date
    }

    /// All files with this session id, newest first.
    public static func files(id: String, in directory: URL) -> [File] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasSuffix("_\(id).jsonl") }.compactMap { url in
            guard let header = header(url), header["type"] as? String == "session", header["id"] as? String == id else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return File(url: url, cwd: header["cwd"] as? String, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// Working folder of the existing session if it still exists; otherwise `nil` (then the desired folder applies).
    public static func pinnedWorkingDirectory(id: String, in directory: URL) -> URL? {
        var isFolder: ObjCBool = false
        for file in files(id: id, in: directory) {
            if let cwd = file.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: cwd, isDirectory: true)
            }
        }
        return nil
    }

    /// Sets aside all files of these ids (Trash, never delete for good). `trash`: where (checks).
    @discardableResult
    public static func trash(ids: [String], in directory: URL, trash: (URL) throws -> Void) -> [URL] {
        var moved: [URL] = []
        for id in Set(ids) {
            for file in files(id: id, in: directory) {
                do { try trash(file.url); moved.append(file.url) } catch { continue }
            }
        }
        return moved
    }

    /// First line as JSON (read at most 64 KB).
    static func header(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let line = data.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }
}
