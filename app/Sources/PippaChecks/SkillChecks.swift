import Foundation
import PippaCore

/// Curated skills: Swift reads them from runtime/pippa-skills (no list of its own), the instructions stay short, suggestions are few and fit the place in the conversation.
/// Excel files are read with formulas.
func runSkillChecks() {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime/pippa-skills", isDirectory: true)
    let shipped = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    let skills = PippaSkill.load(from: folder)
    let read = { (name: String) in (try? String(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "" }

    check("Skills: Swift finds every shipped folder from the SKILL.md header, nothing is kept twice") {
        skills.map(\.name) == shipped
            && Set(shipped) == ["text-kuerzen", "dokument-einordnen", "rechnung-auslesen", "fristen-erkennen", "antwort-schreiben", "brief-verstehen", "tabelle-pruefen", "text-verbessern", "zusammenfassen",
                                  "online-pruefen", "termin-aus-mail"]
    }
    // Two skills act through Pi's tools on purpose: the invoice table (write; pippa-assist keeps the old version) and
    // deadlines (calendar_add). All others change nothing.
    let acting: Set<String> = ["rechnung-auslesen", "fristen-erkennen"]
    check("Skills: SKILL.md follows Pi's header rules (name like folder, lowercase with hyphens, description), explicit invocation only, short, no tool names, changes nothing unless meant to") {
        var bad: [String] = []
        for name in shipped {
            let parts = read(name).components(separatedBy: "---\n")
            guard parts.count >= 3, parts[0].isEmpty else { bad.append(name); continue }
            let head = parts[1], body = parts.dropFirst(2).joined(separator: "---\n")
            let ok = head.contains("name: \(name)\n") && PippaSkill.isValid(name: name) && head.contains("description: ")
                && head.contains("disable-model-invocation: true\n")
                && body.count <= 1300 && !body.contains("list_context") && !body.contains("read_context") && !body.contains("http")
                && (acting.contains(name) || body.contains("Du änderst keine Datei"))
            if !ok { bad.append(name) }
        }
        if !bad.isEmpty { print("   ", bad) }
        return bad.isEmpty
    }
    check("Skills: read the header (Pippa fields, quotation marks) and reject invalid headers") {
        let ok = PippaSkill.parse("---\nname: ein-skill\ndescription: \"Tut etwas.\"\npippa-label: Los\npippa-suggest: tabelle, immer, unsinn\npippa-draft: true\n---\nText", folder: "ein-skill")
        return ok?.description == "Tut etwas." && ok?.title == "Los" && ok?.prompt == "Los" && ok?.writesDraft == true && ok?.places == [.tabelle, .immer]
            && PippaSkill.parse("---\nname: anders\ndescription: x\n---\n", folder: "ein-skill") == nil
            && PippaSkill.parse("---\nname: Ein_Skill\ndescription: x\n---\n", folder: "Ein_Skill") == nil
            && PippaSkill.parse("---\nname: a--b\ndescription: x\n---\n", folder: "a--b") == nil
            && PippaSkill.parse("---\nname: ein-skill\n---\n", folder: "ein-skill") == nil
            && PippaSkill.parse("kein Kopf", folder: "ein-skill") == nil
            && PippaSkill.parse("---\nname: ohne-knopf\ndescription: x\npippa-suggest: brief\n---\n", folder: "ohne-knopf")?.places == []
    }
    check("Skills: button and message in English, German with -de fields; if the translation is missing, English applies") {
        let head = "---\nname: zwei\ndescription: x\npippa-label: Summarize\npippa-label-de: Zusammenfassen\npippa-prompt: Please summarize this.\npippa-prompt-de: Fass das bitte zusammen.\n---\n"
        let english = PippaSkill.parse(head, folder: "zwei", german: false)
        let german = PippaSkill.parse(head, folder: "zwei", german: true)
        let untranslated = PippaSkill.parse("---\nname: eins\ndescription: x\npippa-label: Go\n---\n", folder: "eins", german: true)
        let labeled = PippaSkill.load(from: folder, german: false).filter { $0.title != nil }.map(\.name)
        let germanSkills = PippaSkill.load(from: folder, german: true)
        let translated = labeled.allSatisfy { name in
            let front = read(name).components(separatedBy: "---\n").dropFirst().first ?? ""
            return front.contains("\npippa-label-de: ") && front.contains("\npippa-prompt-de: ")
        }
        return english?.title == "Summarize" && english?.prompt == "Please summarize this."
            && german?.title == "Zusammenfassen" && german?.prompt == "Fass das bitte zusammen."
            && untranslated?.title == "Go" && untranslated?.prompt == "Go"
            && !labeled.isEmpty && translated
            && germanSkills.first { $0.name == "brief-verstehen" }?.title == "Einfach erklären"
    }
    check("Skills: a new folder with SKILL.md shows up as a suggestion without a Swift change") {
        let extra = dir("skills-extra")
        let one = extra.appendingPathComponent("neu-hier")
        try fm.createDirectory(at: one, withIntermediateDirectories: true)
        write("---\nname: neu-hier\ndescription: Neu.\npippa-label: Neu\npippa-suggest: dokument\n---\nAnleitung", one.appendingPathComponent("SKILL.md"))
        let loaded = PippaSkill.load(from: extra)
        return loaded.map(\.name) == ["neu-hier"] && PippaSkill.suggestions(for: .dokument, in: loaded).count == 1 && PippaSkill.suggestions(for: .tabelle, in: loaded).isEmpty
    }
    check("Skills: objection says \"keine Rechtsberatung\" and names the deadline, drafts send nothing") {
        let answer = read("antwort-schreiben")
        return answer.contains("keine Rechtsberatung") && answer.contains("Frist") && answer.contains("Kündigung")
            && skills.filter(\.writesDraft).allSatisfy { read($0.name).contains("Du verschickst nichts") }
    }
    check("Skills: sheet check knows error kinds and German function names") {
        let sheet = read("tabelle-pruefen")
        return sheet.contains("#BEZUG!") && sheet.contains("$") && sheet.contains("SUMME")
    }
    check("Skills: few suggestions per place, every skill with a button reachable somewhere, folders, links and slides without buttons") {
        let all = Set(PippaSkill.Place.allCases.flatMap { PippaSkill.suggestions(for: $0, in: skills) }.map(\.name))
        return PippaSkill.Place.allCases.allSatisfy { (0...5).contains(PippaSkill.suggestions(for: $0, in: skills).count) } && all == Set(skills.filter { $0.title != nil }.map(\.name))
            && PippaSkill.suggestions(for: .tabelle, in: skills).map(\.name) == ["tabelle-pruefen", "zusammenfassen"]
            && PippaSkill.suggestions(for: .immer, in: skills).isEmpty
            && PippaSkill.place(for: .pdf) == nil && PippaSkill.place(for: .image) == nil && PippaSkill.place(for: .mail) == nil
            && PippaSkill.place(for: .office, fileExtension: "XLSX") == .tabelle && PippaSkill.place(for: .office, fileExtension: "docx") == nil
            && PippaSkill.place(for: .office, fileExtension: "pages") == nil && PippaSkill.place(for: .text, fileExtension: "csv") == .tabelle
            && PippaSkill.place(for: .text, fileExtension: "txt") == nil && PippaSkill.place(for: .office, fileExtension: "pptx") == nil
            && PippaSkill.place(for: .folder) == nil && PippaSkill.place(for: .link) == nil && PippaSkill.place(for: .mixed) == nil
            && skills.first { $0.name == "brief-verstehen" }?.writesDraft == false && skills.first { $0.name == "antwort-schreiben" }?.writesDraft == true
    }
    check("Suggestions: generic files abstain while explicit selection palette remains available") {
        PippaSkill.place(for: .text, fileExtension: "md") == nil
            && PippaSkill.place(for: .office, fileExtension: "rtf") == nil
            && PippaSkill.place(for: .mail, fileExtension: "eml") == nil
            && !PippaSkill.suggestions(for: .text, in: skills).isEmpty
            && PippaSkill.suggestions(for: .brief, in: skills).contains { $0.name == "antwort-schreiben" }
    }
    check("Skills: suggestions in the conversation classify by extension like the engine (slides and folders without buttons)") {
        let place = { (path: String, folder: Bool) in
            let url = URL(fileURLWithPath: path, isDirectory: folder)
            return PippaSkill.place(for: DropKind.guess(for: url), fileExtension: url.pathExtension)
        }
        return place("/x/Brief.PDF", false) == nil && place("/x/Scan.heic", false) == nil && place("/x/Haushalt.numbers", false) == .tabelle
            && place("/x/Bericht.odt", false) == nil && place("/x/Notiz.txt", false) == nil && place("/x/Liste.csv", false) == .tabelle
            && place("/x/Folien.pptx", false) == nil && place("/x/Steuer", true) == nil
            && DropKind.officeExtensions.isSuperset(of: ["docx", "xlsx", "pages", "numbers", "pptx", "rtf"])
    }
    check("Skills: buttons and messages in plain English and German, no jargon") {
        let both = PippaSkill.load(from: folder, german: false) + PippaSkill.load(from: folder, german: true)
        let texts = both.flatMap { [$0.title ?? "", $0.prompt] }
        let jargon = ["Skill", "Prompt", "Modell", "Model", "KI", "AI ", "Agent", "Token", "Pi "]
        return !texts.isEmpty && texts.allSatisfy { text in !jargon.contains { text.contains($0) } }
    }
    check("Read Excel: formulas with results, values, text cells, sheet names (stored and deflate)") {
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Betrag</t></is></c></row>\
        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>10.5</v></c></row>\
        <row r="3"><c r="A3" t="s"><v>2</v></c><c r="B3"><f>SUM(B2:B2)</f><v>10.5</v></c></row>\
        <row r="4"><c r="B4" t="e"><f>#REF!+1</f><v>#REF!</v></c><c r="C4"/></row></sheetData></worksheet>
        """
        let strings = #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Posten</t></si><si><t>Miete</t></si><si><r><t>Sum</t></r><r><t>me</t></r></si></sst>"#
        let files: [(String, String)] = [
            ("xl/workbook.xml", #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Haushalt" sheetId="1" r:id="rId7"/></sheets></workbook>"#),
            ("xl/_rels/workbook.xml.rels", #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="x" Target="worksheets/sheet1.xml"/></Relationships>"#),
            ("xl/sharedStrings.xml", strings), ("xl/worksheets/sheet1.xml", sheet),
        ]
        var stored = ZipWriter()
        for (name, content) in files { stored.add(name, Data(content.utf8)) }
        // Packed like Excel does (deflate): with the system zip.
        let folder = dir("xlsx-fixture")
        for (name, content) in files {
            let url = folder.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            write(content, url)
        }
        let packed = dir("xlsx-packed").appendingPathComponent("Haushalt.xlsx")
        try? fm.removeItem(at: packed)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = folder
        zip.arguments = ["-qr", packed.path, "xl"]
        try zip.run(); zip.waitUntilExit()
        let broken = dir("xlsx-broken").appendingPathComponent("kaputt.xlsx")
        try Data("kein zip".utf8).write(to: broken)
        let expected = ["Blatt „Haushalt“", "A1: Posten | B1: Betrag", "A2: Miete | B2: 10,5", "A3: Summe | B3 = SUM(B2:B2) → 10,5", "B4 = #REF!+1 → #REF!"].joined(separator: "\n")
        let viaReader = TextReader.read(packed)
        let packedData = try Data(contentsOf: packed)
        return XLSXReader.read(stored.finish())?.text == expected && XLSXReader.read(packedData)?.text == expected
            && viaReader.fullText == expected && viaReader.problem == .none && TextReader.read(broken).problem == .damaged
    }
    check("Skills: draft flag is kept in the history, older histories count as no draft") {
        let draft = ConversationMessage(role: .assistant, text: "Sehr geehrte …", draft: true)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(draft))
        let old = try JSONDecoder().decode(ConversationMessage.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","text":"Alt","timestamp":0,"attachments":[]}"#.utf8))
        return decoded.draft == true && old.draft == nil && ConversationMessage(role: .assistant, text: "x").draft == nil
    }
    check("Read ZIP: truncated archives, wrong offsets and CRC are rejected; empty entries are fine") {
        var writer = ZipWriter()
        writer.add("a", Data("Inhalt".utf8)); writer.add("leer", Data())
        let good = writer.finish()
        guard ZipReader(good)?.read("leer") == Data() else { return false }
        for i in 0..<good.count { if ZipReader(Data(good.prefix(i))) != nil { return false } }
        var corrupt = good; corrupt[31] ^= 1
        guard ZipReader(corrupt)?.read("a") == nil else { return false }
        var offset = good
        for i in (offset.count - 6)..<(offset.count - 2) { offset[i] = 255 }
        return ZipReader(offset) == nil
    }
    check("Read Excel: damaged XML/missing sheet is not reported as complete; shared formulas kept; limit in the middle of a row") {
        func archive(_ sheet: String?) -> Data {
            var zip = ZipWriter()
            zip.add("xl/workbook.xml", Data(#"<workbook xmlns:r="r"><sheets><sheet name="Test" r:id="r1"/></sheets></workbook>"#.utf8))
            zip.add("xl/_rels/workbook.xml.rels", Data(#"<Relationships><Relationship Id="r1" Target="/xl/worksheets/sheet1.xml"/></Relationships>"#.utf8))
            if let sheet { zip.add("xl/worksheets/sheet1.xml", Data(sheet.utf8)) }
            return zip.finish()
        }
        guard XLSXReader.read(archive(nil)) == nil,
              XLSXReader.read(archive("<worksheet><sheetData><row><c r='A1'><v>1</v></c></row>")) == nil,
              XLSXReader.read(archive("<worksheet><row><c r='A1' t='s'><v>7</v></c></row></worksheet>")) == nil else { return false }
        let shared = XLSXReader.read(archive("<worksheet><row><c r='B1'><f t='shared' si='0'>A1*2</f><v>4</v></c><c r='B2'><f t='shared' si='0'/><v>6</v></c></row></worksheet>"))
        guard shared?.text.contains("B2 = [gemeinsame Formel, relativ zu B1: A1*2] → 6") == true else { return false }
        let many = (1...4001).map { "<c r='A\($0)'><v>\($0)</v></c>" }.joined()
        let limited = XLSXReader.read(archive("<worksheet><row>\(many)</row></worksheet>"))
        return limited?.truncated == true && limited?.text.contains("A4000: 4000") == true && limited?.text.contains("A4001:") == false
    }
}
