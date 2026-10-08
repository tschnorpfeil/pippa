import Foundation

/// A text section with location.
public struct Passage: Sendable, Hashable {
    public var id: Int
    public var file: URL
    public var page: Int?          // 1-based, PDFs only
    public var text: String

    public var location: String? { page.map { "S. \($0)" } }

    public init(id: Int, file: URL, page: Int?, text: String) { self.id = id; self.file = file; self.page = page; self.text = text }
}

/// Full-text search over page sections, SQLite FTS5 with trigram tokenizer (also finds word parts).
public final class SearchIndex: @unchecked Sendable {
    private let db: SQLiteDB
    private let lock = NSLock()
    private var nextID = 1

    public init() throws {
        db = try SQLiteDB(path: ":memory:")
        try db.exec("CREATE VIRTUAL TABLE passages USING fts5(text, file UNINDEXED, page UNINDEXED, tokenize='trigram')")
    }

    /// Adds a document; long pages are split at paragraphs into pieces of about 1,200 characters.
    public func add(_ doc: DocumentText) throws {
        for (i, page) in doc.pages.enumerated() {
            for chunk in Self.chunks(page) {
                try add(file: doc.url, page: doc.isPaged ? i + 1 : nil, text: chunk)
            }
        }
    }

    public func add(file: URL, page: Int?, text: String) throws {
        try lock.withLock {
            try db.run("INSERT INTO passages(rowid, text, file, page) VALUES(?,?,?,?)",
                       [.int(Int64(nextID)), .text(text), .text(file.path), page.map { .int(Int64($0)) } ?? .null])
            nextID += 1
        }
    }

    static func chunks(_ text: String, size: Int = 1200) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        guard clean.count > size else { return [clean] }
        var out: [String] = []
        var current = ""
        for para in clean.components(separatedBy: "\n") {
            if current.count + para.count > size && !current.isEmpty {
                out.append(current); current = ""
            }
            if para.count > size {
                var rest = Substring(para)
                while rest.count > size { out.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + para
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out
    }

    static let stopwords: Set<String> = ["der", "die", "das", "und", "oder", "ist", "sind", "war", "wie", "was", "wer", "wo", "wann", "welche",
        "welcher", "welches", "ein", "eine", "einen", "einem", "einer", "mit", "von", "für", "auf", "aus", "bei", "dem", "den", "des",
        "ich", "mein", "meine", "meinen", "meinem", "meiner", "hat", "habe", "haben", "wird", "werden", "noch", "schon", "lange", "lang",
        "steht", "stand", "denn", "dass", "nicht", "kein", "keine", "zum", "zur", "the", "and", "what", "when", "where", "how", "gibt", "viel", "viele"]

    /// Search terms from a question: words of 3+ characters without filler words; long words additionally as start and end
    /// ("Kündigungsfrist" → "kündi", "frist"), so "gekündigt" and "Frist" are found too.
    public static func terms(for question: String) -> [String] {
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stopwords.contains($0) }
        var out: [String] = []
        for w in words {
            out.append(w)
            if w.count >= 9 { out.append(String(w.prefix(5))); out.append(String(w.suffix(5))) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Best sections for the question (BM25).
    public func search(_ question: String, limit: Int = 8) throws -> [Passage] {
        let terms = Self.terms(for: question)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        return try lock.withLock {
            try db.query("SELECT rowid, text, file, page FROM passages WHERE passages MATCH ? ORDER BY bm25(passages) LIMIT ?",
                         [.text(match), .int(Int64(limit))]).compactMap { r in
                guard let id = r[0].int, let text = r[1].string, let file = r[2].string else { return nil }
                return Passage(id: Int(id), file: URL(fileURLWithPath: file), page: r[3].int.map { Int($0) }, text: text)
            }
        }
    }

    public var count: Int {
        lock.withLock { Int((try? db.query("SELECT COUNT(*) FROM passages").first?.first?.int) ?? 0) }
    }
}
