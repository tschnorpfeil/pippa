import Foundation

// Web pages and their verification for "Online prüfen". Page content is foreign text: it reaches the core only as
// data, and every fact from the web needs a verbatim quote that the code finds on the fetched page.
// No quote, no fact.

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

/// A verified fact: statement, verbatim quote and the page where the quote stands.
public struct VerifiedWebFact: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var statement: String
    public var quote: String
    public var source: WebSource
    /// Page with text fragment (`#:~:text=`) that jumps to the quote.
    public var link: URL
    public init(id: UUID = UUID(), statement: String, quote: String, source: WebSource, link: URL) {
        self.id = id; self.statement = statement; self.quote = quote; self.source = source; self.link = link
    }
}

public struct WebAnswer: Sendable, Equatable {
    public var facts: [VerifiedWebFact]
    /// Quotes that failed verification (only for the task log, never as a number on screen).
    public var dropped: Int
    /// A calm sentence: nothing confirmed, pages old or sources disagree.
    public var note: String?
    public init(facts: [VerifiedWebFact], dropped: Int, note: String?) {
        self.facts = facts; self.dropped = dropped; self.note = note
    }
}

public enum WebQuotes {
    public static let maxCitations = 6
    public static let quoteLength = 12...400
    public static let statementLength = 1...300
    /// Older than this, a page counts as "more than a year old".
    public static let staleAfter: TimeInterval = 365 * 24 * 3600

    /// Every claim from the core is checked: source known, quote 12–400 characters and verbatim on the page
    /// (GermanText.isVerbatim), statement one line of 1–300 characters whose numbers and time spans all appear in the quote
    /// (Verify.numbersBacked). What fails counts only as `dropped`. At most six claims; anything beyond that too.
    public static func verify(_ citations: [WebCitation], sources: [WebSource], now: Date = Date()) -> WebAnswer {
        var byID: [String: WebSource] = [:]
        for source in sources where byID[source.id] == nil { byID[source.id] = source }
        var facts: [VerifiedWebFact] = []
        var dropped = max(0, citations.count - maxCitations)
        var seen = Set<String>()
        for citation in citations.prefix(maxCitations) {
            guard let fact = verified(citation, byID: byID) else { dropped += 1; continue }
            let key = "\(fact.source.id)\u{1F}\(GermanText.normalize(fact.quote))\u{1F}\(fact.statement)"
            if seen.insert(key).inserted { facts.append(fact) }
        }
        return WebAnswer(facts: facts, dropped: dropped, note: note(for: facts, now: now))
    }

