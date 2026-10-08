import Foundation

// The tray at the pill ("Tray"): given things and finished results, remembered across restarts.
// Pure and without AppKit: rules as functions over `TrayState`, storage as one JSON file.

/// A thing in the tray: given (the person's file, reference only) or result (Pippa's file in the cache).
public struct TrayItem: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable { case given, result }
    public var id: UUID
    public var role: Role
    public var url: URL
    /// Security-scoped bookmark; nil for Pippa's own copies (Inbox, Results).
    public var bookmark: Data?
    public var name: String
    /// "Downloads", "Mail", "Schreibtisch" – never a path.
    public var origin: String?
    public var addedAt: Date
    public var touchedAt: Date?
    /// Result → job in the journal (undo).
    public var receipt: UUID?
    /// Result → given things that were merged into it (come back on undo).
    public var sources: [UUID]
    /// Result → which tool made it.
    public var tool: ToolID?

    public init(id: UUID = UUID(), role: Role, url: URL, bookmark: Data? = nil, name: String? = nil, origin: String? = nil,
                addedAt: Date = Date(), receipt: UUID? = nil, sources: [UUID] = [], tool: ToolID? = nil) {
        self.id = id; self.role = role; self.url = url; self.bookmark = bookmark
        self.name = name ?? url.lastPathComponent
        self.origin = origin; self.addedAt = addedAt; self.touchedAt = nil
        self.receipt = receipt; self.sources = sources; self.tool = tool
    }

    /// Last added or touched.
    public var lastActive: Date { max(addedAt, touchedAt ?? addedAt) }
}

public struct TrayState: Codable, Sendable, Equatable {
    public var version = 1
    public var items: [TrayItem] = []
    public init(items: [TrayItem] = []) { self.items = items }
}

public enum TrayRules {
    /// Given things not touched for this long silently leave the tray (the file stays where it is).
    public static let fadeAfter: TimeInterval = 24 * 3600
    /// This many cards the pill shows at rest.
    public static let peekCount = 3

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Name of the folder the thing comes from ("Downloads"). Pippa's own tray copies (`inbox`) → nil;
    /// then the caller names the origin ("Mail", "Eingefügt").
    public static func origin(for url: URL, inbox: URL) -> String? {
        let path = key(url)
        let inboxPath = key(inbox)
        if path == inboxPath || path.hasPrefix(inboxPath.hasSuffix("/") ? inboxPath : inboxPath + "/") { return nil }
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let raw = parent.lastPathComponent
        guard !raw.isEmpty, raw != "/" else { return nil }
        let shown = FileManager.default.displayName(atPath: parent.path)
        return shown.isEmpty ? raw : shown
    }

    /// Appends new things at the end in tray order. Already present ones (same path) are not duplicated,
    /// but count as freshly touched.
    public static func adding(_ urls: [URL], origin: String?, to s: TrayState, now: Date, bookmark: (URL) -> Data?) -> TrayState {
        var out = s
        var seen: [String: Int] = [:]
        for (i, item) in out.items.enumerated() { seen[key(item.url)] = i }
        for url in urls {
            let k = key(url)
            if let i = seen[k] {
                out.items[i].touchedAt = now
                continue
            }
            out.items.append(TrayItem(role: .given, url: url, bookmark: bookmark(url), origin: origin, addedAt: now))
            seen[k] = out.items.count - 1
        }
        return out
    }

    /// Missing files drop out; so do given things not touched for longer than `fadeAfter`. Results stay.
    public static func pruned(_ s: TrayState, now: Date, exists: (URL) -> Bool) -> TrayState {
        var out = s
        out.items = s.items.filter { item in
            guard exists(item.url) else { return false }
            if item.role == .result { return true }
            return now.timeIntervalSince(item.lastActive) <= fadeAfter
        }
        return out
    }

    /// Explicit hand-over consumes only that batch; later Give starts with its own sources.
    public static func handedOver(_ ids: [UUID], in state: TrayState) -> TrayState {
        var next = state
        let handed = Set(ids)
        next.items.removeAll { handed.contains($0.id) }
        return next
    }

    /// A tool consumed `ids`: these leave the tray, the result comes to the front.
    public static func consumed(_ ids: [UUID], by result: TrayItem, in s: TrayState) -> TrayState {
        var out = s
        let gone = Set(ids)
        out.items.removeAll { gone.contains($0.id) || $0.id == result.id }
        out.items.insert(result, at: 0)
        return out
    }

    /// Undo: the result goes (with all results of the same job), `restoring` comes back,
    /// unless it is already in the tray.
    public static func undone(_ resultID: UUID, in s: TrayState, restoring: [TrayItem]) -> TrayState {
        var out = s
        let receipt = s.items.first { $0.id == resultID }?.receipt
        out.items.removeAll { item in
            if item.id == resultID { return true }
            if let receipt, item.role == .result, item.receipt == receipt { return true }
            return false
        }
        var ids = Set(out.items.map(\.id))
        var paths = Set(out.items.map { key($0.url) })
        for item in restoring where !ids.contains(item.id) && !paths.contains(key(item.url)) {
            out.items.append(item)
            ids.insert(item.id); paths.insert(key(item.url))
        }
        return out
    }

    /// What the pill shows at rest: results first, newest first each, at most `peekCount`.
    public static func peek(_ s: TrayState) -> [TrayItem] {
        let ordered = s.items.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.role != y.role { return x.role == .result }
            if x.addedAt != y.addedAt { return x.addedAt > y.addedAt }
            return a.offset < b.offset
        }
        return Array(ordered.prefix(peekCount).map(\.element))
    }
}

/// The tray on disk: `<Support>/tray.json`.
public struct TrayStore: Sendable {
    public static let fileName = "tray.json"
    public let directory: URL

    public init(directory: URL = Pippa.supportDirectory) { self.directory = directory }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// If the file is missing or broken: empty tray.
    public func load() -> TrayState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(TrayState.self, from: data) else { return TrayState() }
        return state
    }

    /// Writes atomically (temp file first, then replace).
    public func save(_ s: TrayState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(s)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Security-scoped bookmark for a given file (app sandbox: access across restarts). nil if that fails.
    public static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the bookmark and begins access. `scoped == true`: the caller afterwards calls
    /// `stopAccessingSecurityScopedResource()` on the returned URL. nil if the file is no longer reachable.
    public static func resolve(_ item: TrayItem) -> (url: URL, scoped: Bool)? {
        if let data = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return (url, url.startAccessingSecurityScopedResource())
            }
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return nil }
        return (item.url, false)
    }
}
