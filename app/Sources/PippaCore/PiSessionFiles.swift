import Foundation


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
