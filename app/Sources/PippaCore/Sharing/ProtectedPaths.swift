import Foundation

/// Places no tool the model calls may read or change (issue #196 review): Pippa's own folder (settings and the online
/// AI's Mac access, conversations, Pi sessions of every route, notes, pinned credential folders, backups) and Pi's agent
/// folders (`~/.pi`: auth.json, models.json). Pippa's working folder `pi-work` stays open. The same rules as
/// runtime/pippa-tools/protected.ts, which guards Pi's own tools and the shell; here for the app's MCP tools that take a
/// path (`read_document`, `prepare_files`), and the environment that tells the extensions which places PiSession uses.
///
/// A path counts by the folder it really is in: symlinks are resolved and each folder on the way up is compared by
/// device and inode, so other letter case, `..`, `/private` and the `/System/Volumes/Data` firmlink name the same place.
public struct ProtectedPaths: Sendable, Equatable {
    public var roots: [URL]
    private let work: [WorkEntry]

    private struct WorkEntry: Sendable, Equatable {
        let url: URL
        let id: String?
        let target: String

        init(_ url: URL) {
            self.url = url
            id = ProtectedPaths.directoryEntryID(url.path)
            target = ProtectedPaths.real(url)
        }
    }


    public init(roots: [URL], open: [URL]) {
        self.init(roots: roots, work: open.map(WorkEntry.init))
    }

    private init(roots: [URL], work: [WorkEntry]) {
        self.roots = roots
        self.work = work
    }

    public var open: [URL] { validWork.map(\.url) }

    private var validWork: [WorkEntry] {
        work.filter { entry in
            guard let id = entry.id, Self.directoryEntryID(entry.url.path) == id,
                  Self.directoryEntryID(entry.target) == id else { return false }
            let target = Self.folded(entry.target)
            // The working folder must never contain a protected root.
            guard !roots.contains(where: {
                [$0.standardizedFileURL.path, Self.real($0)].map(Self.folded).contains { root in
                    root == target || root.hasPrefix(target.hasSuffix("/") ? target : target + "/")
                }
            }) else { return false }
            return true
        }
    }

    private static func directoryEntryID(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(UInt32(bitPattern: info.st_dev)):\(info.st_ino)"
    }

    /// The app's places: Pippa's support folder, the real `~/.pi`, Pi's agent folder from the environment (development
    /// and test runs: `PI_CODING_AGENT_DIR`, `PIPPA_PI_HOME`) and `extra` (the agent folder in use, a pinned copy).
    public static func app(support: URL = Pippa.supportDirectory, home: URL = ExistingModels.realHome, extra: [URL] = [],
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let configured = [environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                          environment["PIPPA_PI_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".pi", isDirectory: true) }]
        return Self(roots: [support, home.appendingPathComponent(".pi", isDirectory: true)] + configured.compactMap { $0 } + extra,
                    work: [WorkEntry(PiConversationDefault.workingDirectory(support: support))])
    }

    /// The extensions' environment (protected.ts `PIPPA_PROTECTED_PATHS`, `PIPPA_WORK_DIR`).
    public var environment: [String: String] {
        let list = (try? JSONSerialization.data(withJSONObject: roots.map(\.path))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let id = work.first.flatMap { validWork.contains($0) ? $0.id : nil }
        return ["PIPPA_PROTECTED_PATHS": list, "PIPPA_WORK_DIR": work.first?.url.path ?? "", "PIPPA_WORK_ID": id ?? ""]
    }

    public struct Refused: Error {}

    /// Freeze the effective path first, then authorize that same URL for the operation that opens it.
    public func authorizedURL(_ url: URL) throws -> URL {
        let resolved = URL(fileURLWithPath: Self.real(url)).standardizedFileURL.resolvingSymlinksInPath()
        guard !contains(resolved) else { throw Refused() }
        return resolved
    }

    public func contains(_ url: URL) -> Bool {
        // A hard link has no canonical parent; an open alias cannot establish that the file is outside our folders.
        var targetInfo = stat()
        if stat(Self.real(url), &targetInfo) == 0, targetInfo.st_nlink > 1,
           (targetInfo.st_mode & S_IFMT) == S_IFREG,
           roots.contains(where: { root in
               var info = stat()
               return stat(Self.real(root), &info) == 0 && info.st_dev == targetInfo.st_dev
           }) { return true }
        let identity = { (path: String) -> String? in
            var info = stat()
            return stat(path, &info) == 0 ? "\(UInt32(bitPattern: info.st_dev)):\(info.st_ino)" : nil
        }
        let rootIDs = Set(roots.compactMap { identity(Self.real($0)) }), openIDs = Set(validWork.compactMap(\.id))
        let rootNames = Set(roots.flatMap { [Self.folded($0.standardizedFileURL.path), Self.folded(Self.real($0))] })
        var current = Self.real(url)
        while true {
            let id = identity(current), name = Self.folded(current)
            if let id, rootIDs.contains(id) { return true }
            if rootNames.contains(name) { return true }
            if let id, openIDs.contains(id) { return false }
            let up = (current as NSString).deletingLastPathComponent
            if up == current || up.isEmpty { return false }
            current = up
        }
    }

    /// The real path; the part that does not exist yet is appended as written.
    static func real(_ url: URL) -> String {
        var rest: [String] = []
        var current = url.standardizedFileURL.path
        while true {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                return rest.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let up = (current as NSString).deletingLastPathComponent
            if up == current || up.isEmpty { return url.standardizedFileURL.path }
            rest.append((current as NSString).lastPathComponent)
            current = up
        }
    }

    /// APFS compares names without case and Unicode form.
    static func folded(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// What the model is told, as protected.ts says it.
    public static let reason = "Not done: this path is protected, or the file has multiple hard links and its origin cannot be verified. Pippa keeps her settings, conversations, notes and sign-ins private. No tool may read or change it. Do not try another way; tell the person in one short sentence that Pippa keeps it to herself."
}
