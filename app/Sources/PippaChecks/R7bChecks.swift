import Foundation
import PippaCore

// - Tidying in conversation is native (TidyIntent): routing table with counterexamples.
// - Source review against what Pi read (PiReadLedger), not against Pippa's truncated reading state.
// (Short texts on by default: R6Checks.) Runs with PIPPA_R7B_CHECKS=1 and in the full run.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func runR7bChecks() async {
    // MARK: Tidying: routing

    let home = dir("r7b-home")
    let shown = home.appendingPathComponent("Projekt Garten", isDirectory: true)
    let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    let documents = home.appendingPathComponent("Documents", isDirectory: true)
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    // (message, folder shown?, expected folder or nil = goes to Pi)
    let table: [(String, Bool, URL?)] = [
        ("Räum meine Downloads auf", false, downloads),
        ("Räum bitte meinen Schreibtisch auf.", false, desktop),
        ("Kannst du meine Dokumente sortieren?", false, documents),
        ("Downloads aufräumen", false, downloads),
        ("Sortier meinen Downloads-Ordner", false, downloads),
        ("Mach Ordnung in meinen Downloads", false, downloads),
        ("raeum mal meine downloads auf", false, downloads),
        ("Tidy up my Downloads folder", false, downloads),
        ("Please clean up my desktop", false, desktop),
        ("Sort my Documents", false, documents),
        ("Räum hier auf", true, shown),
        ("Aufräumen bitte", true, shown),
        ("Sortier den Ordner", true, shown),
        ("Räum meine Downloads auf", true, shown),            // shown folder wins
        // Counterexamples: Pi reads, explains or does a single step.
        ("Was liegt in Downloads?", false, nil),
        ("Was liegt in meinen Downloads?", true, nil),
        ("Wie räume ich meine Downloads am besten auf?", false, nil),
        ("Soll ich meine Downloads aufräumen?", false, nil),
        ("Hast du die Downloads aufgeräumt?", false, nil),
        ("Wie viel Platz belegen meine Downloads?", false, nil),
        ("What is in my Downloads?", false, nil),
        ("How do I tidy up my desktop?", false, nil),
        ("Sortier die Tabelle nach Datum", true, nil),
        ("Räum meinen Posteingang auf", false, nil),
        ("Räum meinen Kalender auf", false, nil),
        ("Verschieb die Rechnung.pdf in Dokumente", false, nil),
        ("Sortier Rechnung.pdf in Dokumente ein", false, nil),
        ("Ordne die Rechnungen in Dokumente ein", false, nil),
        ("Benenn den Scan in Mietvertrag um", true, nil),
        ("Räum meine Downloads nicht auf", false, nil),
        ("Räum auf", false, nil),
        ("Sortier die Downloads nach Dokumente", false, nil),
        ("Räum Downloads und Schreibtisch auf", false, nil),
        ("Lösch die alten Downloads", false, nil),
        ("Fass meine Termine diese Woche zusammen", false, nil),
        ("Was will der Nachbar?", true, nil),
    ]
    var wrong: [String] = []
    for (text, withShown, expected) in table {
        let intent = TidyIntent.parse(text, shownFolder: withShown ? shown : nil, home: home)
        if intent?.folder.standardizedFileURL != expected?.standardizedFileURL {
            wrong.append("\"\(text)\"\(withShown ? " (+folder)" : ""): \(intent?.folder.lastPathComponent ?? "Pi") instead of \(expected?.lastPathComponent ?? "Pi")")
        }
    }
    check("R7b: tidy routing (\(table.count) cases: \(table.filter { $0.2 != nil }.count) native, \(table.filter { $0.2 == nil }.count) to Pi)") {
        if !wrong.isEmpty { print("    " + wrong.joined(separator: "\n    ")) }
        return wrong.isEmpty
    }
    check("R7b: origin of the folder (shown/named) and everyday folders under the home folder") {
        TidyIntent.parse("Räum hier auf", shownFolder: shown, home: home)?.source == .shownFolder
            && TidyIntent.parse("Räum den Schreibtisch auf", shownFolder: nil, home: home)?.source == .named(.desktop)
            && TidyIntent.folder(for: .documents, home: home).path == home.path + "/Documents"
    }

    // Folders by their own name or path: only existing, ordinary, unique folders under home; everything else to Pi.
    let invoices = documents.appendingPathComponent("Rechnungen", isDirectory: true)
    let english = desktop.appendingPathComponent("Invoices", isDirectory: true)
    let garden = home.appendingPathComponent("Projekt Garten", isDirectory: true)
    let gardenOnly = downloads.appendingPathComponent("Garten", isDirectory: true)
    let twice1 = documents.appendingPathComponent("Steuer", isDirectory: true)
    let twice2 = downloads.appendingPathComponent("Steuer", isDirectory: true)
    for folder in [invoices, english, garden, gardenOnly, twice1, twice2, home.appendingPathComponent("Library/Mail", isDirectory: true),
                   home.appendingPathComponent("Pictures/Urlaub", isDirectory: true), documents.appendingPathComponent(".geheim", isDirectory: true),
                   documents.appendingPathComponent("Fotos.photoslibrary", isDirectory: true)] {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let named: [(String, URL?)] = [
        ("Räum meinen Ordner Rechnungen auf", invoices),
        ("räum den rechnungen-ordner auf", invoices),
        ("Tidy my Invoices folder", english),
        ("Sortier Projekt Garten", garden),                        // the longer name wins over "Garten"
        ("Räum den Ordner Garten auf", gardenOnly),
        ("Räum meinen Ordner Rechnungen in Dokumente auf", invoices),
        ("Räum ~/Documents/Rechnungen auf", invoices),
        ("Räum \"\(garden.path)\" auf", garden),
        // To Pi: ambiguous, unknown, Library, media library, hidden, package, outside home.
        ("Räum meinen Ordner Steuer auf", nil),
        ("Räum meinen Ordner Urlaubsfotos auf", nil),
        ("Räum den Ordner Mail auf", nil),
        ("Räum den Ordner Urlaub auf", nil),
        ("Räum ~/Library/Mail auf", nil),
        ("Räum ~/Pictures/Urlaub auf", nil),
        ("Räum ~/Documents/.geheim auf", nil),
        ("Räum den Ordner Fotos auf", nil),
        ("Räum /System/Library auf", nil),
        ("Räum ~/Documents/Gibtsnicht auf", nil),
        ("Wie räume ich meinen Ordner Rechnungen auf?", nil),
    ]
    var wrongNamed: [String] = []
    for (text, expected) in named {
        let intent = TidyIntent.parse(text, shownFolder: nil, home: home)
        if intent?.folder.standardizedFileURL != expected?.standardizedFileURL || (expected != nil && intent?.source != .found) {
            wrongNamed.append("\"\(text)\": \(intent?.folder.path ?? "Pi") instead of \(expected?.path ?? "Pi")")
        }
    }
    check("R7b: tidy a folder by its own name or path (\(named.count) cases, unique matches only, never Library or hidden)") {
        if !wrongNamed.isEmpty { print("    " + wrongNamed.joined(separator: "\n    ")) }
        return wrongNamed.isEmpty
    }

    check("Tidy preview: \"was: …\" only when the name really changes (extension included)") {
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let same = PlanOp(kind: .move, source: folder.appendingPathComponent("Bild.png"), target: folder.appendingPathComponent("Bilder/Bild.png"), reason: "", certainty: .sure)
        let renamed = PlanOp(kind: .move, source: folder.appendingPathComponent("IMG_1.jpg"), target: folder.appendingPathComponent("Fotos/2024-05-03 Foto 01.jpg"), reason: "", certainty: .sure)
        let ext = PlanOp(kind: .rename, source: folder.appendingPathComponent("Bild.jpeg"), target: folder.appendingPathComponent("Bild.jpg"), reason: "", certainty: .sure)
        return same.previousName == nil && renamed.previousName == "IMG_1.jpg" && ext.previousName == "Bild.jpeg"
    }

    check("Tidy classification: system model first, local model as fallback, recordings alone; time limit leaves the file in place") {
        typealias C = TidyClassifier
        return C.routes(replay: false, appleAvailable: true, localReady: true) == [.apple, .local]
            && C.routes(replay: false, appleAvailable: true, localReady: false) == [.apple]
            && C.routes(replay: false, appleAvailable: false, localReady: true) == [.local]
            && C.routes(replay: true, appleAvailable: true, localReady: false) == [.local]
            && !C.canClassify(replay: false, appleAvailable: false, localReady: false)
            && C.canClassify(replay: false, appleAvailable: true, localReady: false)       // not deferred to "later" when the system model is there
            && C.settle([.declined, .answered]) == .answered
            && C.settle([.timedOut, .declined]) == .timedOut
            && C.settle([.declined]) == .declined && C.settle([]) == .declined
            && C.excerptChars <= 1500 && C.perFileTimeout(.apple) <= .seconds(20) && C.perFileTimeout(.local) <= .seconds(60)
            && C.prompt(name: "a.txt", doc: DocumentText(url: URL(fileURLWithPath: "/tmp/a.txt"), pages: [String(repeating: "x", count: 9000)], isPaged: false, usedOCR: false, headers: [:])).count < 1600
    }

    // MARK: Source review against what Pi actually read

    let ans = dir("r7b-ans1-long")
    let fixtures = (try? JSONSerialization.jsonObject(with: Data(contentsOf: repoRoot.appendingPathComponent("app/Fixtures/p0-answers.json")))) as? [[String: Any]]
    let turn = (fixtures?.first { $0["id"] as? String == "partial-source-hidden-fact" }?["turns"] as? [[String: Any]])?.first
    let sources = (turn?["sources"] as? [[String: Any]]) ?? []
    var files: [URL] = []
    for source in sources {
        guard let path = source["path"] as? String, let text = source["text"] as? String else { continue }
        let url = ans.appendingPathComponent(path)
        write(text, url)
        files.append(url)
    }
    let longText = (sources.first { $0["path"] as? String == "Bestaetigung.txt" }?["text"] as? String) ?? ""
    let answer = "Ja, es gibt eine Abweichung: Das Angebot nennt den 08.12.2026 um 10 Uhr, die Bestätigung den 09.12.2026 um 10 Uhr."
    let question = "Vergleiche die Liefertermine: Gibt es eine Abweichung?"
    let snapshots = (try? await LocalEngine.snapshots(for: ChatContext(files: files))) ?? []
    check("R7b: ANS-1 partial-source: Pippa's own reading state is truncated (starting point)") {
        files.count == 2 && longText.count > 30_000 && snapshots.last?.readStatus == .partial && !(snapshots.last?.text.contains("09.12.2026") ?? true)
    }
    check("R7b: Pi read the long file completely with `read` → no \"only read part\", no marker, answer stays") {
        let old = PiAnswerReview.review(answer: answer, question: question, snapshots: snapshots, fileCount: 2)
        var ledger = PiReadLedger()
        ledger.notePiRead(arguments: json(["path": files[1].path]), result: longText)
        ledger.notePiRead(arguments: json(["path": files[0].path]), result: (try? String(contentsOf: files[0], encoding: .utf8)) ?? "")
        let new = PiAnswerReview.review(answer: answer, question: question, snapshots: snapshots, fileCount: 2, reads: ledger, files: files)
        let oldSaysPart = old?.changed == true && (old?.text.contains("Teil") == true || old?.text.contains("prüfen") == true || old?.text != answer)
        return oldSaysPart && ledger.readCompletely(files[1].path) == true && new?.changed == false && new?.text == answer
    }
    check("R7b: Pi read only the beginning (hint \"Showing lines …\") → stays \"partial\", the review stays strict") {
        var ledger = PiReadLedger()
        let lines = longText.components(separatedBy: "\n")
        let head = lines.prefix(100).joined(separator: "\n")
        ledger.notePiRead(arguments: json(["path": files[1].path]),
                          result: head + "\n\n[Showing lines 1-100 of \(lines.count) (50.0KB limit). Use offset=101 to continue.]")
        let partial = ledger.readCompletely(files[1].path) == false
        let adjusted = ledger.adjusting(snapshots, files: files)
        // Read on to the end: then complete.
        ledger.notePiRead(arguments: json(["path": files[1].path, "offset": 101]), result: lines.dropFirst(100).joined(separator: "\n"))
        return partial && adjusted.last?.readStatus == .partial && !(adjusted.last?.text.contains("[Showing lines") ?? true)
            && ledger.readCompletely(files[1].path) == true
    }
    await checkAsync("R7b: `read_document` over all pages (two calls) → read completely; only the first 12 of 14 pages → partial") {
        let pdf = ans.appendingPathComponent("Vertrag.pdf")
        makePDF((1...14).map { $0 == 14 ? "Seite 14\nKündigungsfrist bis 31.03.2027." : "Seite \($0)\nAllgemeines." }, at: pdf)
        let tools = PippaMCPTurnTools(turns: PippaMCPTurns.shared)
        let first = PippaMCPTurn()
        PippaMCPTurns.shared.begin(first)
        _ = await tools.call("read_document", ["path": pdf.path])
        let half = await first.ledger
        _ = await tools.call("read_document", ["path": pdf.path, "from_page": 13])
        let whole = await first.ledger
        PippaMCPTurns.shared.end(first)
        let own = (try? await LocalEngine.snapshots(for: ChatContext(files: [pdf]))) ?? []
        let review = PiAnswerReview.review(answer: "Die Kündigungsfrist läuft bis 31.03.2027.", question: "Bis wann kann ich kündigen?",
                                           snapshots: own, fileCount: 1, reads: whole, files: [pdf])
        return half.readCompletely(pdf.path) == false && whole.readCompletely(pdf.path) == true
            && whole.adjusting(own, files: [pdf]).last?.text.contains("[S. 14]") == true && review?.changed == false
    }
    check("R7b: files not read by Pi keep Pippa's reading state (e.g. short texts already in the message)") {
        let ledger = PiReadLedger()
        let adjusted = ledger.adjusting(snapshots, files: files)
        return adjusted.map(\.text) == snapshots.map(\.text) && adjusted.map(\.readStatus) == snapshots.map(\.readStatus)
    }
}

private func json(_ value: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self)
}
