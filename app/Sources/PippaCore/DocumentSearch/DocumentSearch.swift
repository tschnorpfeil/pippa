import Foundation

/// Search inside the files and folders the person showed in a conversation: Pippa's full-text index (SearchIndex, FTS5
/// trigram + BM25) plus, if the optional model is installed, EmbeddingGemma 2 vectors over the same sections, combined
/// by reciprocal rank fusion. Measured on app/Fixtures/search-eval (scripts/search-eval.sh): exact numbers stay as good
/// as full text, other wording and English↔German get better.
///
/// - Only what was shown; never the whole Mac, never Mail or other apps.
/// - In memory only, rebuilt when a file changes (size or date), dropped with the app. Removing never touches files.
/// - Hits are pointers, not facts: every hit carries file, page and the original text; a score is no truth value.
public actor DocumentSearch {
    public static let shared = DocumentSearch()

    /// How sections are cut and prefixed; part of the cache key together with the model revision.
    public static let chunkingVersion = "sections-1200/title-text-v1"
    public static let maxFiles = 300
    public static let maxSections = 4000
    public static let pagesPerFile = 30
    /// Reading (with text recognition) stops after this long; what is left counts as skipped.
    public static let readBudget: Duration = .seconds(90)
    static let fusionK = 60.0
    static let readableExtensions: Set<String> = ["pdf", "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "eml", "emlx",
                                                  "xlsx", "xls", "numbers", "csv", "html", "htm"]

    public struct Hit: Sendable, Equatable {
        public var name: String
        public var path: String
        public var page: Int?
        public var text: String
    }

    public struct Skipped: Sendable, Equatable {
        public var name: String
        /// `no_text`, `protected`, `cloud_only`, `damaged`, `limit`, `time`
        public var reason: String
    }

    public enum Mode: String, Sendable { case hybrid, fulltext }

    public struct Result: Sendable {
        public var mode: Mode
        public var hits: [Hit]
        public var files: Int
        public var skipped: [Skipped]
        /// Why only full text: `no_model` (not installed) or `embedding_failed`.
        public var fulltextReason: String?
    }

    struct Stamp: Hashable { var size: Int; var modified: Double }

    final class Entry: @unchecked Sendable {
        let stamps: [String: Stamp]
        let index: SearchIndex
        let passages: [Passage]
        let skipped: [Skipped]
        var revision: String?
        var vectors: [[Float]]?
        init(stamps: [String: Stamp], index: SearchIndex, passages: [Passage], skipped: [Skipped]) {
            self.stamps = stamps; self.index = index; self.passages = passages; self.skipped = skipped
        }
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    /// The files a search over `roots` covers: shown files directly, folders recursively (no hidden files, no packages).
    public nonisolated static func files(in roots: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard readableExtensions.contains(url.pathExtension.lowercased()), seen.insert(path).inserted else { return }
            out.append(url.standardizedFileURL)
        }
        for root in roots {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue { add(root); continue }
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { add(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `roots`: what was shown (checked by the caller). `embedder`: `nil` → full text only.
    public func search(_ query: String, in roots: [URL], embedder: (any TextEmbedding)?, limit: Int = 6,
                       onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        let files = Self.files(in: roots)
        let key = roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\n")
        let stamps = Self.stamps(files)
        let entry: Entry
        if let cached = cache[key], cached.stamps == stamps {
            entry = cached
        } else {
            entry = try await Self.build(files: files, stamps: stamps, onProgress: onProgress)
            cache[key] = entry
            order.removeAll { $0 == key }; order.append(key)
            while order.count > 3 { cache[order.removeFirst()] = nil }
        }
        try Task.checkCancellation()
        let fts = try entry.index.search(query, limit: 20)
        var fulltextReason: String? = embedder == nil ? "no_model" : nil
        var semantic: [Passage] = []
        if let embedder {
            do {
                if entry.revision != embedder.revision || entry.vectors == nil {
                    var vectors: [[Float]] = []
                    for start in stride(from: 0, to: entry.passages.count, by: 16) {
                        try Task.checkCancellation()
                        let slice = entry.passages[start..<min(start + 16, entry.passages.count)]
                        vectors += try await embedder.embed(slice.map { "title: \($0.file.lastPathComponent) | text: \($0.text)" })
                    }
                    entry.vectors = vectors; entry.revision = embedder.revision
                }
                let q = try await embedder.embed(["task: search result | query: \(query)"])[0]
                let vectors = entry.vectors ?? []
                semantic = vectors.indices.map { (i: $0, s: Self.dot(q, vectors[$0])) }.sorted { $0.s > $1.s }.prefix(20).map { entry.passages[$0.i] }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fulltextReason = "embedding_failed"
                DiagnosticsLog.shared.event("dokumentsuche-embedding-fehler")
            }
        }
        let ranked = Self.fuse(fts, semantic)
        let hits = ranked.prefix(limit).map { Hit(name: $0.file.lastPathComponent, path: $0.file.path, page: $0.page, text: $0.text) }
        DiagnosticsLog.shared.event("dokumentsuche", ["art": fulltextReason == nil ? "hybrid" : "volltext", "dateien": String(files.count),
                                                     "abschnitte": String(entry.passages.count), "treffer": String(hits.count)])
        return Result(mode: fulltextReason == nil ? .hybrid : .fulltext, hits: hits, files: files.count, skipped: entry.skipped,
                      fulltextReason: fulltextReason)
    }

    /// Reciprocal rank fusion (k = 60): each list adds 1/(k + rank); ties keep insertion order.
    static func fuse(_ a: [Passage], _ b: [Passage]) -> [Passage] {
        var score: [Int: Double] = [:]
        var byID: [Int: Passage] = [:]
        for list in [a, b] {
            for (rank, p) in list.enumerated() { score[p.id, default: 0] += 1 / (fusionK + Double(rank + 1)); byID[p.id] = p }
        }
        return score.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.compactMap { byID[$0.key] }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    static func stamps(_ files: [URL]) -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[url.path] = Stamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }

    static func build(files: [URL], stamps: [String: Stamp], onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> Entry {
        let index = try SearchIndex()
        var skipped: [Skipped] = []
        let started = ContinuousClock.now
        for (n, url) in files.enumerated() {
            try Task.checkCancellation()
            guard n < maxFiles else { skipped.append(Skipped(name: url.lastPathComponent, reason: "limit")); continue }
            guard ContinuousClock.now - started < readBudget else { skipped.append(Skipped(name: url.lastPathComponent, reason: "time")); continue }
            guard index.count < maxSections else { skipped.append(Skipped(name: url.lastPathComponent, reason: "limit")); continue }
            onProgress?(n + 1, files.count)
            let document = await Task.detached(priority: .userInitiated) {
                TextReader.read(url, options: .init(maxPages: pagesPerFile, ocr: true))
            }.value
            switch document.problem {
            case .none: try index.add(document)
            case .protected: skipped.append(Skipped(name: url.lastPathComponent, reason: "protected"))
            case .cloudOnly: skipped.append(Skipped(name: url.lastPathComponent, reason: "cloud_only"))
            case .damaged: skipped.append(Skipped(name: url.lastPathComponent, reason: "damaged"))
            case .noText, .unsupported: skipped.append(Skipped(name: url.lastPathComponent, reason: "no_text"))
            }
        }
        return Entry(stamps: stamps, index: index, passages: try index.passages(), skipped: skipped)
    }
}
