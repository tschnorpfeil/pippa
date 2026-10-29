import AppKit
import CoreText
import CryptoKit
import Foundation
import PDFKit
import PippaCore

/// fill_pdf (not offered to Pi yet): blanks and labels of forms drawn here, answers checked before anything is written,
/// filled copies with the original unchanged, real form fields, and the MCP type called directly. The forms port Hob's
/// make-fixtures.swift (MIT, see THIRD_PARTY_NOTICES.md). No model.
func runFormFillChecks() async {
    let folder = dir("form-fill").resolvingSymlinksInPath()
    let priorResults = getenv("PIPPA_RESULTS_DIR").map { String(cString: $0) }
    setenv("PIPPA_RESULTS_DIR", folder.appendingPathComponent("results").path, 1)
    defer { if let priorResults { setenv("PIPPA_RESULTS_DIR", priorResults, 1) } else { unsetenv("PIPPA_RESULTS_DIR") } }
    let english = folder.appendingPathComponent("Leave request.pdf"), german = folder.appendingPathComponent("Antrag.pdf")
    let club = folder.appendingPathComponent("Club.pdf"), letter = folder.appendingPathComponent("Brief.pdf")
    let notes = folder.appendingPathComponent("Notizen.txt")
    leaveForm(at: english)
    germanForm(at: german)
    fieldForm(at: club)
    makePDF(["Sehr geehrte Damen und Herren,\n\nvielen Dank für Ihre Nachricht vom 3. März. Die Unterlagen schicke ich Ihnen bis Ende des Monats.\n\nMit freundlichen Grüßen\nMax Mustermann"], at: letter)
    write("Not a form", notes)
    func facts(_ result: PippaMCPToolResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Labels

    check("Form fill: labels as in Hob's tests (left label and caption, table row and column, box words, more lines)") {
        func page(_ lines: [PDFForm.Line], _ blanks: [PDFForm.Blank]) -> PDFForm.Page {
            PDFForm.Page(number: 1, width: 612, height: 792, recognized: true, lines: lines, blanks: blanks)
        }
        func l(_ t: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 12) -> PDFForm.Line { PDFForm.Line(text: t, x: x, y: y, w: w, h: h) }
        func line(_ x: Double, _ y: Double, _ w: Double) -> PDFForm.Blank { PDFForm.Blank(kind: .line, x: x, y: y, w: w, h: 1) }
        let row = PDFForm.label(page([l("Name", 60, 160, 34), l("Last name", 130, 175, 48, 10), l("First name", 340, 175, 50, 10), l("Phone", 60, 215, 37)],
                                     [line(130, 172, 180), line(340, 172, 180), line(130, 227, 180)]))
        let table = PDFForm.label(page([l("Date Leave to Begin", 230, 280, 93), l("Medical Leave", 60, 320, 80), l("Intermittent", 60, 352, 66)],
                                       [line(230, 332, 110), line(230, 364, 110)]))
        let box = PDFForm.label(page([l("• I agree to the terms", 59, 417, 125), l("A long paragraph of instructions that runs across the page", 46, 100, 500)],
                                     [PDFForm.Blank(kind: .box, x: 59.5, y: 420.5, w: 11.5, h: 11.5), line(46, 93, 520)]))
        let trailing = PDFForm.label(page([l("Cell Phone_", 340, 379, 59)], [line(394, 389, 126)]))
        let address = PDFForm.label(page([l("Home Address", 50, 303, 77)], [line(124, 313, 180), line(124, 338, 180), line(124, 364, 180)]))
        let unnamed = PDFForm.label(page([l("(1)", 59, 195, 18), l("_ (3)", 110, 195, 29)], [line(80, 205, 25), line(142, 205, 25)]))
        let rules = PDFForm.label(page([l("Note: Persons are not required to respond to this collection of information unless it displays a valid number", 52, 600, 400),
                                        l("Page 1 of 4", 46, 748, 50), l("Explain", 46, 400, 40)],
                                       [line(52, 598, 450), line(42, 744, 519), line(95, 410, 470)]))
        let rowIDs: [String] = row.map(\.id), rowLabels: [String] = row.map(\.label)
        let rowOK = rowIDs == ["p1:name-last-name", "p1:name-first-name", "p1:phone"] && rowLabels == ["Name / Last name", "Name / First name", "Phone"]
        let tableOK = table.map(\.label) == ["Medical Leave / Date Leave to Begin", "Intermittent / Date Leave to Begin"]
        let boxOK = box.map(\.label) == ["I agree to the terms"] && box.first?.blank.kind == .box
        let addressIDs: [String] = address.map(\.id)
        let addressOK = address.map(\.label) == ["Home Address", "Home Address (line 2)", "Home Address (line 3)"]
            && addressIDs == ["p1:home-address", "p1:home-address-line-2", "p1:home-address-line-3"]
        let rest = trailing.map(\.label) == ["Cell Phone"] && unnamed.isEmpty && rules.map(\.label) == ["Explain"]
        return rowOK && tableOK && boxOK && addressOK && rest
    }

    let leave = PDFForm.analyze(english, pages: 1...1)
    let antrag = PDFForm.analyze(german, pages: 1...3)

    check("Form fill: blanks of drawn forms get the ids Hob gives them; the boxes are boxes, signatures are marked") {
        guard let leave, let antrag else { return false }
        let ids = Set(leave.blanks.map(\.id)), germanIDs = Set(antrag.blanks.map(\.id))
        let expected: Set<String> = ["p1:name-last-name", "p1:name-first-name", "p1:phone", "p1:medical-leave-date-leave-to-begin",
                                     "p1:medical-leave-date-leave-to-end", "p1:intermittent-date-leave-to-begin", "p1:intermittent-date-leave-to-end",
                                     "p1:i-agree-to-the-terms", "p1:employee-signature", "p1:date"]
        let expectedGerman: Set<String> = ["p1:name-vorname", "p1:geburtsdatum", "p1:strasse-hausnummer", "p1:strasse-hausnummer-line-2",
                                           "p1:plz-ort", "p1:ich-stimme-zu", "p1:unterschrift", "p1:datum", "p2:telefon-tagsuber"]
        let boxes = (leave.blanks + antrag.blanks).filter { $0.blank.kind == .box }.map(\.id)
        let signatures = Set((leave.blanks + antrag.blanks).filter(\.isSignature).map(\.label))
        let shape = leave.pageCount == 1 && antrag.pageCount == 3 && leave.fields.isEmpty && antrag.fields.isEmpty
            && leave.pages.allSatisfy { !$0.recognized } && antrag.pages.map(\.number) == [1, 2, 3]
        return shape && ids == expected && germanIDs == expectedGerman && boxes == ["p1:i-agree-to-the-terms", "p1:ich-stimme-zu"]
            && signatures == ["Employee Signature", "Unterschrift"]
    }

    check("Form fill: an underlined heading and table borders are not blanks; a page-wide rule is a divider") {
        guard let leave, let page = leave.pages.first else { return false }
        let heading = page.blanks.contains { $0.kind == .line && abs($0.y - 123) < 3 }
        let borders = page.blanks.contains { $0.kind == .line && (abs($0.y - 270) < 2 || abs($0.y - 380) < 2) }
        let rule = page.blanks.contains { $0.kind == .line && abs($0.y - 600) < 2 && $0.w > 500 }
        let labeledRule = leave.blanks.contains { abs($0.blank.y - 600) < 2 }
        return !heading && !borders && rule && !labeledRule
    }

    check("Form fill: ids come from the page alone (another analysis, pages 1...1 or 1...3)") {
        let copy = folder.appendingPathComponent("Antrag Kopie.pdf")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: german, to: copy)
        guard let antrag, let again = PDFForm.analyze(copy, pages: 1...3), let first = PDFForm.analyze(german, pages: 1...1) else { return false }
        let firstPage = antrag.blanks.filter { $0.page == 1 }
        return again.blanks.map(\.id) == antrag.blanks.map(\.id) && first.blanks == firstPage && first.pages.map(\.number) == [1]
            && !firstPage.isEmpty
    }

    // MARK: Answers

    check("Form fill: unknown ids, yes on a line, signatures and empty answers are refused; yes ticks a box; an address spreads") {
        guard let antrag else { return false }
        func plan(_ answers: [String: String]) -> Result<PDFForm.FillPlan, PDFForm.FillProblem> {
            PDFForm.plan(PDFForm.spreadLines(answers, blanks: antrag.blanks), analysis: antrag)
        }
        let valid = antrag.blanks.map(\.id)
        let unknown = plan(["p9:nope": "x", "p1:name-vorname": "Mustermann, Max"]) == .failure(.unknownIDs(["p9:nope"], valid: valid))
        let wrong = plan(["p1:geburtsdatum": "ja"]) == .failure(.wrongKind(["p1:geburtsdatum"]))
        let signature = plan(["p1:unterschrift": "Max Mustermann"]) == .failure(.signature(["p1:unterschrift"]))
        let empty = plan(["p1:name-vorname": "  ", "p1:geburtsdatum": ""]) == .failure(.nothingToFill)
        guard case .success(let ticked) = plan(["[p1:ich-stimme-zu]": "ja", "p1:name-vorname": "Mustermann, Max"]),
              case .success(let declined) = plan(["p1:ich-stimme-zu": "nein", "p1:name-vorname": "Mustermann,\nMax"]) else { return false }
        let box = ticked.marks.count == 2 && ticked.marks.contains { $0.check && $0.text == "X" && $0.page == 1 }
            && ticked.stillEmpty.contains("Unterschrift") && !ticked.stillEmpty.contains("Ich stimme zu")
            && !ticked.stillEmpty.contains("Telefon (tagsüber)")
        let no = declined.marks.count == 1 && declined.marks.first?.text == "Mustermann, Max" && !declined.stillEmpty.contains("Ich stimme zu")
        let spread = PDFForm.spreadLines(["p1:strasse-hausnummer": "Musterweg 1, 12345 Köln"], blanks: antrag.blanks)
            == ["p1:strasse-hausnummer": "Musterweg 1", "p1:strasse-hausnummer-line-2": "12345 Köln"]
        return unknown && wrong && signature && empty && box && no && spread
    }

    // MARK: Writing

    check("Form fill: the copy has the answers as text boxes; the original's bytes stay the same") {
        guard let antrag, case .success(let plan) = PDFForm.plan(PDFForm.spreadLines(
            ["p1:name-vorname": "Mustermann, Max", "p1:geburtsdatum": "01.02.1980", "p1:strasse-hausnummer": "Musterweg 1, 12345 Köln",
             "p1:ich-stimme-zu": "ja"], blanks: antrag.blanks), analysis: antrag) else { return false }
        let before = SHA256.hash(data: try Data(contentsOf: german))
        let copy = folder.appendingPathComponent("Antrag gefüllt.pdf")
        let count = try PDFForm.write(plan, source: german, to: copy)
        guard let filled = PDFDocument(url: copy), let original = PDFDocument(url: german) else { return false }
        let texts = (0..<filled.pageCount).flatMap { filled.page(at: $0)?.annotations ?? [] }.compactMap(\.contents)
        let untouched = (0..<original.pageCount).allSatisfy { original.page(at: $0)?.annotations.isEmpty ?? false }
        let answers = ["Mustermann, Max", "01.02.1980", "Musterweg 1", "12345 Köln", "X"].allSatisfy { texts.contains($0) }
        let after = SHA256.hash(data: try Data(contentsOf: german))
        return count == 5 && filled.pageCount == 3 && answers && untouched && before == after
    }

    check("Form fill: real form fields get their values; a checkbox is on and exactly one radio option is") {
        guard let analysis = PDFForm.analyze(club, pages: 1...40) else { return false }
        let kinds = Dictionary(analysis.fields.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let options = Set(analysis.fields.first(where: { $0.name == "membership" })?.options ?? [])
        guard kinds == ["full_name": .text, "newsletter": .checkbox, "membership": .radio], options == ["Monthly", "Yearly"],
              analysis.blanks.isEmpty, analysis.pages.allSatisfy({ $0.blanks.isEmpty }),
              case .success(let plan) = PDFForm.plan(["f:full_name": "Ada Lovelace", "f:newsletter": "yes", "f:membership": "yearly"], analysis: analysis)
        else { return false }
        let copy = folder.appendingPathComponent("Club filled.pdf")
        let count = try PDFForm.write(plan, source: club, to: copy)
        guard let page = PDFDocument(url: copy)?.page(at: 0) else { return false }
        let widgets = page.annotations.filter { $0.type == "Widget" }
        let name = widgets.first(where: { $0.fieldName == "full_name" })?.widgetStringValue
        let box = widgets.first(where: { $0.fieldName == "newsletter" })?.buttonWidgetState
        let on = widgets.filter { $0.fieldName == "membership" && $0.buttonWidgetState == .onState }
        let back = PDFForm.analyze(copy, pages: 1...1)?.fields.first(where: { $0.name == "membership" })?.value
        return count == 3 && plan.fields["membership"] == "Yearly" && name == "Ada Lovelace" && box == .onState
            && on.count == 1 && on.first?.buttonWidgetStateString == "Yearly" && back == "Yearly"
    }

    check("Form fill: the list for read_document names ids, labels and kinds; a letter gets none") {
        guard let leave, let fields = PDFForm.analyze(club, pages: 1...1), let plain = PDFForm.analyze(letter, pages: 1...1) else { return false }
        let blanks = PDFForm.modelSummary(leave)?["blanks"] as? [String] ?? []
        let listed = PDFForm.modelSummary(fields)?["fields"] as? [String] ?? []
        let named = blanks.contains("p1:i-agree-to-the-terms: I agree to the terms (box)")
            && blanks.contains("p1:employee-signature: Employee Signature (signature, leave empty)")
            && blanks.contains("p1:name-last-name: Name / Last name") && listed.contains("f:full_name: Full name (text)")
        let cut = PDFForm.modelSummary(leave, limit: 3)?["truncated"] as? Bool == true
        return named && cut && plain.blanks.isEmpty && PDFForm.modelSummary(plain) == nil && PDFForm.instructions.contains("mcp__pippa__fill_pdf")
    }

    // MARK: MCP, called directly (fill_pdf is not registered until read_document lists blanks)

    check("fill_pdf: closed schema, marked as changing something, and not in the tool list yet") {
        let tool = PippaMCPFormFill.toolList().first ?? [:]
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let hints = tool["annotations"] as? [String: Any] ?? [:]
        let listed = PippaMCPTools.toolList().compactMap { $0["name"] as? String }
        let closed = tool["name"] as? String == PippaMCPFormFill.name && schema["additionalProperties"] as? Bool == false
            && (schema["properties"] as? [String: Any])?.keys.sorted() == ["answers", "path"]
        return closed && hints["readOnlyHint"] as? Bool == false && hints["destructiveHint"] as? Bool == false
            && !PippaMCPTools.toolNames.contains(PippaMCPFormFill.name) && !listed.contains(PippaMCPFormFill.name)
    }

    await checkAsync("fill_pdf: a filled copy in the results folder with its card, create receipt and note for this answer") {
        var host = PippaMCPHost.demo()
        host.turns = PippaMCPTurns()
        let turn = PippaMCPTurn()
        host.turns.begin(turn)
        let result = await PippaMCPFormFill(host: host, turn: turn, scope: turn.writes).call(["path": german.path, "answers": [
            "p1:name-vorname": "Mustermann, Max", "p1:geburtsdatum": "01.02.1980", "p1:ich-stimme-zu": "ja"]])
        let payload = facts(result)
        guard !result.isError, case .filledForm(let card)? = result.card else { return false }
        let note = PippaMCPFormFill.readNote(for: result, turnID: turn.id)
        let reported = payload["done"] as? Bool == true && payload["dispatched"] as? Bool == true
            && (payload["data"] as? [String: Any])?["path"] as? String == card.file.path
        let kept = ResultsFolder.contains(card.file) && fm.fileExists(atPath: card.file.path)
            && card.file.lastPathComponent == L("%@ (filled in)", table: "MCP", "Antrag") + ".pdf"
        let described = card.source == "Antrag.pdf" && card.pageCount == 3 && card.filled == 3 && card.stillEmpty.contains("Unterschrift")
        let receipt = result.receipt?.action == "create" && result.receipt?.outcome == "done" && result.receipt?.turnID == turn.id
            && result.receipt?.name == card.file.lastPathComponent
        let noted = note.turnID == turn.id && note.read && note.card == result.card && note.line == L("Form filled in", table: "MCP")
        return reported && kept && described && receipt && noted
    }

    await checkAsync("fill_pdf: drafts-only, stopped and refused requests write nothing and report a status read as no effect") {
        let results = folder.appendingPathComponent("results")
        func copies() -> Int { ((try? fm.subpathsOfDirectory(atPath: results.path)) ?? []).filter { $0.hasSuffix(".pdf") }.count }
        let before = copies()
        var host = PippaMCPHost.demo()
        host.turns = PippaMCPTurns()
        let answers: [String: String] = ["p1:name-vorname": "Mustermann, Max"]
        let draft = PippaMCPTurn(allowsNativeWrites: false)
        host.turns.begin(draft)
        let drafted = await PippaMCPFormFill(host: host, turn: draft, scope: draft.writes).call(["path": german.path, "answers": answers])
        let turn = PippaMCPTurn()
        host.turns.begin(turn)
        let tool = PippaMCPFormFill(host: host, turn: turn, scope: turn.writes)
        let refused: [([String: Any], String)] = [
            (["path": german.path, "answers": ["p9:nope": "x"]], "invalid_arguments"),
            (["path": german.path, "answers": ["p1:unterschrift": "Max Mustermann"]], "invalid_arguments"),
            (["path": german.path, "answers": ["p1:geburtsdatum": "ja"]], "invalid_arguments"),
            (["path": german.path, "answers": ["p1:geburtsdatum": " "]], "invalid_arguments"),
            (["path": german.path, "answers": ["p1:geburtsdatum": 1]], "invalid_arguments"),
            (["path": german.path, "answers": answers, "save_as": "/tmp/x.pdf"], "invalid_arguments"),
            (["path": "Antrag.pdf", "answers": answers], "invalid_arguments"),
            (["path": notes.path, "answers": answers], "invalid_arguments"),
            (["path": letter.path, "answers": answers], "invalid_arguments"),
            (["path": folder.appendingPathComponent("Fehlt.pdf").path, "answers": answers], "not_found"),
        ]
        var statuses = [facts(drafted)["status"] as? String ?? ""]
        for (arguments, status) in refused {
            let result = await tool.call(arguments)
            let payload = facts(result)
            guard result.isError, payload["status"] as? String == status, payload["dispatched"] as? Bool == false, result.card == nil,
                  result.receipt?.outcome == "blocked" else { return false }
            statuses.append(status)
        }
        host.turns.end(turn)
        let stopped = await tool.call(["path": german.path, "answers": answers])
        statuses.append(facts(stopped)["status"] as? String ?? "")
        let noEffect: Set<String> = ["not_dispatched", "failed", "invalid_arguments", "denied", "not_found"]
        let refusedFirst = facts(drafted)["status"] as? String == "not_dispatched" && drafted.receipt?.reason == "draftOnly"
            && stopped.receipt?.outcome == "cancelled" && !PippaMCPFormFill.readNote(for: stopped, turnID: turn.id).read
        return refusedFirst && statuses.allSatisfy { noEffect.contains($0) } && copies() == before
    }

    await runFormFillStorageCheck(folder: folder)
}

@MainActor private func runFormFillStorageCheck(folder: URL) {
    check("Filled form card: stored with the answer, and the history keeps its copy from the results cleanup") {
        let file = folder.appendingPathComponent("results/kept/Antrag (filled in).pdf")
        let card = ResultCard.filledForm(FilledFormCard(file: file, source: "Antrag.pdf", pageCount: 3, filled: 4, stillEmpty: ["Unterschrift"]))
        let back = try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card))
        let store = try ConversationStore(directory: dir("form-fill-history"))
        let conversation = try store.create()
        _ = try store.append(ConversationMessage(role: .assistant, text: "Filled in", actions: .init(items: [], cards: [card])), to: conversation.id)
        let reopened = try ConversationStore(directory: store.fileURL.deletingLastPathComponent())
        return back == card && reopened.retainedResultFiles() == [file]
    }
}

