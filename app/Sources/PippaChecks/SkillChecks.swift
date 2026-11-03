import Foundation
import PippaCore

/// Curated skills: Swift reads them from runtime/pippa-skills (no list of its own), the instructions stay short, suggestions are few and fit the place in the conversation.
/// Excel files are read with formulas.
func runSkillChecks() {
    check("Server lock: oversized PIDs and malformed locks are rejected safely") {
        let file = root.appendingPathComponent("invalid-server.lock")
        for fields in ["\"holder\":9223372036854775807,\"pid\":null", "\"holder\":1,\"pid\":9223372036854775807"] {
            try Data("{\"owner\":\"pi\",\"port\":8191,\(fields)}".utf8).write(to: file)
            guard PiServerLock.read(file) == nil, !PiServerLock.remove(file, if: { _ in true }),
                  fm.fileExists(atPath: file.path) else { return false }
        }
        return true
    }
    check("Read Excel: both 1904 date flags apply the workbook epoch") {
        func workbook(_ flag: String, serial: Int) -> Data {
            var zip = ZipWriter()
            zip.add("xl/workbook.xml", Data("<workbook xmlns:r='r'><workbookPr date1904='\(flag)'/><sheets><sheet name='Dates' r:id='r1'/></sheets></workbook>".utf8))
            zip.add("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id='r1' Target='worksheets/sheet1.xml'/></Relationships>".utf8))
            zip.add("xl/styles.xml", Data("<styleSheet><cellXfs><xf numFmtId='14'/></cellXfs></styleSheet>".utf8))
            zip.add("xl/worksheets/sheet1.xml", Data("<worksheet><row><c r='A1' s='0'><v>\(serial)</v></c></row></worksheet>".utf8))
            return zip.finish()
        }
        let expected = XLSXReader.read(workbook("0", serial: 46023))?.text
        return expected?.contains("2026-01-01") == true && ["1", "true"].allSatisfy {
            XLSXReader.read(workbook($0, serial: 44561))?.text == expected
                && XLSXReader.read(workbook($0, serial: 0))?.text.contains("1904-01-01") == true
                && XLSXReader.read(workbook($0, serial: 2_957_003))?.text.contains("9999-12-31") == true
                && XLSXReader.read(workbook($0, serial: 2_957_004))?.text.contains("10000-") == false
        }
    }
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("runtime/pippa-skills", isDirectory: true)
    let shipped = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    let skills = PippaSkill.load(from: folder)
    let read = { (name: String) in (try? String(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "" }

    check("Skills: Swift finds every shipped folder from the SKILL.md header, nothing is kept twice") {
        skills.map(\.name) == shipped
            && Set(shipped) == ["text-kuerzen", "dokument-einordnen", "fristen-erkennen", "antwort-schreiben", "brief-verstehen", "tabelle-pruefen", "text-verbessern", "zusammenfassen",
                                  "online-pruefen", "termin-aus-mail", "text-korrigieren", "checkliste"]
    }
    check("Skills: SKILL.md follows Pi's header rules (name like folder, lowercase with hyphens, description), explicit invocation only, short") {
        var bad: [String] = []
        for name in shipped {
            let parts = read(name).components(separatedBy: "---\n")
            guard parts.count >= 3, parts[0].isEmpty else { bad.append(name); continue }
            let head = parts[1], body = parts.dropFirst(2).joined(separator: "---\n")
            let ok = head.contains("name: \(name)\n") && PippaSkill.isValid(name: name) && head.contains("description: ")
                && head.contains("disable-model-invocation: true\n")
                && body.count <= 1300
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
        // The reader puts what code recomputed (the total "Summe") before the cells.
        return XLSXReader.read(stored.finish())?.text == expected && XLSXReader.read(packedData)?.text == expected
            && viaReader.fullText.hasSuffix("\n\n" + expected) && viaReader.fullText.hasPrefix("[Pippa hat diese Tabelle") && viaReader.problem == .none && TextReader.read(broken).problem == .damaged
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
