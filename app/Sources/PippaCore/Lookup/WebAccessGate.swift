import Foundation

// "Online nachsehen" in conversation: Pi does the work (`web_search`, `read_web_page` from Pippa's MCP server, `MCP/PippaMCPTurn.swift`),
// Pippa only guards the boundary. Every single request that would leave the Mac arrives here and goes out only after a
// click by the person on exactly what is sent. Fetching happens in the separate fetch process (WebFetcher).
//
// Rules, in code and not in the prompt:
// (a) Pi may only send search queries; a page only if its address comes from a search result of the same message
//     or the person wrote it themselves. No self-built addresses.
// (b) Before the card: QueryGuard removes obviously personal data (numbers, IBAN, email, phone). Words from the
//     attached documents (four words in a row or a recognized personal term) are marked; then the card warns and its
//     default button is "Nicht jetzt".
// (c) Page text goes to the core as foreign data (`untrusted` in web-tools.mjs). Whatever it requests afterwards needs a
//     separate approval; an approval covers exactly one request.
//
// The request itself is never logged; DiagnosticsLog only gets event names and counts.

/// What the person sees on the card and approves: exactly what would be sent.
public struct WebAccessAsk: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case search, page }
    public let id: UUID
    public var kind: Kind
    /// Exactly this text (search query) or address leaves the Mac after the click.
    public var shown: String
    /// Pieces of `shown` that come from the person's documents (for highlighting). Not empty → warning, default "Nicht jetzt".
    public var copied: [String]
    /// QueryGuard removed obviously personal data.
    public var redacted: Bool
    public var warns: Bool { !copied.isEmpty }
    public init(id: UUID = UUID(), kind: Kind, shown: String, copied: [String], redacted: Bool) {
        self.id = id; self.kind = kind; self.shown = shown; self.copied = copied; self.redacted = redacted
    }
}

/// Asks the person (card in the conversation) and waits for the click. `true` only for "Nachsehen".
public typealias WebAccessApproval = @Sendable (WebAccessAsk) async -> Bool

/// One request of this message and what became of it (Pi RPC path: receipt "Was hinausging", from code, never from
/// the model text). `ask` is `nil` if the request was not even allowed to be asked: then nothing went out.
public struct WebAccessRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable { case done, declined, notAllowed, failed }
    public var kind: WebAccessAsk.Kind
    public var ask: WebAccessAsk?
    public var outcome: Outcome
    public var found: Int
}

