import Foundation

// Web pages for Pippa's lookups behind the web card. Page content is foreign text: it reaches the model only as data.

/// A fetched page. `text` is the whole text read (≤ 40,000 characters) for verification; the core sees only an excerpt.
public struct WebSource: Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var site: String
    public var title: String
    public var asOf: DayDate?
    public var fetchedAt: Date
    public var text: String
    public init(id: String, url: URL, site: String, title: String, asOf: DayDate?, fetchedAt: Date, text: String) {
        self.id = id; self.url = url; self.site = site; self.title = title
        self.asOf = asOf; self.fetchedAt = fetchedAt; self.text = text
    }
}

/// Excerpt of a page for the core: the sentences around the best spot for the query, at most `limit` characters.
public enum WebPassages {
    public static func excerpt(_ text: String, query: String, limit: Int = 1200) -> String {
        guard limit > 0 else { return "" }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let sentences = split(flat)
        guard !sentences.isEmpty else { return String(flat.prefix(limit)) }
        let wanted = queryWords(query)
        var best = 0, bestScore = 0
        for (index, sentence) in sentences.enumerated() where !wanted.isEmpty {
            let folded = PersonalTerms.fold(sentence)
            let score = wanted.reduce(0) { $0 + (folded.contains($1) ? 1 : 0) }
            if score > bestScore { best = index; bestScore = score }
        }
        // The best sentence alone is too long: a window around the first matching word.
        if sentences[best].count > limit { return window(sentences[best], around: wanted, limit: limit) }
        var first = best, last = best
        var length = sentences[best].count
        var preferAfter = true
        while true {
            let canAfter = last + 1 < sentences.count && length + 1 + sentences[last + 1].count <= limit
            let canBefore = first > 0 && length + 1 + sentences[first - 1].count <= limit
            if !canAfter && !canBefore { break }
            if (preferAfter && canAfter) || !canBefore {
                last += 1; length += 1 + sentences[last].count
            } else {
                first -= 1; length += 1 + sentences[first].count
            }
            preferAfter.toggle()
        }
        return String(sentences[first...last].joined(separator: " ").prefix(limit))
    }

    /// Words of the query with at least three letters, folded, without stop words.
    static func queryWords(_ query: String) -> [String] {
        let pieces = query.split { !($0.isLetter || $0.isNumber || $0 == "§") }.map { PersonalTerms.fold(String($0)) }
        var seen = Set<String>()
        return pieces.filter { ($0.count >= 3 || $0 == "§") && !PersonalTerms.stopwords.contains($0) && seen.insert($0).inserted }
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?", ":"]

    /// Sentences: end after ".", "!", "?" or ":" followed by a space. Abbreviations split too — when joined
    /// with a space the text stays the same.
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previousEnds = false
        for character in text {
            if previousEnds && character == " " {
                sentences.append(current); current = ""; previousEnds = false; continue
            }
            current.append(character)
            previousEnds = sentenceEnds.contains(character)
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences.filter { !$0.isEmpty }
    }

    static func window(_ sentence: String, around wanted: [String], limit: Int) -> String {
        let folded = PersonalTerms.fold(sentence)
        var offset = 0
        // Folding can change the length (rare); then it stays at the beginning.
        if folded.count == sentence.count,
           let hit = wanted.compactMap({ folded.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            offset = max(0, folded.distance(from: folded.startIndex, to: hit.lowerBound) - limit / 3)
        }
        let start = sentence.index(sentence.startIndex, offsetBy: min(offset, max(0, sentence.count - limit)))
        var piece = String(sentence[start...].prefix(limit))
        // On word boundaries.
        if start != sentence.startIndex, let space = piece.firstIndex(of: " ") { piece = String(piece[piece.index(after: space)...]) }
        if piece.count == limit, let space = piece.lastIndex(of: " ") { piece = String(piece[..<space]) }
        return piece
    }
}
