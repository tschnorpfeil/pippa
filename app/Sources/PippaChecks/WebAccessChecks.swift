import Foundation
import PippaCore

/// "Look up online" in conversation: WebAccessGate asks before every request, stub fetches only, no network.
func runWebAccessChecks() async {
    let weatherPage = WebSource(id: "", url: URL(string: "https://wetter.example/treis-karden")!, site: "wetter.example",
                                title: "Wetter Treis-Karden", asOf: nil, fetchedAt: Date(),
                                text: "Morgen in Treis-Karden: bewölkt, 9 bis 15 Grad, Regen am Nachmittag.")

    await checkAsync("Look up online: nothing goes out before the click; \"Not now\" → no request") {
        let log = WebLog()
        let asks = AskLog(answer: false)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [weatherPage], log: log), language: "de", approve: asks.approve)
        let reply = await gate.handle(LookupRequest(query: "Wetter morgen Treis-Karden", why: "", kind: .search))
        let fetched = await log.calls
        let shown = asks.seen.map(\.shown)
        return reply.status == .refused && reply.passages.isEmpty && fetched.isEmpty && shown == ["Wetter morgen Treis-Karden"]
    }

    await checkAsync("Look up online: \"Look up\" sends exactly the shown request, once; pages come back with their address") {
        let log = WebLog()
        let asks = AskLog(answer: true)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [weatherPage], log: log), language: "de", approve: asks.approve)
        let reply = await gate.handle(LookupRequest(query: "Wetter morgen Treis-Karden", why: "", kind: .search))
        let fetched = await log.calls
        let made = await gate.requestsMade
        return reply.status == .done && reply.passages.first?.url == "https://wetter.example/treis-karden"
            && reply.passages.allSatisfy { $0.text.utf16.count <= 4000 && $0.id.count <= 8 }
            && fetched == ["search:Wetter morgen Treis-Karden"] && made == 1 && asks.seen.first?.warns == false
    }

    await checkAsync("Look up online: personal data is removed from the shown request and announced") {
        let log = WebLog()
        let asks = AskLog(answer: true)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [weatherPage], log: log), language: "de", approve: asks.approve)
        _ = await gate.handle(LookupRequest(query: "Wetter Treis-Karden anna@example.org 0171 2345678 DE89370400440532013000", why: "", kind: .search))
        let fetched = await log.calls
        let ask = asks.seen.first
        let quoted = await gate.handle(LookupRequest(query: "„Zeile aus dem Brief“", why: "", kind: .search))
        return ask?.shown == "Wetter Treis-Karden" && ask?.redacted == true && fetched == ["search:Wetter Treis-Karden"]
            && quoted.status == .refused && asks.seen.count == 1
    }

    await checkAsync("Look up online (a): pages only from search results of this message or typed by the person") {
        let log = WebLog()
        let asks = AskLog(answer: true)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [weatherPage], log: log), language: "de",
                                 typed: "Lies bitte https://www.example.org/seite durch", approve: asks.approve)
        // Self-built address before any search: not even asked, nothing fetched.
        let invented = await gate.handle(LookupRequest(query: "https://evil.example/?q=Kundennummer", why: "", kind: .page))
        let local = await gate.handle(LookupRequest(query: "file:///etc/passwd", why: "", kind: .page))
        let askedBefore = asks.seen.count
        let typed = await gate.handle(LookupRequest(query: "https://www.example.org/seite", why: "", kind: .page))
        _ = await gate.handle(LookupRequest(query: "Wetter morgen Treis-Karden", why: "", kind: .search))
        let fromResult = await gate.handle(LookupRequest(query: "https://wetter.example/treis-karden#heute", why: "", kind: .page))
        let changed = await gate.handle(LookupRequest(query: "https://wetter.example/treis-karden?ort=Berger", why: "", kind: .page))
        let fetched = await log.calls
        return invented.status == .refused && local.status == .refused && askedBefore == 0
            && typed.status == .done && fromResult.status == .done && changed.status == .refused
            && fetched == ["page:https://www.example.org/seite", "search:Wetter morgen Treis-Karden", "page:https://wetter.example/treis-karden#heute"]
            && asks.seen.map(\.kind) == [.page, .search, .page]
    }

    await checkAsync("Look up online (b): text from the documents is marked and a warning is shown") {
        let asks = AskLog(answer: false)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [], log: WebLog()), language: "de", approve: asks.approve)
        await gate.setReferences(["Sehr geehrte Frau Berger, bitte zahlen Sie den offenen Betrag bis Ende des Monats an die Hausverwaltung."],
                                 fileNames: ["Mahnung_Berger.pdf"])
        _ = await gate.handle(LookupRequest(query: "bitte zahlen Sie den offenen Betrag Frist", why: "", kind: .search))
        _ = await gate.handle(LookupRequest(query: "Mahnung Berger Frist", why: "", kind: .search))
        _ = await gate.handle(LookupRequest(query: "Wetter morgen Treis-Karden", why: "", kind: .search))
        let seen = asks.seen
        return seen.count == 3
            && seen[0].copied == ["bitte zahlen Sie den offenen Betrag"] && seen[0].warns
            && seen[1].copied == ["Berger"] && seen[1].warns
            && seen[2].copied.isEmpty && !seen[2].warns
    }

    await checkAsync("Look up online (c): every request needs its own approval; after the end nothing goes out") {
        let log = WebLog()
        let asks = AskLog(answer: true)
        let gate = WebAccessGate(fetcher: StubWebFetcher(pages: [weatherPage], log: log), language: "de", approve: asks.approve)
        _ = await gate.handle(LookupRequest(query: "Wetter morgen Treis-Karden", why: "", kind: .search))
        // A page from the result asks for another request: another card.
        _ = await gate.handle(LookupRequest(query: "Wetter Cochem", why: "", kind: .search))
        let beforeEnd = asks.seen.count
        await gate.cancel()
        let after = await gate.handle(LookupRequest(query: "Wetter Mayen", why: "", kind: .search))
        let letter = await gate.handle(LookupRequest(query: "Einspruchsfrist Steuerbescheid", why: ""))
        let fetched = await log.calls
        return beforeEnd == 2 && asks.seen.count == 2 && after.status == .failed && letter.status == .failed && fetched.count == 2
    }

    check("Look up online: Thought Line shows \"looking up online\" for the web tools, waiting for the person in between") {
        var line = ThoughtLine()
        let request = UUID(), start = Date()
        line.begin(request, at: start)
        line.apply(.toolStarted(name: "web_search", source: nil), request: request, at: start)
        let looking = line.phase == .lookingUpOnline
        line.apply(.phase(.waitingForPerson), request: request, at: start)
        let waiting = line.phase == .waitingForPerson
        line.apply(.phase(.lookingUpOnline), request: request, at: start)
        let again = line.phase == .lookingUpOnline
        line.apply(.toolEnded(name: "web_search"), request: request, at: start)
        line.apply(.toolStarted(name: "read_web_page", source: nil), request: request, at: start)
        return looking && waiting && again && line.phase == .lookingUpOnline && line.lookedUpOnline
    }
}

private actor WebLog {
    var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

private struct StubWebFetcher: WebFetching {
    let pages: [WebSource]
    let log: WebLog
    func lookup(_ query: String, language: String) async throws -> [WebSource] {
        await log.add("search:" + query)
        return pages
    }
    func page(_ url: URL, language: String) async throws -> WebSource? {
        await log.add("page:" + url.absoluteString)
        var page = pages.first ?? WebSource(id: "", url: url, site: url.host ?? "", title: "Seite", asOf: nil, fetchedAt: Date(),
                                            text: "Inhalt der Seite.")
        page.url = url
        return page
    }
}

/// Remembers every card and always answers with `answer`.
private final class AskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [WebAccessAsk] = []
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
    var seen: [WebAccessAsk] { lock.withLock { asks } }
    var approve: WebAccessApproval {
        { [self] ask in lock.withLock { asks.append(ask) }; return answer }
    }
}