public actor WebAccessGate {
    /// Core limits for `lookup_result` (lookup-tools.mjs `lookupResult`): at most 6 sources, text ≤ 4000.
    static let searchTextLimit = 2500
    static let pageTextLimit = 4000
    static let copiedRunWords = 4

    private let fetcher: any WebFetching
    private let language: String
    private let approve: WebAccessApproval
    private var references: [String] = []
    private var personal = PersonalTerms()
    /// Addresses that may be read in this message: from search results and from what the person wrote.
    private var allowedPages: Set<String>
    private var nextNumber = 1
    private var cancelled = false

    /// How often something was actually fetched (after approval); how often asked.
    public private(set) var requestsMade = 0
    public private(set) var asked = 0
    /// Every request of this message in order (exactly the shown text, whether approved, whether anything came back).
    public private(set) var records: [WebAccessRecord] = []
    /// The whole fetched pages of this message (for checking the answer on the Pi RPC path, SourceFidelity).
    public private(set) var pages: [WebSource] = []

    /// `typed`: what the person wrote themselves in this message (addresses named there may be read).
    public init(fetcher: any WebFetching, language: String = LookupHost.uiLanguage, typed: String = "", approve: @escaping WebAccessApproval) {
        self.fetcher = fetcher
        self.language = language == "de" ? "de" : "en"
        self.approve = approve
        self.allowedPages = Set(Self.typedAddresses(in: typed).map(Self.pageKey))
    }

    /// Texts of the attached documents and the context of this message (for the marking in the card).
    public func setReferences(_ texts: [String], fileNames: [String] = []) {
        references = texts.filter { !$0.isEmpty }
        personal = PersonalTerms.from(texts: references, senders: [], fileNames: fileNames, userName: nil)
    }

    public func cancel() { cancelled = true }

    /// Never throws. `refused`: not allowed or "Nicht jetzt" — nothing went out.
    public func handle(_ request: LookupRequest) async -> LookupReply {
        guard !cancelled, request.kind != .lookup else { return LookupReply(status: .failed, passages: []) }
        guard let ask = prepare(request) else {
            DiagnosticsLog.shared.event("online-nachsehen", ["ergebnis": "nicht-erlaubt", "art": request.kind.rawValue])
            records.append(WebAccessRecord(kind: request.kind == .page ? .page : .search, ask: nil, outcome: .notAllowed, found: 0))
            return LookupReply(status: .refused, passages: [])
        }
        asked += 1
        let approved = await approve(ask)
        guard approved, !cancelled else {
            DiagnosticsLog.shared.event("online-nachsehen", ["ergebnis": "nicht-jetzt", "art": ask.kind.rawValue])
            records.append(WebAccessRecord(kind: ask.kind, ask: ask, outcome: .declined, found: 0))
            return LookupReply(status: .refused, passages: [])
        }
        requestsMade += 1
        var found: [WebSource]
        do {
            switch ask.kind {
            case .search: found = try await fetcher.lookup(ask.shown, language: language)
            case .page:
                guard let url = URL(string: ask.shown) else { return LookupReply(status: .failed, passages: []) }
                found = try await fetcher.page(url, language: language).map { [$0] } ?? []
            }
        } catch {
            DiagnosticsLog.shared.event("online-nachsehen", ["ergebnis": "fehler", "art": ask.kind.rawValue])
            records.append(WebAccessRecord(kind: ask.kind, ask: ask, outcome: .failed, found: 0))
            return LookupReply(status: .failed, passages: [])
        }
        guard !cancelled else {
            records.append(WebAccessRecord(kind: ask.kind, ask: ask, outcome: .failed, found: 0))
            return LookupReply(status: .failed, passages: [])
        }
        var passages: [LookupPassage] = []
        for page in found.prefix(6) where page.url.absoluteString.count <= 2000 {
            // (a) Only what this message's search really found may afterwards be read as a page.
            allowedPages.insert(Self.pageKey(page.url.absoluteString))
            pages.append(page)
            let text = ask.kind == .search
                ? WebPassages.excerpt(page.text, query: ask.shown, limit: Self.searchTextLimit)
                : LookupHost.bounded(page.text, utf16: Self.pageTextLimit)
            passages.append(LookupPassage(id: "w\(nextNumber)", site: LookupHost.bounded(page.site, utf16: 200),
                                          title: LookupHost.bounded(page.title, utf16: 300), url: page.url.absoluteString,
                                          asOf: page.asOf?.iso, text: LookupHost.bounded(text, utf16: Self.pageTextLimit)))
            nextNumber += 1
        }
        records.append(WebAccessRecord(kind: ask.kind, ask: ask, outcome: .done, found: passages.count))
        DiagnosticsLog.shared.event("online-nachsehen", ["ergebnis": passages.isEmpty ? "nichts" : "gefunden", "art": ask.kind.rawValue,
                                                       "quellen": String(passages.count)])
        return LookupReply(status: .done, passages: passages)
    }

    /// The card for the request, or `nil` if it may not even be asked.
    func prepare(_ request: LookupRequest) -> WebAccessAsk? {
        switch request.kind {
        case .lookup: return nil
        case .search:
            let shown: String, redacted: Bool
            switch QueryGuard.check(request.query, personal: PersonalTerms()) {
            case .pass(let cleaned): shown = cleaned; redacted = false
            case .confirm(let cleaned): shown = cleaned; redacted = true
            case .refuse: return nil
            }
            return WebAccessAsk(kind: .search, shown: shown, copied: copied(in: shown), redacted: redacted)
        case .page:
            let address = request.query.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false, allowedPages.contains(Self.pageKey(address)) else { return nil }
            return WebAccessAsk(kind: .page, shown: address, copied: copied(in: address.removingPercentEncoding ?? address), redacted: false)
        }
    }

    /// Pieces from the documents: every sequence of at least four words that stands there exactly like that, and every word
    /// that QueryGuard recognizes in the documents as personal (names, places from addresses, file names).
    func copied(in text: String) -> [String] {
        guard !references.isEmpty else { return [] }
        let words = Self.words(text)
        var marked: [String] = []
        let folded = words.map(PersonalTerms.fold)
        if folded.count >= Self.copiedRunWords {
            let haystack = " " + references.map { Self.words($0).map(PersonalTerms.fold).joined(separator: " ") }.joined(separator: " \u{1F} ") + " "
            var start = 0
            while start + Self.copiedRunWords <= folded.count {
                let run = folded[start..<(start + Self.copiedRunWords)].joined(separator: " ")
                if haystack.contains(" " + run + " ") {
                    var end = start + Self.copiedRunWords
                    while end < folded.count, haystack.contains(" " + folded[start...end].joined(separator: " ") + " ") { end += 1 }
                    marked.append(words[start..<end].joined(separator: " "))
                    start = end
                } else { start += 1 }
            }
        }
        for word in words where personal.contains(word) && !marked.contains(where: { $0.localizedCaseInsensitiveContains(word) }) {
            marked.append(word)
        }
        return marked
    }

    static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init).filter { !$0.allSatisfy { $0 == "-" } }
    }

    /// Addresses the person wrote themselves (http/https only).
    static func typedAddresses(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
            return url.absoluteString
        }
    }

    /// Comparison key of an address: without fragment, without trailing "/", host lowercase.
    static func pageKey(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        parts.scheme = parts.scheme?.lowercased()
        var key = parts.string ?? address
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
