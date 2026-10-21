import Foundation
import PippaCore

/// Invoices as a spreadsheet in code: total, date, currency and sender from receipt and invoice texts, what code is
/// unsure about, the model only pointing at an amount code found, the .xlsx with a total per currency, and the button.
func runInvoiceChecks() async {
    let receipt = """
    REWE Markt GmbH
    Hauptstr. 5
    50667 Köln
    BROT                 2,49
    MILCH                1,19
    SUMME EUR            3,68
    Geg. BAR             5,00
    Rückgeld             1,32
    MwSt 7%  Netto 3,44  MwSt 0,24
    Datum 03.02.2026 12:31
    """
    let invoice = """
    Stadtwerke Musterstadt GmbH
    Rechnung Nr. 2026-0042
    Rechnungsdatum: 15.03.2026
    Fällig am: 30.03.2026
    Strom Grundpreis   12,50 €
    Arbeitspreis 84,20 €
    Nettobetrag 81,26 €
    zzgl. 19 % USt 15,44 €
    Gesamtbetrag 96,70 €
    """
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

    check("Invoices: a receipt's total comes from the SUMME line, never cash given, change or VAT; date and sender found") {
        let r = InvoiceReader.read(file: "Bon.jpg", text: receipt)
        if r.amount != 3.68 { print("  receipt: \(r)") }
        return r.amount == 3.68 && !r.unsure.contains(.amount) && r.date == day(2026, 2, 3) && !r.unsure.contains(.date)
            && r.currency == "EUR" && r.sender == "REWE Markt" && r.evidence?.contains("SUMME") == true
    }
    check("Invoices: an invoice's total is the gross amount, the date the invoice date (not the due date)") {
        let r = InvoiceReader.read(file: "Strom.pdf", text: invoice)
        if r.amount != 96.7 { print("  invoice: \(r)") }
        return r.amount == 96.7 && !r.unsure.contains(.amount) && r.date == day(2026, 3, 15) && !r.unsure.contains(.date)
            && r.sender == "Stadtwerke Musterstadt" && r.currency == "EUR"
    }
    check("Invoices: two totals that disagree stay yellow; the model may only point at an amount code found; a sender must be in the text") {
        let text = "Bäckerei\nSumme 50,00\nGesamt 45,00\n"
        let r = InvoiceReader.read(file: "x.pdf", text: text)
        let other = InvoiceReader.choose(r, amount: "45,00", sender: "Bäckerei Schmidt", text: text)
        let same = InvoiceReader.choose(r, amount: "50,00", sender: "bäckerei", text: text)
        let invented = InvoiceReader.choose(r, amount: "47,00", sender: nil, text: text)
        let none = InvoiceReader.read(file: "Notiz.txt", text: "Einkaufen: Brot, Milch\nAnrufen 03.02.2026")
        return r.unsure.contains(.amount) && r.amount == 50 && other.amount == 45 && other.unsure.contains(.amount) && other.sender == r.sender
            && same.amount == 50 && !same.unsure.contains(.amount) && same.sender == "bäckerei" && !same.unsure.contains(.sender)
            && invented.amount == 50 && invented.unsure.contains(.amount) && none.amount == nil
    }
    check("Invoices: \"inkl. MwSt\" totals, English thousands, a total on the next line, the invoice date first, codes as words") {
        let gross = InvoiceReader.read(file: "a.pdf", text: "Hotel Sonne\nBeratung 100,00 €\nNetto 100,00 €\nMwSt 19 % 19,00 €\nGesamtbetrag inkl. MwSt. 119,00 €")
        let english = InvoiceReader.read(file: "b.pdf", text: "Acme Inc.\nInvoice date: 2026-10-01\nSubtotal $1,120.00\nTax $114.00\nTotal due $1,234.56")
        let split = InvoiceReader.read(file: "c.pdf", text: "Friseur Haarwerk\nAbschlag Betrag 85,00\nGesamtbetrag\n96,70 €")
        let amazon = InvoiceReader.read(file: "d.pdf", text: "Bestelldatum 01.10.2026\nRechnungsdatum/Lieferdatum 05.10.2026\nZahlbetrag 19,99 €")
        let usd = InvoiceReader.read(file: "e.pdf", text: "Friseur Studio\nAmount due 40.00\nAll amounts in USD")
        let sure = InvoiceReader.choose(split, amount: "85,00", sender: nil, text: "")
        if gross.amount != 119 || english.amount != 1234.56 || split.amount != 96.7 { print("  \(gross.amount ?? -1) \(english.amount ?? -1) \(split.amount ?? -1)") }
        return gross.amount == 119 && !gross.unsure.contains(.amount) && gross.sender == "Hotel Sonne"
            && english.amount == 1234.56 && english.currency == "USD" && english.date == day(2026, 10, 1)
            && split.amount == 96.7 && split.currency == "EUR"
            && amazon.date == day(2026, 10, 5) && usd.currency == "USD" && sure.amount == 96.7 && !sure.unsure.contains(.amount)
    }
    check("Invoices: the sheet has one row per invoice by date, unsure cells yellow, a total per currency as a formula") {
        let rows = [
            InvoiceRow(file: "b.pdf", sender: "B", date: day(2026, 3, 1), amount: 10, currency: "EUR"),
            InvoiceRow(file: "a.pdf", sender: "A", date: day(2026, 1, 1), amount: 5.5, currency: "EUR", unsure: [.amount]),
            InvoiceRow(file: "c.pdf", sender: nil, date: nil, amount: 20, currency: "CHF"),
        ]
        let sheet = InvoiceTable.sheet(rows)
        guard let back = XLSXReader.workbook(XLSXWriter.data([sheet]))?.sheets.first?.grid else { return false }
        let order = back[2, 5].value == .text("a.pdf") && back[3, 5].value == .text("b.pdf") && back[4, 5].value == .text("c.pdf")
        let yellow = sheet.rows[1][2].highlight && !sheet.rows[2][2].highlight && sheet.rows[3][1].highlight && sheet.rows[3][0].highlight
        let totals = back[6, 3].formula == "=SUMIF(D2:D4,\"EUR\",C2:C4)" && back[6, 3].value == .number(15.5)
            && back[7, 3].value == .number(20) && back[7, 4].value == .text("CHF")
        let single = InvoiceTable.sheet(Array(rows.prefix(2)))
        if !order || !yellow || !totals { print("  sheet: \(back)") }
        return order && yellow && totals && single.rows.last?[2].formula == "SUM(C2:C3)"
    }
    await checkAsync("Invoices: the tool reads text files, writes one .xlsx into the results folder, leaves the invoices, skips a note with a reason") {
        let folder = dir("invoices")
        let a = folder.appendingPathComponent("Rechnung Strom.txt"), b = folder.appendingPathComponent("Bon REWE.txt")
        let note = folder.appendingPathComponent("Notiz.txt")
        write(invoice, a); write(receipt, b); write("Einkaufen: Brot, Milch und Butter", note)
        do {
            let output = try await OneAnswerTools.run(.invoiceTable, inputs: [a, b, note])
            guard let file = output.files.first, let data = try? Data(contentsOf: file),
                  let grid = XLSXReader.workbook(data)?.sheets.first?.grid else { return false }
            return output.files.count == 1 && file.pathExtension == "xlsx" && ResultsFolder.contains(file) && output.consumedInputs.isEmpty
                && output.skipped.map(\.name) == ["Notiz.txt"] && grid[2, 3].value == .number(3.68) && grid[3, 3].value == .number(96.7)
                && FileManager.default.fileExists(atPath: a.path) && OneAnswerTools.accepts(.invoiceTable, a)
                && !OneAnswerTools.accepts(.invoiceTable, folder.appendingPathComponent("Film.mov"))
        } catch {
            print("  tool: \(error)")
            return false
        }
    }
    check("Invoices: the button comes first for receipts and invoices by name or kind, not for other PDFs") {
        func ids(_ names: [String], role: DocumentRole = .unknown) -> [String] {
            ThingActions.candidates(for: names.map { URL(fileURLWithPath: "/x/" + $0) }, size: { _ in 0 }, skills: [], role: role).map(\.id)
        }
        return ids(["Rechnung Januar.pdf", "Rechnung Februar.pdf"]).first == "invoice-table"
            && ids(["Bon 1.jpg", "Bon 2.jpg"]).first == "invoice-table"
            && !ids(["Seite 1.pdf", "Seite 2.pdf"]).contains("invoice-table")
            && ids(["Scan.pdf"], role: .invoice) == ["invoice-table", "extract-text"] && ids(["Scan.pdf"]) == ["extract-text"]
    }
}
