import Foundation
import PippaCore

func runProposalChecks() async {
    let file = dir("pi-plan").appendingPathComponent("Brief.txt")
    write("Brief mit Inhalt", file)
    check("Deadlines: Pi's evidence is page-bound; an invented due date does not become a calendar date") {
        let doc = DocumentText(url: file, pages: ["Bitte zahlen Sie bis zum 31.10.2026.", "Geburtstag am 02.11.2026."], isPaged: true, usedOCR: false, headers: [:])
        let json = #"{"items":[{"kind":"payment","datum":"31.10.2026","title":"Rechnung bezahlen","quote":"Bitte zahlen Sie bis zum 31.10.2026.","page":1,"note":"","sender":"","documentKind":""},{"kind":"payment","datum":"02.11.2026","title":"Unbelegte Fälligkeit","quote":"Bitte zahlen Sie bis zum 31.10.2026.","page":2,"note":"","sender":"","documentKind":""}]}"#
        let result = try JSONDecoder().decode(DeadlineAnalysis.self, from: Data(json.utf8)).verified(in: doc, today: DayDate(year: 2026, month: 10, day: 6)!)
        return result.count == 1 && result[0].date == DayDate(year: 2026, month: 10, day: 31) && result[0].location == "S. 1"
    }
    check("Deadlines: time reference required in the source quote, no prices or addresses") {
        DeadlineAnalysis.hasTemporalEvidence("Kündigung mit drei Monaten zum Monatsende")
            && DeadlineAnalysis.hasTemporalEvidence("Bitte zahlen bis 31.10.2026")
            && !DeadlineAnalysis.hasTemporalEvidence("Monatlicher Grundpreis: 29,99 EUR")
            && !DeadlineAnalysis.hasTemporalEvidence("Anna Becker, Lindenstraße 5, 88131 Lindau")
    }
    check("Deadlines: separate page marker is removed; invented content stays unverified") {
        let text = "Kündigung mit drei Monaten zum Monatsende."
        let quote = DeadlineAnalysis.sourceQuote(text + " (Seite 4, § 9)")
        return quote == text && GermanText.isVerbatim(quote, in: text)
            && !GermanText.isVerbatim(DeadlineAnalysis.sourceQuote(text + " Zusätzliche Garantie."), in: text)
    }
    check("Deadlines: computed date needs a verified base date and correct amount/unit") {
        let doc = DocumentText(url: file, pages: ["Die Mindestvertragslaufzeit endet am 28.02.2027.", "Kündigung mit einer Frist von einem Monat zum Ende der Laufzeit."], isPaged: true, usedOCR: false, headers: [:])
        let json = #"{"items":[{"kind":"cancellation","datum":"","title":"Vertrag kündigen","quote":"Kündigung mit einer Frist von einem Monat zum Ende der Laufzeit.","page":2,"note":"","sender":"","documentKind":"Vertrag","calculation":{"baseDate":"28.02.2027","baseQuote":"Die Mindestvertragslaufzeit endet am 28.02.2027.","basePage":1,"unit":"months","amount":-1}}]}"#
        func result(_ input: String) throws -> [Deadline] {
            try JSONDecoder().decode(DeadlineAnalysis.self, from: Data(input.utf8)).verified(in: doc, today: DayDate(year: 2026, month: 10, day: 6)!)
        }
        let correct = try result(json)
        let badDate = try result(json.replacingOccurrences(of: "28.02.2027", with: "27.02.2027"))
        let badAmount = try result(json.replacingOccurrences(of: #""amount":-1"#, with: #""amount":-2"#))
        return correct.first?.date == DayDate(year: 2027, month: 1, day: 28) && correct.first?.certainty == .unsure
            && badDate.first?.date == nil
            && badAmount.first?.date == nil
    }
    check("Calendar: all-day event ends at the next day's start on 23- and 25-hour days") {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let short = CalendarEntry(target: .calendar, title: "Test", date: DayDate(year: 2026, month: 3, day: 29)!, notes: "", alertDay: DayDate(year: 2026, month: 3, day: 28)!).eventInterval(in: calendar)
        let long = CalendarEntry(target: .calendar, title: "Test", date: DayDate(year: 2026, month: 10, day: 25)!, notes: "", alertDay: DayDate(year: 2026, month: 10, day: 24)!).eventInterval(in: calendar)
        return short.duration == 23 * 3600 && long.duration == 25 * 3600 && calendar.component(.hour, from: long.end) == 0
    }
}