    static func cleanedQuote(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "„“”\"'‚‘’«»")))
    }

    static func verified(_ citation: WebCitation, byID: [String: WebSource]) -> VerifiedWebFact? {
        guard let source = byID[citation.sourceID.trimmingCharacters(in: .whitespaces)] else { return nil }
        let quote = cleanedQuote(citation.quote)
        guard quoteLength.contains(quote.count), GermanText.isVerbatim(quote, in: source.text, minLength: 12) else { return nil }
        let statement = citation.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard statementLength.contains(statement.count) else { return nil }
        guard !statement.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return nil }
        guard Verify.numbersBacked(statement, by: quote) else { return nil }
        return VerifiedWebFact(statement: statement, quote: quote, source: source, link: SourceTile.link(source, quote: quote))
    }

    static func note(for facts: [VerifiedWebFact], now: Date) -> String? {
        if facts.isEmpty { return L("I couldn’t confirm this on the pages I found.", table: "Lookup") }
        if disagree(facts) { return L("The sources don’t quite agree. Please check.", table: "Lookup") }
        let stale = facts.contains { fact in
            guard let asOf = fact.source.asOf, let stand = WebQuotes.date(of: asOf) else { return false }
            return now.timeIntervalSince(stand) > staleAfter
        }
        if stale { return L("Some of these pages are more than a year old. Please check.", table: "Lookup") }
        return nil
    }

    static func date(of day: DayDate) -> Date? {
        var components = DateComponents()
        components.year = day.year; components.month = day.month; components.day = day.day; components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }

    static let digitRuns = try! NSRegularExpression(pattern: #"\d+"#)

    /// Dates (as YYYY-MM-DD), amounts and other numbers of a statement.
    static func figures(_ statement: String) -> Set<String> {
        let dates = GermanText.dates(in: statement)
        let amounts = GermanText.amounts(in: statement)
        var result = Set(dates.map { $0.value.iso })
        for amount in amounts { result.insert("\(amount.value)") }
        var covered = dates.map { NSRange($0.range, in: statement) }
        covered += amounts.map { NSRange($0.range, in: statement) }
        for match in digitRuns.matches(in: statement, range: NSRange(statement.startIndex..., in: statement)) {
            let inside = covered.contains { NSIntersectionRange($0, match.range).length > 0 }
            if !inside, let range = Range(match.range, in: statement) { result.insert(String(statement[range])) }
        }
        return result
    }

    /// Two sources contradict each other if their statements carry numbers or dates and neither set contains the other
    /// ("1 Monat" vs "2 Wochen"; "1 Monat" vs "1 Monat, § 355" is no contradiction, however).
    static func disagree(_ facts: [VerifiedWebFact]) -> Bool {
        let withFigures = facts.map { ($0.source.id, figures($0.statement)) }.filter { !$0.1.isEmpty }
        for (index, first) in withFigures.enumerated() {
            for second in withFigures.dropFirst(index + 1) where second.0 != first.0 {
                let a = first.1, b = second.1
                if !a.isSubset(of: b) && !b.isSubset(of: a) { return true }
            }
        }
        return false
    }
}

/// The tile under a fact: page, title, date.
public enum SourceTile {
    public static let titleLength = 60
    public static let fragmentWords = 8

    /// "gesetze-im-internet.de · § 355 AO · as of 01.01.2026"; without a date "checked …" with the fetch date.
    public static func caption(_ source: WebSource, locale: Locale = .current) -> String {
        var parts = [source.site]
        let title = shortened(source.title, to: titleLength)
        if !title.isEmpty { parts.append(title) }
        if let asOf = source.asOf, let stand = WebQuotes.date(of: asOf) {
            parts.append(L("as of %@", table: "Lookup", day(stand, locale: locale)))
        } else {
            parts.append(L("checked %@", table: "Lookup", day(source.fetchedAt, locale: locale)))
        }
        return parts.joined(separator: " · ")
    }

    /// Day two digits, month two digits, year four digits, in the order of the language (de: 01.01.2026).
    static func day(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return formatter.string(from: date)
    }

    /// Truncated at whole words, with "…".
    static func shortened(_ text: String, to limit: Int) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean }
        var result = ""
        for word in clean.split(separator: " ") {
            var next = result
            if !next.isEmpty { next.append(" ") }
            next.append(contentsOf: word)
            if next.count > limit - 1 { break }
            result = next
        }
        if result.isEmpty { result = String(clean.prefix(limit - 1)) }
        return result + "…"
    }

    /// Only ASCII letters, digits and "._~" stay; everything else (also "-", "&", ",") is encoded,
    /// because it has a meaning in a text fragment.
    static let fragmentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~")

    /// Page with `#:~:text=` and the first (at most eight) words of the quote. An existing fragment is replaced.
    public static func link(_ source: WebSource, quote: String) -> URL {
        let words = WebQuotes.cleanedQuote(quote).split(whereSeparator: \.isWhitespace).prefix(fragmentWords).joined(separator: " ")
        guard !words.isEmpty, let encoded = words.addingPercentEncoding(withAllowedCharacters: fragmentAllowed),
              var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else { return source.url }
        components.fragment = nil
        components.percentEncodedFragment = ":~:text=" + encoded
        return components.url ?? source.url
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
