import Foundation

/// Answers the core's fetch requests during a "Check online" answer.
///
/// Flow per request: check the query in code (QueryGuard) → show the actual query and ask the person (`pendingConfirmation`,
/// `approve`) → separate fetch process (WebFetcher) → excerpts back as `LookupPassage`, which the core sees only as foreign
/// data. The full pages stay here for `verify`: every fact needs a verbatim quote from exactly this page.
///
/// The query itself is never logged; DiagnosticsLog gets only event names and counts.
public actor LookupHost {
    public static let passageLimit = 1200

    private let fetcher: any WebFetching
    private let personal: PersonalTerms
    private let language: String
    private var approved: String?
    private var stored: [WebSource] = []
    private var nextNumber = 1
    private var cancelled = false
    /// Owned separately from the Pi tool request, so stopping the letter also stops its network request.
    private var pendingFetch: Task<[WebSource], Error>?

    /// The sanitized query waiting for the person's click.
    public private(set) var pendingConfirmation: String?
    /// How often a fetch actually happened (not: rejected or waiting for the person).
    public private(set) var lookupsMade = 0

    public init(fetcher: any WebFetching = WebFetcher(), personal: PersonalTerms, language: String = LookupHost.uiLanguage) {
        self.fetcher = fetcher
        self.personal = personal
        self.language = language == "de" ? "de" : "en"
    }

    /// "de" or "en", by the language Pippa is currently speaking.
    public static var uiLanguage: String {
        let preferred = Bundle.module.preferredLocalizations.first ?? "en"
        return preferred.hasPrefix("de") ? "de" : "en"
    }

    /// Is an approved query waiting? Then `handle` takes exactly it, whatever is asked (LetterModel saves
    /// the model call for the query then).
    public var hasApprovedQuery: Bool { approved != nil }

    /// Never throws. Approved query first (exactly once), otherwise QueryGuard decides.
    public func handle(_ request: LookupRequest) async -> LookupReply {
        guard !cancelled, pendingFetch == nil else { return LookupReply(status: .failed, passages: []) }
        let query: String
        if let approved {
            query = approved
            self.approved = nil
        } else {
            switch QueryGuard.check(request.query, personal: personal) {
            case .pass(let cleaned):
                // Pattern matching cannot prove that a free query contains no private words.
                // Until lookups use code-built templates, every free query needs a preview and a click.
                pendingConfirmation = cleaned
                return LookupReply(status: .needsPerson, passages: [])
            case .confirm(let cleaned):
                pendingConfirmation = cleaned
                DiagnosticsLog.shared.event("online-pruefen", ["ergebnis": "rueckfrage"])
                return LookupReply(status: .needsPerson, passages: [])
            case .refuse:
                DiagnosticsLog.shared.event("online-pruefen", ["ergebnis": "abgelehnt"])
                return LookupReply(status: .refused, passages: [])
            }
        }
        pendingConfirmation = nil
        lookupsMade += 1
        let found: [WebSource]
        let fetcher = self.fetcher
        let language = self.language
        let running = Task { try await fetcher.lookup(query, language: language) }
        pendingFetch = running
        defer { pendingFetch = nil }
        do {
            found = try await running.value
        } catch {
            DiagnosticsLog.shared.event("online-pruefen", ["ergebnis": "fehler"])
            return LookupReply(status: .failed, passages: [])
        }
        guard !cancelled else { return LookupReply(status: .failed, passages: []) }
        var passages: [LookupPassage] = []
        // Limits of the core for `lookup_result` (runtime/pi/src/lookup-tools.mjs): otherwise it discards the whole answer.
        for page in found.prefix(6) where page.url.absoluteString.count <= 2000 {
            var source = page
            source.site = Self.bounded(source.site, utf16: 200)
            source.title = Self.bounded(source.title, utf16: 300)
            source.id = "w\(nextNumber)"
            nextNumber += 1
            stored.append(source)
            let excerpt = WebPassages.excerpt(source.text, query: query, limit: Self.passageLimit)
            passages.append(LookupPassage(id: source.id, site: source.site, title: source.title, url: source.url.absoluteString,
                                          asOf: source.asOf?.iso, text: excerpt))
        }
        DiagnosticsLog.shared.event("online-pruefen", ["ergebnis": passages.isEmpty ? "nichts" : "gefunden", "quellen": String(passages.count)])
        return LookupReply(status: .done, passages: passages)
    }

    /// The person approved the sanitized query: the next fetch request takes exactly this one, once, whatever the
    /// core then sends. One line, 2 to QueryGuard.maxLength characters; otherwise everything stays as is.
    public func approve(_ query: String) {
        guard !cancelled else { return }
        let clean = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let breaks = query.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
        guard !breaks, clean.count >= 2, clean.count <= QueryGuard.maxLength,
              clean == pendingConfirmation else { return }
        approved = clean
        pendingConfirmation = nil
    }

    /// Invalidates this lookup permanently. WebFetcher cancels only the owned request id and shuts down its process;
    /// a late cancellation therefore cannot stop a different lookup that has since started.
    public func cancel() {
        cancelled = true
        pendingFetch?.cancel()
        approved = nil
        pendingConfirmation = nil
        stored = []
    }

    /// At most `limit` UTF-16 units (that is how the core counts in JavaScript), shortened to whole characters.
    static func bounded(_ text: String, utf16 limit: Int) -> String {
        var result = text
        while result.utf16.count > limit { result.removeLast() }
        return result
    }

    /// Checks the core's quotes against the complete fetched pages of this answer.
    public func verify(_ citations: [WebCitation]) -> WebAnswer {
        WebQuotes.verify(citations, sources: stored)
    }
}
