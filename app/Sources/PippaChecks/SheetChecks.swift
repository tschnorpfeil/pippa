import Foundation
import PippaCore

/// Sheet: "Check the total" as pure code over grids built by hand here (German and English, SUMME and SUM,
/// omitted row, number stored as text, everything fine), plus reading from Excel without Excel (area selection,
/// Apple Event values) and that no script writes to a sheet.
func runSheetChecks() async {
    let english = Locale(identifier: "en_US")
    func t(_ s: String) -> SheetCell { SheetCell(.text(s)) }
    func n(_ v: Double) -> SheetCell { SheetCell(.number(v)) }
    func f(_ formula: String, _ v: Double) -> SheetCell { SheetCell(.number(v), formula: formula) }
    func grid(_ rows: [[SheetCell]]) -> SheetGrid { SheetGrid(origin: CellRef(row: 1, column: 1), rows: rows) }
    func sheet(_ key: String) -> String { L(key, table: "Sheet") }
    /// No sentence names a cell address ("B5", "F11").
    func noAddress(_ text: String) -> Bool { text.range(of: #"\b[A-Z]{1,3}[0-9]{1,7}\b"#, options: .regularExpression) == nil }

    // MARK: Numbers and addresses

    check("Sheet: numbers from text, German and English; a date and a phone number are not numbers") {
        let numbers: [(String, Double)] = [("24,50", 24.5), ("1.234,56 €", 1234.56), ("1,234.56", 1234.56), ("-3", -3), ("12", 12),
                                           ("12.500", 12500)]
        let parsed = numbers.allSatisfy { SheetNumber.parse($0.0) == $0.1 }
        let notNumbers = ["01.10.2026", "0171 1234567", "Miete", "Zeile 12"].allSatisfy { SheetNumber.parse($0) == nil }
        return parsed && notNumbers
    }
    check("Sheet: addresses as Excel delivers them") {
        let a = CellArea(a1: "$F$2:$F$10"), b = CellArea(a1: "'Kosten 2026'!B3"), c = CellArea(a1: "A1:B2,D4"), d = CellArea(a1: "F:F")
        let plain = a == CellArea(top: 2, left: 6, bottom: 10, right: 6) && b?.a1 == "B3" && c?.a1 == "A1:B2"
        let column = d?.top == 1 && d?.bottom == CellArea.maxRow && d?.left == 6
        let names = CellRef(a1: "AA12")?.column == 27 && CellRef.columnName(28) == "AB" && CellArea(a1: "Miete") == nil
        return plain && column && names
    }
    check("Sheet: formulas that only add") {
        let summe = SumFormula.parse("=SUMME(B2:B4)")?.areas == [CellArea(a1: "B2:B4")!]
        let sum = SumFormula.parse("=sum($F$2:$F$10)")?.kind == .sum && SumFormula.parse("=SUM(B2:B4;B6)")?.areas.count == 2
        let other = SumFormula.parse("=SUBTOTAL(9,C2:C9)")?.kind == .subtotal
            && SumFormula.parse("=TEILERGEBNIS(109;C2:C9)")?.kind == .subtotal
            && SumFormula.parse("=B2+B3+B4")?.kind == .plus
        let rejected = ["=B2*B3", "=SUM(Sheet2!B2:B4)", "=AVERAGE(B2:B4)", "=SUBTOTAL(1,C2:C9)", "=SUMIF(A2:A9,\"x\",B2:B9)"]
            .allSatisfy { SumFormula.parse($0) == nil }
        return summe && sum && other && rejected
    }

    // MARK: Check the total

    check("Sheet: duplicate references and overlapping SUM ranges count every occurrence") {
        let formulas: [(String, Double)] = [("=B2+B2+B3", 40), ("=SUM(B2:B3,B2)", 40), ("=SUM(B2:B3,B2:B3)", 60)]
        return formulas.allSatisfy { formula, expected in
            let g = grid([[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), n(20)], [t("Total"), f(formula, expected)]])
            let r = SheetCheck.run(g, locale: english)
            return r.allFine && r.totals.first?.recomputed == expected && r.firstLine.text == sheet("The total adds up.")
        }
    }
    check("Sheet: a duplicate reference exposes a wrong stored total") {
        let g = grid([[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), n(20)], [t("Total"), f("=SUM(B2:B3,B2)", 30)]])
        let r = SheetCheck.run(g, locale: english)
        return !r.allFine && r.findings.map(\.kind) == [.mismatch] && r.findings.first?.expected == 40
    }
    check("Sheet: a total reaching outside the area read is explicitly unverified") {
        let g = grid([[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), n(20)], [t("Total"), f("=SUM(B2:B100)", 999)]])
        let r = SheetCheck.run(g, locale: english)
        return r.foundTotals && !r.allFine && r.totals.first?.recomputed == nil && r.findings.map(\.kind) == [.unverified]
            && r.firstLine.text == sheet("I couldn’t fully check this total.") && r.firstLine.pleaseCheck
            && r.findings.first?.sentence.contains("outside") == true && noAddress(r.firstLine.text)
    }
    check("Sheet: an error value in the total or its numbers gets no success message") {
        let rows: [[[SheetCell]]] = [
            [[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), n(20)], [t("Total"), SheetCell(.text("#VALUE!"), formula: "=SUM(B2:B3)")]],
            [[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), t("#DIV/0!")], [t("Total"), f("=SUM(B2:B3)", 10)]],
            [[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), t("invalid")], [t("Total"), f("=B2+B3", 10)]],
        ]
        return rows.allSatisfy { rows in
            let r = SheetCheck.run(grid(rows), locale: english)
            return !r.allFine && r.findings.map(\.kind) == [.unverified] && r.totals.first?.recomputed == nil
                && r.firstLine.text == sheet("I couldn’t fully check this total.")
        }
    }
    check("Sheet: SUBTOTAL stays unverified without visibility data, also when it contains subtotals") {
        return ["=SUBTOTAL(9,B2:B4)", "=SUBTOTAL(109,B2:B4)", "=TEILERGEBNIS(109;B2:B4)"].allSatisfy { formula in
            let g = grid([[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), n(20)],
                          [t("Subtotal"), f("=SUBTOTAL(9,B2:B3)", 30)], [t("Total"), f(formula, 30)]])
            let r = SheetCheck.run(g, locale: english)
            return r.totals.count == 2 && !r.allFine && r.findings.count == 2
                && r.findings.allSatisfy { $0.kind == .unverified && $0.expected == nil }
                && r.totals.allSatisfy { $0.recomputed == nil }
        }
    }
    check("Sheet: a typed total with an error value above it also stays unverified") {
        let g = grid([[t("Item"), t("Amount")], [t("Rent"), n(10)], [t("Power"), t("#VALUE!")], [t("Total"), n(10)]])
        let r = SheetCheck.run(g, locale: english)
        return !r.allFine && r.findings.map(\.kind) == [.unverified] && r.totals.first?.recomputed == nil
    }
    check("Sheet: a verified total does not turn a second unverified one green") {
        let g = grid([[t("Item"), t("Net"), t("Gross")], [t("Rent"), n(10), n(12)], [t("Power"), n(20), n(24)],
                      [t("Total"), f("=SUM(B2:B3)", 30), f("=SUM(C2:C100)", 36)]])
        let r = SheetCheck.run(g, locale: english)
        return r.totals.count == 2 && r.totals.first?.recomputed == 30 && !r.allFine
            && r.findings.map(\.kind) == [.unverified] && r.firstLine.text == sheet("I couldn’t fully check this total.")
    }

    check("Sheet: SUMME leaves out the last row; sentence names \"Wasser\" and \"Betrag\", no address") {
        let g = grid([
            [t("Posten"), t("Betrag")],
            [t("Miete"), n(950)],
            [t("Strom"), n(84.2)],
            [t("Internet"), n(39.99)],
            [t("Wasser"), n(36.5)],
            [t("Summe"), f("=SUMME(B2:B4)", 1074.19)],
        ])
        let r = SheetCheck.run(g, locale: english)
        guard let finding = r.findings.first, r.findings.count == 1 else { return false }
        let layoutOK = r.layout.headerRow == 1 && r.layout.labelColumn == 1
        let cellsOK = finding.kind == .missingRows && finding.cells == [CellRef(row: 5, column: 2)] && finding.addresses == ["B5"]
        let sentence = finding.sentence
        let sentenceOK = sentence.contains("Wasser") && sentence.contains("Betrag") && sentence.contains("1,110.69") && noAddress(sentence)
        let expectedOK = abs((finding.expected ?? 0) - 1110.69) < 0.001
        let lineOK = r.firstLine.text == sheet("This total leaves out one row.") && noAddress(r.firstLine.text)
        let recomputed: Double = r.totals.first?.recomputed ?? -1
        let totalOK = r.totals.first?.name == "Betrag" && abs(recomputed - 1074.19) < 0.001
        return layoutOK && cellsOK && sentenceOK && expectedOK && lineOK && totalOK
    }
    check("Sheet: SUM over all rows, English headings: \"The total adds up.\"") {
        let g = grid([
            [t("Item"), t("Amount")],
            [t("Rent"), n(1200)],
            [t("Power"), n(90.5)],
            [t("Water"), n(30)],
            [t("Total"), f("=SUM(B2:B4)", 1320.5)],
        ])
        let r = SheetCheck.run(g, locale: english)
        return r.allFine && r.totals.count == 1 && r.firstLine.text == sheet("The total adds up.")
    }
    check("Sheet: total starts one row too late (first row missing)") {
        let g = grid([
            [t("Monat"), t("Kosten")],
            [t("Januar"), n(100)],
            [t("Februar"), n(200)],
            [t("März"), n(300)],
            [t("Gesamt"), f("=SUM(B3:B4)", 500)],
        ])
        let r = SheetCheck.run(g, locale: english)
        return r.findings.map(\.kind) == [.missingRows] && r.findings.first?.cells == [CellRef(row: 2, column: 2)]
            && r.findings.first?.sentence.contains("Januar") == true
    }
    check("Sheet: a number stored as text is skipped by SUMME and named by row and column") {
        let g = grid([
            [t("Posten"), t("Betrag")],
            [t("Miete"), n(950)],
            [t("Taxi"), t("24,50")],
            [t("Strom"), n(84.2)],
            [t("Summe"), f("=SUMME(B2:B4)", 1034.2)],
        ])
        let r = SheetCheck.run(g, locale: english)
        guard let finding = r.findings.first, r.findings.count == 1 else { return false }
        return finding.kind == .textNumber && finding.cells == [CellRef(row: 3, column: 2)] && finding.expected == 24.5
            && finding.sentence.contains("Taxi") && finding.sentence.contains("Betrag") && noAddress(finding.sentence)
            && r.firstLine.text == sheet("One number here is stored as text.")
    }
    check("Sheet: typed total in the \"Total\" row does not match") {
        let g = grid([
            [t("Item"), t("Amount")],
            [t("Rent"), n(1200)],
            [t("Power"), n(90)],
            [t("Water"), n(30)],
            [t("Total"), n(1300)],
        ])
        let r = SheetCheck.run(g, locale: english)
        guard let finding = r.findings.first, r.findings.count == 1 else { return false }
        return finding.kind == .mismatch && finding.expected == 1320 && finding.sentence.contains("1,300") && finding.sentence.contains("1,320")
            && r.totals.first?.source == .labelledRow && r.firstLine.text == sheet("This total doesn’t match its numbers.")
    }
    check("Sheet: typed subtotals and grand total add up, no false report") {
        let g = grid([
            [t("Posten"), t("Betrag")],
            [t("Brot"), n(10)],
            [t("Milch"), n(20)],
            [t("Zwischensumme"), n(30)],
            [t("Kaffee"), n(5)],
            [t("Tee"), n(5)],
            [t("Zwischensumme"), n(10)],
            [t("Gesamt"), n(40)],
        ])
        let r = SheetCheck.run(g, locale: english)
        return r.totals.count == 3 && r.findings.isEmpty && r.firstLine.text == sheet("The totals add up.")
    }
    check("Sheet: total along a row, no finding") {
        let g = grid([
            [t("Posten"), t("Jan"), t("Feb"), t("Summe")],
            [t("Miete"), n(950), n(950), f("=SUM(B2:C2)", 1900)],
            [t("Strom"), n(80), n(90), f("=B3+C3", 170)],
        ])
        let r = SheetCheck.run(g, locale: english)
        return r.totals.count == 2 && r.allFine && r.totals.first?.name == "Miete"
    }
    check("Sheet: two totals, one leaves out a row: first line names the column") {
        let g = grid([
            [t("Posten"), t("Netto"), t("Brutto")],
            [t("Miete"), n(100), n(119)],
            [t("Strom"), n(200), n(238)],
            [t("Summe"), f("=SUM(B2:B3)", 300), f("=SUM(C2:C2)", 119)],
        ])
        let r = SheetCheck.run(g, locale: english)
        let expected = L("The total for “%@” leaves out one row.", table: "Sheet", "Brutto")
        return r.findings.map(\.kind) == [.missingRows] && r.firstLine.text == expected
    }
    check("Sheet: without a total: \"I didn’t find a total here.\"") {
        let g = grid([[t("Posten"), t("Betrag")], [t("Miete"), n(950)], [t("Strom"), n(84)]])
        let r = SheetCheck.run(g, locale: english)
        return !r.foundTotals && r.findings.isEmpty && r.firstLine.text == sheet("I didn’t find a total here.")
    }
    check("Sheet: selection narrows down to its total") {
        let g = grid([
            [t("Posten"), t("Netto"), t("Brutto")],
            [t("Miete"), n(100), n(119)],
            [t("Strom"), n(200), n(238)],
            [t("Summe"), f("=SUM(B2:B3)", 300), f("=SUM(C2:C2)", 119)],
        ])
        let r = SheetCheck.run(g, focus: CellArea(a1: "B2:B4"), locale: english)
        return r.totals.count == 1 && r.allFine
    }

    // MARK: Compare with last year

    check("Sheet: last year only with two comparable columns") {
        let years = grid([
            [t("Posten"), n(2025), n(2026)],
            [t("Miete"), n(900), n(950)],
            [t("Strom"), n(70), n(84)],
            [t("Summe"), f("=SUM(B2:B3)", 970), f("=SUM(C2:C3)", 1034)],
        ])
        let previous = grid([
            [t("Posten"), t("Aktuell"), t("Vorjahr")],
            [t("Miete"), n(950), n(900)],
            [t("Strom"), n(84), n(70)],
        ])
        let single = grid([[t("Posten"), t("Betrag")], [t("Miete"), n(950)], [t("Strom"), n(84)]])
        guard let c = SheetComparison.find(in: years), let p = SheetComparison.find(in: previous) else { return false }
        let line = c.line(locale: english)
        return c.currentHeading == "2026" && c.previousHeading == "2025" && c.changes.count == 2
            && c.biggestChange?.label == "Miete" && line.contains("Miete") && noAddress(line)
            && p.currentColumn == 2 && p.previousColumn == 3 && SheetComparison.find(in: single) == nil
            && SheetCheck.run(years, locale: english).allFine
    }

    // MARK: Reading from Excel (without Excel)

    check("Excel: a single cell reads the used range, a whole column is trimmed, at most 4000 cells") {
        let used = CellArea(a1: "A1:D20")
        let single = ExcelScript.readArea(selection: CellArea(a1: "B3"), used: used)
        let column = ExcelScript.readArea(selection: CellArea(a1: "D:D"), used: used)
        let big = ExcelScript.readArea(selection: CellArea(a1: "C5"), used: CellArea(a1: "A1:Z1000"))
        let wide = ExcelScript.readArea(selection: CellArea(a1: "A1:Z1000"), used: CellArea(a1: "A1:Z1000"))
        let singleOK = single?.area.a1 == "A1:D20" && single?.clipped == false
        let columnOK = column?.area.a1 == "A1:D20" && column?.clipped == false
        let bigCells: Int = big?.area.cellCount ?? Int.max
        let wideCells: Int = wide?.area.cellCount ?? Int.max
        let bigOK = big?.area.a1 == "A1:Z153" && big?.clipped == true && bigCells <= ExcelScript.maxCells
        let nothing = ExcelScript.readArea(selection: nil, used: nil) == nil
        return singleOK && columnOK && bigOK && wideCells <= ExcelScript.maxCells && nothing
    }
    check("Excel: selection is extended by headings, labels and the total row") {
        let r = ExcelScript.readArea(selection: CellArea(a1: "B2:B4"), used: CellArea(a1: "A1:C6"))
        return r?.area.a1 == "A1:B6" && r?.clipped == false
    }
    check("Excel: values and formulas from Apple Event lists; an error value is not a number") {
        func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let l = NSAppleEventDescriptor.list()
            for (i, item) in items.enumerated() { l.insert(item, at: i + 1) }
            return l
        }
        let s = NSAppleEventDescriptor.init(string:)
        let values = list([list([s("Posten"), s("Betrag")]), list([s("Miete"), NSAppleEventDescriptor(double: 950)]),
                           list([s("Summe"), NSAppleEventDescriptor(double: -2146826281)])])
        let formulas = list([list([s("Posten"), s("Betrag")]), list([s("Miete"), s("950")]), list([s("Summe"), s("=SUM(B2:B2)/0")])])
        let g = ExcelScript.grid(values: values, formulas: formulas, area: CellArea(a1: "A1:B3")!)
        let single = ExcelScript.grid(values: NSAppleEventDescriptor(double: 7), formulas: s("=3+4"), area: CellArea(a1: "C9")!)
        let shape = g.rowCount == 3 && g.columnCount == 2 && g[1, 1].value.label == "Posten"
        let typed = g[2, 2].value == SheetValue.number(950) && g[2, 2].formula == nil
        let error = g[3, 2].formula == "=SUM(B2:B2)/0" && g[3, 2].value.number == nil
        let one = single.origin == CellRef(row: 9, column: 3) && single[9, 3].value == SheetValue.number(7) && single[9, 3].formula == "=3+4"
        return shape && typed && error && one && ExcelScript.value(s("")) == SheetValue.empty
    }
    check("Excel: no script writes to a sheet or sends anything") {
        guard let excel = IntegrationScripts.sources.first(where: { $0.name == "Excel" })?.source else { return false }
        let write = #"(?i)\bset\s+(value|formula|content|name|selection)\b|\b(save|clear|delete|insert|paste|calculate|send|make|close)\b"#
        let readsBoth = excel.contains("value of r") && excel.contains("formula of r") && excel.contains("used range")
        return excel.range(of: write, options: .regularExpression) == nil && readsBoth
            && IntegrationScripts.thirdPartyApps["Excel"] == ExcelScript.bundleIdentifier
            && ExcelScript.bundleIdentifier == "com.microsoft.Excel"
    }
    await checkAsync("Excel: stand-in asks first, then delivers \"Kosten 2026\" with the omitted row \"Wasser\"") {
        let reader = DemoSheetReader()
        let denied = (try? await reader.selectedSheet()) == nil
        _ = await reader.requestSheetAccess()
        guard let snapshot = try await reader.selectedSheet() else { return false }
        let r = SheetCheck.run(snapshot, locale: english)
        let calling = SheetLine.calling(snapshot)
        let findingOK = r.findings.first?.kind == .missingRows && r.findings.first?.sentence.contains("Wasser") == true
        let callingOK = calling.contains("Kosten 2026") && calling.contains("Betrag") && !calling.contains(".xlsx") && noAddress(calling)
        return denied && snapshot.tableName == "Kosten 2026" && findingOK && callingOK && snapshot.contextText().contains("=SUM(B2:B4)")
    }
    await checkAsync("Excel via the engine: sample engine asks first and then reads; check engine never touches Excel") {
        let stub = StubEngine(delay: 0)
        let askedFirst = await stub.sheetAccess() == .notDetermined
        let deniedBefore = (try? await stub.selectedSheet()) == nil
        let granted = await stub.requestSheetAccess() == .granted
        let read = try await stub.selectedSheet()
        // With stand-in integrations LocalEngine does not read real Excel: stand-in without a sheet, never the system prompt.
        let local = LocalEngine(baseDirectory: dir("support-sheet"), modelEnabled: false, integrations: DemoIntegrations())
        let localAccess = await local.sheetAccess()
        let localSheet = try? await local.selectedSheet()
        let given = LocalEngine(baseDirectory: dir("support-sheet-given"), modelEnabled: false, integrations: DemoIntegrations(),
                                sheets: DemoSheetReader(granted: true))
        let givenSheet = try await given.selectedSheet()
        let stubOK = askedFirst && deniedBefore && granted && read?.tableName == "Kosten 2026"
        let localOK = localAccess == .notDetermined && localSheet == nil && givenSheet?.sheet == "2026"
        return stubOK && localOK
    }
    check("Sheet: checking 4000 cells stays under one second") {
        var rows: [[SheetCell]] = [[t("Posten"), t("A"), t("B"), t("C")]]
        for i in 2..<1000 { rows.append([t("Zeile \(i)"), n(Double(i)), n(1), n(2)]) }
        let total = Double((2..<1000).reduce(0, +))
        rows.append([t("Summe"), f("=SUM(B2:B999)", total), f("=SUM(C2:C998)", 997), n(1996)])
        let start = Date()
        let r = SheetCheck.run(grid(rows), locale: english)
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= 1 { print("  \(elapsed) s") }
        return elapsed < 1 && r.findings.map(\.kind) == [.missingRows] && r.totals.count == 3
    }
}