// MARK: Fixtures

/// Draws like Hob's fixtures: `top` is measured from the page's top edge, text by the top of its letters.
private struct FormPage {
    let ctx: CGContext
    let height: CGFloat

    private func makeFont(_ size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    private func makeLine(_ s: String, _ font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes) as CFAttributedString)
    }

    func text(_ s: String, _ x: CGFloat, _ top: CGFloat, size: CGFloat = 12, bold: Bool = false) {
        let font = makeFont(size, bold: bold)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: height - top - font.ascender)
        CTLineDraw(makeLine(s, font), ctx)
    }

    func width(_ s: String, size: CGFloat = 12, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(makeLine(s, makeFont(size, bold: bold)), nil, nil, nil))
    }

    func line(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat) {
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: x, y: height - top - 1, width: w, height: 1))
    }

    func box(_ x: CGFloat, _ top: CGFloat) {
        ctx.setStrokeColor(gray: 0.1, alpha: 1)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: x, y: height - top - 11, width: 11, height: 11))
    }
}

private func drawPDF(at url: URL, pages: [(FormPage) -> Void]) {
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { return }
    for draw in pages {
        ctx.beginPDFPage(nil)
        draw(FormPage(ctx: ctx, height: media.height))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Hob's leave request form (make-fixtures.swift), with real text instead of a scan, and a page-wide rule.
private func leaveForm(at url: URL) {
    drawPDF(at: url, pages: [{ p in
        p.text("LEAVE REQUEST FORM", 200, 60, size: 14, bold: true)
        // An underlined heading (2 points under the baseline): not a blank.
        p.text("Section A", 60, 110, size: 14, bold: true)
        p.line(60, 123, p.width("Section A", size: 14, bold: true))
        // Two blanks on one row, with captions under them.
        p.text("Name", 60, 160)
        p.line(130, 172, 180)
        p.line(340, 172, 180)
        p.text("Last name", 130, 176, size: 10)
        p.text("First name", 340, 176, size: 10)
        p.text("Phone", 60, 215)
        p.line(130, 227, 180)
        // A box around a table: its edges aren't blanks.
        p.ctx.setStrokeColor(gray: 0.45, alpha: 1)
        p.ctx.setLineWidth(1)
        p.ctx.stroke(CGRect(x: 50, y: p.height - 380, width: 510, height: 110))
        p.text("Date Leave to Begin", 230, 285, size: 10)
        p.text("Date Leave to End", 390, 285, size: 10)
        p.text("Medical Leave", 60, 320)
        p.line(230, 332, 110)
        p.line(390, 332, 110)
        p.text("Intermittent", 60, 352)
        p.line(230, 364, 110)
        p.line(390, 364, 110)
        // A checkbox with its label to the right.
        p.box(60, 421)
        p.text("I agree to the terms", 80, 420)
        p.line(60, 500, 200)
        p.text("Employee Signature", 60, 504, size: 10)
        p.line(340, 500, 180)
        p.text("Date", 340, 504, size: 10)
        // A page-wide rule with nothing asking for an answer: a divider.
        p.line(40, 600, 532)
    }])
}

/// The German variant: three pages, an address with a second line, a box and a signature.
private func germanForm(at url: URL) {
    drawPDF(at: url, pages: [{ p in
        p.text("Antrag auf Mitgliedschaft", 60, 50, size: 14, bold: true)
        p.text("Name, Vorname", 60, 200)
        p.line(200, 212, 300)
        p.text("Geburtsdatum", 60, 240)
        p.line(200, 252, 150)
        p.text("Straße, Hausnummer", 60, 280)
        p.line(200, 292, 300)
        p.line(200, 320, 300)
        p.text("PLZ, Ort", 60, 350)
        p.line(200, 362, 300)
        p.box(60, 401)
        p.text("Ich stimme zu", 80, 400)
        p.line(60, 480, 200)
        p.text("Unterschrift", 60, 484, size: 10)
        p.line(340, 480, 180)
        p.text("Datum", 340, 484, size: 10)
        p.text("Seite 1 von 3", 60, 760, size: 9)
    }, { p in
        p.text("Telefon (tagsüber)", 60, 100)
        p.line(200, 112, 200)
        p.text("Seite 2 von 3", 60, 760, size: 9)
    }, { p in
        p.text("Hinweise zum Datenschutz: Die Angaben werden nur für die Mitgliederverwaltung verwendet.", 60, 100, size: 10)
        p.text("Seite 3 von 3", 60, 760, size: 9)
    }])
}

/// Hob's fillable form (make-fixtures.swift) with a two-option radio group added.
private func fieldForm(at url: URL) {
    drawPDF(at: url, pages: [{ p in
        p.text("Club Membership Form", 60, 56, size: 16, bold: true)
        p.text("Full name", 60, 111)
        p.text("Send me the newsletter", 80, 151)
        p.text("Membership", 60, 191)
        p.text("Monthly", 180, 191)
        p.text("Yearly", 280, 191)
    }])
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return }
    let name = PDFAnnotation(bounds: CGRect(x: 140, y: 665, width: 220, height: 20), forType: .widget, withProperties: nil)
    name.widgetFieldType = .text
    name.fieldName = "full_name"
    page.addAnnotation(name)
    let box = PDFAnnotation(bounds: CGRect(x: 60, y: 628, width: 14, height: 14), forType: .widget, withProperties: nil)
    box.widgetFieldType = .button
    box.widgetControlType = .checkBoxControl
    box.fieldName = "newsletter"
    page.addAnnotation(box)
    for (x, option) in [(CGFloat(160), "Monthly"), (CGFloat(260), "Yearly")] {
        let radio = PDFAnnotation(bounds: CGRect(x: x, y: 588, width: 14, height: 14), forType: .widget, withProperties: nil)
        radio.widgetFieldType = .button
        radio.widgetControlType = .radioButtonControl
        radio.fieldName = "membership"
        radio.buttonWidgetStateString = option
        page.addAnnotation(radio)
    }
    _ = document.write(to: url)
}
