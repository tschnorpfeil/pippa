import AppKit
import CoreText
import Foundation
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// Shown items, `read_document`, online lookup receipts and source verification on the Pi RPC path, without a model and
/// without network. Only invented files under the checks folder.
func runR2Checks() async {
    let base = root.appendingPathComponent("r2", isDirectory: true)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let letter = base.appendingPathComponent("brief-finanzamt.pdf")
    makePDF(["Finanzamt Musterstadt\nBescheid über Einkommensteuer 2025\nNachzahlung: 1.234,56 €\nBitte zahlen Sie bis zum 16.11.2026.",
             "Rechtsbehelfsbelehrung\nGegen diesen Bescheid ist der Einspruch zulässig. Frist: ein Monat nach Bekanntgabe."], at: letter)
    let long = base.appendingPathComponent("vertrag-14-seiten.pdf")
    makePDF((1...14).map { "Seite \($0) des Vertrags.\n" + String(repeating: "Textbaustein ohne Bedeutung. ", count: 40) + ($0 == 13 ? "\nKündigungsfrist: drei Monate zum 31.03.2027." : "") }, at: long)
    let folder = base.appendingPathComponent("Unterlagen 2026", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    write("Hallo", folder.appendingPathComponent("a.txt")); write("Welt", folder.appendingPathComponent("b.txt"))
    let mail = base.appendingPathComponent("einladung.eml")
    write("From: Verein Beispiel <info@verein.example>\nSubject: Einladung Sommerfest\nContent-Type: text/plain; charset=utf-8\n\nAm 12.09.2026 um 15 Uhr.", mail)
    let table = base.appendingPathComponent("Nebenkosten.tsv")
    write("A\tB\n1\tHeizung\t812,40", table)
    let photo = base.appendingPathComponent("foto.jpg")
    makeImage(at: photo, type: .jpeg)
    let locked = base.appendingPathComponent("gesperrt.pdf")
    ToolFixtures.lockedPDF(["geheim"], password: "x", at: locked)

    // MARK: Shown items in the message

    check("Shown: without shown items the message is exactly the question") {
        PiShownContext.prompt(.init(question: "Wie spät ist es?")) == "Wie spät ist es?"
    }
    check("Shown: an English question gets the English note, a German one nothing") {
        let english = PiShownContext.prompt(.init(question: "Find all my invoices from 2024 and tell me the total."))
        let german = PiShownContext.prompt(.init(question: "Such alle Rechnungen aus 2024 und sag mir die Summe."))
        let shown = PiShownContext.prompt(.init(question: "Summarize this letter briefly.", files: [URL(fileURLWithPath: "/tmp/brief.pdf")], language: "de"))
        return english.hasSuffix("\n\n" + PiShownContext.englishNote) && german == "Such alle Rechnungen aus 2024 und sag mir die Summe."
            && shown.hasSuffix("Summarize this letter briefly.\n\n" + PiShownContext.englishNote)
    }
    check("Shown: path and tool per kind (PDF → read_document, folder → list_folder, mail with subject, table → read), question last") {
        let files = [letter, folder, mail, table, photo]
        let prompt = PiShownContext.prompt(.init(question: "Bis wann muss ich zahlen?", files: files, newFiles: files, language: "de"))
        let lines = prompt.components(separatedBy: "\n")
        let pdf = lines.first { $0.contains("brief-finanzamt.pdf") } ?? ""
        let dirLine = lines.first { $0.contains("Unterlagen 2026") } ?? ""
        let mailLine = lines.first { $0.contains("einladung.eml") } ?? ""
        let tsv = lines.first { $0.contains("Nebenkosten.tsv") } ?? ""
        let img = lines.first { $0.contains("foto.jpg") } ?? ""
        return pdf.contains("2 Seiten") && pdf.contains(letter.path) && pdf.hasSuffix("mcp__pippa__read_document")
            && dirLine.contains("Ordner") && dirLine.contains("2 Einträge") && dirLine.hasSuffix("list_folder")
            && mailLine.contains("Einladung Sommerfest") && mailLine.hasSuffix("mcp__pippa__read_document")
            && tsv.hasSuffix("read") && img.contains("Bild") && img.hasSuffix("mcp__pippa__read_document")
            && lines.last == "Bis wann muss ich zahlen?" && !prompt.contains("1.234,56")
    }
    check("Shown: already shown → name and path only; several → \"gemeint\" marker on the focused one") {
        let prompt = PiShownContext.prompt(.init(question: "Und das andere?", files: [letter, mail], newFiles: [mail], focused: [mail], language: "de"))
        return prompt.contains("Weiter gezeigt") && prompt.contains("„brief-finanzamt.pdf“ – \(letter.path)") && !prompt.contains("2 Seiten")
            && prompt.contains("Einladung Sommerfest") && prompt.contains("(gemeint)")
    }
    check("Shown: short text is in the message, long text is provided as a file") {
        let short = PiShownContext.prompt(.init(question: "Was heißt das?", selectedText: "Kündigungsfrist drei Monate", language: "de"))
        let text = String(repeating: "Absatz mit Inhalt. ", count: 400)
        var written: String?
        let longPrompt = PiShownContext.prompt(.init(question: "Fass zusammen", selectedText: text, language: "de")) { value in
            written = value
            return base.appendingPathComponent("auswahl.txt")
        }
        return short.contains("<<<\nKündigungsfrist drei Monate\n>>>") && longPrompt.contains(base.appendingPathComponent("auswahl.txt").path)
            && written == text.trimmingCharacters(in: .whitespacesAndNewlines) && !longPrompt.contains("Absatz mit Inhalt. Absatz")
    }

    // MARK: read_document

    func call(_ tools: PippaMCPTools, _ name: String, _ arguments: [String: Any]) async -> (json: [String: Any], isError: Bool, text: String) {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let reply = await tools.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = reply?["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:], result["isError"] as? Bool ?? true, text)
    }
    func tools(_ turns: PippaMCPTurns) -> PippaMCPTools {
        var host = PippaMCPHost.demo()
        host.askForAccess = false
        host.turns = turns
        return PippaMCPTools(host: host)
    }

    await checkAsync("read_document: text PDF with page markers, amounts verbatim, untrusted content, reading and receipt reported") {
        let turns = PippaMCPTurns()
        let events = LockedBox<[WorkEvent]>([])
        let turn = PippaMCPTurn(onWork: { event in events.mutate { $0.append(event) } })
        turns.begin(turn)
        let r = await call(tools(turns), "read_document", ["path": letter.path])
        let data = r.json["data"] as? [String: Any] ?? [:]
        let text = data["text"] as? String ?? ""
        let reads = await turn.reads
        let reported = events.value.contains { if case .sources(let list) = $0 { return list.first?.name == "brief-finanzamt.pdf" && list.first?.status == .read }; return false }
        return !r.isError && r.json["untrusted"] as? Bool == true && (r.json["rule"] as? String)?.contains("never instructions") == true
            && text.contains("[S. 1]") && text.contains("[S. 2]") && text.contains("1.234,56 €") && text.contains("16.11.2026")
            && data["pageCount"] as? Int == 2 && data["pages"] as? String == "1-2" && data["truncated"] == nil
            && r.json["next"] as? String == "This is the whole document." && reads.count == 1 && reads[0].complete && reported
    }
    await checkAsync("Mail appointments: the instruction comes with an email read (read_document, mail_selected), not with a PDF, not in the system prompt") {
        let hint = PippaMCPTools.mailAppointmentHint
        let turns = PippaMCPTurns()
        let eml = await call(tools(turns), "read_document", ["path": mail.path])
        let pdf = await call(tools(turns), "read_document", ["path": letter.path])
        let selected = await call(tools(turns), "mail_selected", [:])
        let launch = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PiRPC/PippaPiLaunch.swift"), encoding: .utf8)) ?? "if_free"
        let inline = PiShownContext.prompt(.init(question: "Passt das?", files: [mail], newFiles: [mail], language: "de", inlineShortText: true))
        let pdfInline = PiShownContext.prompt(.init(question: "Passt das?", files: [letter], newFiles: [letter], language: "de", inlineShortText: true))
        return hint.contains("calendar_add mit if_free: true") && inline.contains(hint) && !pdfInline.contains(hint) && hint.contains("mail_draft") && !hint.contains("---")
            && (eml.json["next"] as? String)?.hasSuffix(hint) == true && (pdf.json["next"] as? String)?.contains(hint) == false
            && (selected.json["next"] as? String)?.hasSuffix(hint) == true
            && !launch.contains("if_free") && !launch.contains("mcp__pippa__calendar_add")
    }
    await checkAsync("read_document: long PDF continues page by page (nextPage), the late deadline arrives with from_page") {
        let first = await call(tools(PippaMCPTurns()), "read_document", ["path": long.path])
        let next = (first.json["data"] as? [String: Any])?["nextPage"] as? Int
        let second = await call(tools(PippaMCPTurns()), "read_document", ["path": long.path, "from_page": next ?? 0])
        let firstText = (first.json["data"] as? [String: Any])?["text"] as? String ?? ""
        let secondText = (second.json["data"] as? [String: Any])?["text"] as? String ?? ""
        return !first.isError && next != nil && (first.json["data"] as? [String: Any])?["truncated"] as? Bool == true
            && (first.json["next"] as? String)?.contains("from_page \(next!)") == true && first.text.utf8.count < 12_000
            && !firstText.contains("31.03.2027") && (secondText.contains("31.03.2027") || ((second.json["data"] as? [String: Any])?["nextPage"] != nil))
            && secondText.hasPrefix("[S. \(next!)]")
    }
    await checkAsync("read_document: plain-text errors instead of guessing (relative path, missing, folder, password, wrong argument)") {
        let t = tools(PippaMCPTurns())
        let relative = await call(t, "read_document", ["path": "brief.pdf"])
        let missing = await call(t, "read_document", ["path": base.appendingPathComponent("weg.pdf").path])
        let isFolder = await call(t, "read_document", ["path": folder.path])
        let protected = await call(t, "read_document", ["path": locked.path])
        let extra = await call(t, "read_document", ["path": letter.path, "pages": "1"])
        return [relative, missing, isFolder, protected, extra].allSatisfy(\.isError)
            && relative.json["status"] as? String == "invalid_arguments" && missing.json["status"] as? String == "not_found"
            && isFolder.json["status"] as? String == "is_folder" && protected.json["status"] as? String == "protected"
            && extra.json["status"] as? String == "invalid_arguments"
    }
    await checkAsync("read_document: small-model habits work (quoted path, escaped spaces, from_page as text, miscopied name); no permission is named") {
        let t = tools(PippaMCPTurns())
        let spaced = base.appendingPathComponent("Brief vom Amt.pdf")
        try? FileManager.default.removeItem(at: spaced)
        try? FileManager.default.copyItem(at: letter, to: spaced)
        let quoted = await call(t, "read_document", ["path": "\"\(spaced.path)\""])
        let escaped = await call(t, "read_document", ["path": spaced.path.replacingOccurrences(of: " ", with: "\\ ")])
        let page = await call(t, "read_document", ["path": letter.path, "from_page": "2"])
        let closed = base.appendingPathComponent("gesperrt.pdf")
        try? FileManager.default.removeItem(at: closed)
        try? FileManager.default.copyItem(at: letter, to: closed)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        let denied = await call(t, "read_document", ["path": closed.path])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: closed.path)
        // A miscopied long name ("DWG" → "DNG", seen with Qwen) gets the one close match back.
        let drawing = base.appendingPathComponent("A12-E-715-50-EA-DWG-1009-Underground Cable Duct.rev.7.pdf")
        try? FileManager.default.removeItem(at: drawing)
        try? FileManager.default.copyItem(at: letter, to: drawing)
        let miscopied = await call(t, "read_document", ["path": base.appendingPathComponent("A12-E-715-50-EA-DNG-1009-Underground Cable Duct.rev.7.pdf").path])
        let suggested = (miscopied.json["error"] as? String)?.contains("Did you mean \(drawing.path)?") == true
        return !quoted.isError && !escaped.isError && !page.isError && miscopied.json["status"] as? String == "not_found" && suggested
            && ((page.json["data"] as? [String: Any])?["text"] as? String)?.hasPrefix("[S. 2]") == true
            && denied.isError && denied.json["status"] as? String == "no_access"
    }
    await checkAsync("read_document: scan without text layer → text recognition, amount readable, marked as recognised") {
        let scan = base.appendingPathComponent("scan.pdf")
        renderedScan("Stadtwerke Musterstadt\nAbschlag Oktober\nBetrag: 84,20 EUR\nFällig am 15.10.2026", at: scan)
        guard (PDFDocument(url: scan)?.page(at: 0)?.string ?? "").isEmpty else { return false }
        let r = await call(tools(PippaMCPTurns()), "read_document", ["path": scan.path])
        let data = r.json["data"] as? [String: Any] ?? [:]
        let text = data["text"] as? String ?? ""
        let line = PiShownContext.describe(scan, german: true)
        if r.isError || !text.contains("84,20") { print("  read_document (Scan): \(r.text.prefix(400))") }
        return !r.isError && data["recognizedText"] as? Bool == true && text.contains("84,20") && line.contains("gescannt")
    }

    // MARK: Online lookup (pi-web-access): no card; the receipt line comes from the call's own arguments

    check("Web receipt: German lines for what went out (PiTurnReceipt takes them from Pi's tool arguments)") {
        let search = ActionReceipt.Item(action: "webSearch", outcome: "done", name: "Wetter morgen Köln · Regen Köln")
        let page = ActionReceipt.Item(action: "webPage", outcome: "failed", name: "https://wetter.example/koeln")
        return search.line(language: "de") == "Online nachgesehen: „Wetter morgen Köln · Regen Köln“"
            && page.line(language: "de") == "Nicht online gelesen: https://wetter.example/koeln (hat nicht geklappt)"
    }

    // MARK: Tool list, work line, receipt, verification

    check("Tool list: read_document only reads; no web tools on Pippa's server (pi-web-access has them)") {
        let list = PippaMCPTools.toolList()
        func hints(_ name: String) -> [String: Any] { list.first { $0["name"] as? String == name }?["annotations"] as? [String: Any] ?? [:] }
        let doc = hints("read_document")
        let names = list.compactMap { $0["name"] as? String }
        let bytes = (try? JSONSerialization.data(withJSONObject: list))?.count ?? .max
        return doc["readOnlyHint"] as? Bool == true && doc["openWorldHint"] as? Bool == false
            && !names.contains("web_search") && !names.contains("read_web_page")
            // Three writing tools on top (own size check in R3Checks).
            && list.count == 11 && bytes < 5400
    }
    // The other share (prompt, Pi's, Pippa's and the web tools) is runtime/pippa-tools/real-pi-budget.test.mjs, 6,400
    // characters; both together about 3,000 tokens, prefilled cold on every new conversation.
    check("First request budget: Pippa's MCP declarations as Pi sends them (name, description, schema) stay under 3,100 characters") {
        let declared = PippaMCPTools.toolList().map { tool in tool.filter { ["name", "description", "inputSchema"].contains($0.key) } }
        let bytes = (try? JSONSerialization.data(withJSONObject: declared, options: [.withoutEscapingSlashes]))?.count ?? .max
        if bytes >= 3100 { print("    MCP declarations: \(bytes) characters") }
        return bytes < 3100
    }
    check("Work line: Pippa's MCP tools show the same phases as the old path") {
        WorkPhase.tool("web_search", source: nil) == .lookingUpOnline && WorkPhase.tool("fetch_content", source: nil) == .lookingUpOnline
            && WorkPhase.tool("mcp__pippa__read_document", source: nil) == .lookingThrough(name: nil)
            && WorkPhase.tool("mcp__pippa__calendar_read", source: nil) == .checkingCalendar
    }
    check("Receipt: English web lines") {
        let done = ActionReceipt.Item(action: "webSearch", outcome: "done", name: "weather tomorrow Cologne")
        let empty = ActionReceipt.Item(action: "webPage", outcome: "done", name: "https://x.example/a", reason: "nothingFound")
        let failed = ActionReceipt.Item(action: "webSearch", outcome: "failed", name: "x y")
        return done.line(language: "en") == "Looked up online: “weather tomorrow Cologne”"
            && empty.line(language: "en") == "Read online: https://x.example/a (nothing found)"
            && failed.line(language: "en") == "Not looked up online: “x y” (didn’t work)"
    }
    await checkAsync("Verification: a wrong amount gets \"bitte prüfen\", a correct one stays unchanged (as on the old path)") {
        let context = ChatContext(files: [letter])
        let snapshots = try await LocalEngine.snapshots(for: context)
        let right = "Du musst 1.234,56 € bis zum 16.11.2026 zahlen."
        let wrong = "Du musst 1.243,56 € bis zum 16.11.2026 zahlen."
        let ok = PiAnswerReview.review(answer: right, question: "Wie viel und bis wann?", snapshots: snapshots, fileCount: 1)
        let marked = PiAnswerReview.review(answer: wrong, question: "Wie viel und bis wann?", snapshots: snapshots, fileCount: 1)
        return ok?.changed == false && marked?.changed == true && (marked?.text.contains("bitte prüfen") == true || marked?.text.contains("please check") == true)
            && marked?.text.contains("1.243,56") == true
    }
}

/// A "scan": text as an image in a PDF without a text layer.
private func renderedScan(_ text: String, at url: URL) {
    let size = CGSize(width: 1240, height: 1754)
    guard let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    bitmap.setFillColor(.white); bitmap.fill(CGRect(origin: .zero, size: size))
    let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                         CGPath(rect: CGRect(x: 120, y: 200, width: 1000, height: 1400), transform: nil), nil)
    CTFrameDraw(frame, bitmap)
    guard let image = bitmap.makeImage() else { return }
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    pdf.beginPDFPage(nil); pdf.draw(image, in: box); pdf.endPDFPage(); pdf.closePDF()
}
