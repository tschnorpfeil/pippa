import Foundation
import PippaCore

/// Stand-in for EmbeddingGemma 2: one dimension per concept, so a question and a passage with no word in common can still
/// meet (that is what the real model adds; its quality is measured in scripts/search-eval.sh, not here).
private struct ConceptEmbedder: TextEmbedding {
    let revision = "concepts-check"
    static let concepts: [[String]] = [["kaution", "mietsicherheit", "deposit"], ["fahrrad", "rad", "bike"], ["strom", "kwh"], ["urlaub", "frei"]]
    let calls: LockedBox<Int>
    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls.mutate { $0 += texts.count }
        return texts.map { text in
            let lower = text.lowercased()
            var v = Self.concepts.map { words in words.contains { lower.contains($0) } ? Float(1) : 0 } + [0.1]
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 }); v = v.map { $0 / norm }
            return v
        }
    }
}

private struct BrokenEmbedder: TextEmbedding {
    let revision = "broken"
    func embed(_ texts: [String]) async throws -> [[Float]] { throw URLError(.cannotConnectToHost) }
}

func runDocumentSearchChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-docsearch-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Unterlagen", isDirectory: true)
    let elsewhere = root.appendingPathComponent("Anderes", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder.appendingPathComponent("2026"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Synthetic test material only.
    func write(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
    write("Mietvertrag (Testmaterial)\n§ 5 Mietsicherheit: Der Mieter leistet eine Sicherheit von 2.460,00 Euro.", folder.appendingPathComponent("Mietvertrag.txt"))
    write("Stromvertrag (Testmaterial)\nZählernummer 1ESY1160-4471, Arbeitspreis 32,9 Cent.", folder.appendingPathComponent("2026/Strom.txt"))
    write("Geheim (Testmaterial) Kaution 999 Euro", elsewhere.appendingPathComponent("Fremd.txt"))
    write("versteckt Kaution", folder.appendingPathComponent(".versteckt.txt"))
    write("PNG", folder.appendingPathComponent("Bild.png"))

    func call(_ shown: [URL], _ args: [String: Any], embedder: (any TextEmbedding)?, search: DocumentSearch = DocumentSearch()) async -> (json: [String: Any], isError: Bool) {
        let turns = PippaMCPTurns()
        turns.begin(PippaMCPTurn(web: nil, shown: shown))
        let tools = PippaMCPTurnTools(turns: turns, embedder: { embedder }, search: search)
        let result = await tools.call("search_documents", args)
        return ((try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:], result.isError)
    }
    func hits(_ json: [String: Any]) -> [[String: Any]] { (json["data"] as? [String: Any])?["hits"] as? [[String: Any]] ?? [] }
    func data(_ json: [String: Any]) -> [String: Any] { json["data"] as? [String: Any] ?? [:] }

    check("Document search: only readable files in what was shown; hidden files and images left out") {
        let names = DocumentSearch.files(in: [folder]).map(\.lastPathComponent)
        return names == ["Strom.txt", "Mietvertrag.txt"].sorted { folder.appendingPathComponent($0).path < folder.appendingPathComponent($1).path } || Set(names) == ["Strom.txt", "Mietvertrag.txt"]
    }
    await checkAsync("search_documents without the model: full text, exact number found with file and text, says why") {
        let (json, isError) = await call([folder], ["query": "1ESY1160-4471"], embedder: nil)
        let first = hits(json).first
        return !isError && data(json)["mode"] as? String == "fulltext" && data(json)["filesSearched"] as? Int == 2
            && first?["name"] as? String == "Strom.txt" && (first?["text"] as? String)?.contains("1ESY1160-4471") == true
            && json["untrusted"] as? Bool == true && (json["next"] as? String)?.contains("not checked facts") == true
    }
    await checkAsync("search_documents with the model: a word that is not in the text (Kaution → Mietsicherheit) is found; full text alone misses it") {
        let calls = LockedBox(0)
        let (plain, _) = await call([folder], ["query": "Wie hoch ist die Kaution?"], embedder: nil)
        let (json, isError) = await call([folder], ["query": "Wie hoch ist die Kaution?"], embedder: ConceptEmbedder(calls: calls))
        return !isError && hits(plain).isEmpty && data(json)["mode"] as? String == "hybrid"
            && hits(json).first?["name"] as? String == "Mietvertrag.txt" && calls.value == 3
    }
    await checkAsync("search_documents: a path outside what was shown is refused; nothing shown → nothing searched") {
        let (outside, outsideError) = await call([folder], ["query": "Kaution", "path": elsewhere.path], embedder: nil)
        let (sneaky, sneakyError) = await call([folder], ["query": "Kaution", "path": folder.path + "/../Anderes"], embedder: nil)
        let (none, noneError) = await call([], ["query": "Kaution"], embedder: nil)
        let (inside, insideError) = await call([folder], ["query": "Zählernummer", "path": folder.appendingPathComponent("2026").path], embedder: nil)
        return outsideError && outside["status"] as? String == "not_shown" && sneakyError && sneaky["status"] as? String == "not_shown"
            && noneError && none["status"] as? String == "nothing_shown" && !insideError && hits(inside).count == 1
            && !hits(outside).contains { ($0["name"] as? String) == "Fremd.txt" }
    }
    await checkAsync("search_documents: embedding failure falls back to full text and says so; nothing is invented") {
        let (json, isError) = await call([folder], ["query": "Zählernummer"], embedder: BrokenEmbedder())
        let (empty, _) = await call([folder], ["query": "Rentenbescheid"], embedder: nil)
        return !isError && data(json)["mode"] as? String == "fulltext" && hits(json).count == 1
            && hits(empty).isEmpty && (empty["next"] as? String)?.contains("do not guess") == true
    }
    await checkAsync("search_documents: a changed file is searched anew; the index never deletes or changes files") {
        let search = DocumentSearch()
        let calls = LockedBox(0)
        _ = await call([folder], ["query": "Arbeitspreis"], embedder: ConceptEmbedder(calls: calls), search: search)
        let firstCalls = calls.value
        _ = await call([folder], ["query": "Arbeitspreis"], embedder: ConceptEmbedder(calls: calls), search: search)
        let cachedCalls = calls.value - firstCalls
        let strom = folder.appendingPathComponent("2026/Strom.txt")
        write("Stromvertrag (Testmaterial, neu)\nArbeitspreis jetzt 29,9 Cent, Zählernummer 1ESY1160-4471.", strom)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: strom.path)
        let (json, _) = await call([folder], ["query": "Arbeitspreis"], embedder: ConceptEmbedder(calls: calls), search: search)
        let files = DocumentSearch.files(in: [folder]).count
        return cachedCalls == 1 && hits(json).contains { ($0["text"] as? String)?.contains("29,9 Cent") == true } && files == 2
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mietvertrag.txt").path)
    }
    check("search_documents is listed read-only and offline, between read_document and web_search") {
        let list = PippaMCPTurnTools.toolList()
        let names = list.compactMap { $0["name"] as? String }
        let tool = list.first { $0["name"] as? String == "search_documents" }
        let hints = tool?["annotations"] as? [String: Any]
        return names == ["read_document", "search_documents", "web_search", "read_web_page"]
            && hints?["readOnlyHint"] as? Bool == true && hints?["openWorldHint"] as? Bool == false
    }
    check("Source check: what Pi read inside a shown folder counts as partly read, not as \"only the names\"") {
        var ledger = PiReadLedger()
        ledger.noteDocument(path: folder.appendingPathComponent("Mietvertrag.txt").path, text: "Sicherheit von 2.460,00 Euro", firstPage: nil,
                            lastPage: nil, pageCount: nil, cut: true)
        let before = [DocumentSnapshot(name: "Unterlagen", text: "Mietvertrag.txt, 2026", readStatus: .metadataOnly)]
        let after = ledger.adjusting(before, files: [folder])
        let other = ledger.adjusting(before, files: [elsewhere])
        return after.first?.text.contains("2.460,00 Euro") == true && after.first?.readStatus == .partial && other.first?.readStatus == .metadataOnly
    }
    check("Embedding model download is pinned: ggml-org BF16 (no float16), size and SHA256 fixed") {
        let file = EmbeddingServer.model.pinned?.files.first
        return EmbeddingServer.model.repo == "ggml-org/embeddinggemma-2-GGUF" && file?.path.hasSuffix("BF16.gguf") == true
            && file?.size == 557_950_176 && file?.sha256.count == 64 && EmbeddingServer.dimension == 768
    }
}
