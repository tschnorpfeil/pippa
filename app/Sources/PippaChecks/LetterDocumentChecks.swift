import Contacts
import Foundation
import PDFKit
import PippaCore

/// "As Letter": subject from the draft, sender from My Card or yellow placeholders, a PDF with the text over pages,
/// a Word file macOS writes.
func runLetterDocumentChecks() {
    let draft = """
    Betreff: Kündigung meines Stromvertrags, Kundennummer [Kundennummer]

    Sehr geehrte Damen und Herren,

    hiermit kündige ich meinen Stromvertrag fristgerecht zum nächstmöglichen Zeitpunkt.
    Bitte bestätigen Sie mir die Kündigung schriftlich.

    Mit freundlichen Grüßen
    """
    let day = Date(timeIntervalSince1970: 1_791_676_800) // 11 Oct 2026, 00:00 UTC
    let german = Locale(identifier: "de_DE")

    check("Letter: the Betreff line becomes the subject, a short first line too; greetings stay text; bold marks go") {
        let a = LetterDocument.from(draft: draft, sender: ["Tobias Muster", "Ringstraße 1", "50667 Köln"], place: "Köln", date: day)
        let b = LetterDocument.from(draft: "Widerspruch gegen den Bescheid vom 1.10.2026\n\nSehr geehrte Damen und Herren,\n**hiermit** lege ich Widerspruch ein.", sender: nil, place: nil, date: day)
        let c = LetterDocument.from(draft: "Sehr geehrte Frau Berger,\n\ndanke für Ihre Nachricht.", sender: nil, place: nil, date: day)
        return a.subject == "Kündigung meines Stromvertrags, Kundennummer [Kundennummer]" && a.body.hasPrefix("Sehr geehrte Damen und Herren,")
            && a.dateLine(locale: german).hasPrefix("Köln, ") && a.dateLine(locale: german).contains("Oktober 2026")
            && b.subject == "Widerspruch gegen den Bescheid vom 1.10.2026" && b.body.contains("hiermit lege") && !b.body.contains("**")
            && b.sender == LetterDocument.senderPlaceholder && b.recipient == LetterDocument.recipientPlaceholder
            && c.subject == nil && c.body.hasPrefix("Sehr geehrte Frau Berger,")
    }
    check("Letter: My Card's fields become sender lines; a missing street stays a placeholder") {
        let address = CNMutablePostalAddress()
        address.street = "Ringstraße 1"; address.postalCode = "50667"; address.city = "Köln"
        let full = MeCard.lines(name: "Tobias Muster", organization: "", address: address, email: "t@example.org")
        let bare = MeCard.lines(name: "", organization: "Muster GmbH", address: nil, email: nil)
        return full.lines == ["Tobias Muster", "Ringstraße 1", "50667 Köln", "t@example.org"] && full.place == "Köln"
            && bare.lines.first == "Muster GmbH" && bare.lines.count == 3 && bare.place == nil
    }
    check("Letter: the PDF is A4 with sender, recipient, subject and text; a long text runs on to page 2; the Word file is a .docx") {
        let a = LetterDocument.from(draft: draft, sender: ["Tobias Muster", "Ringstraße 1", "50667 Köln"], place: "Köln", date: day)
        guard let pdf = PDFDocument(data: a.pdfData()), let page = pdf.page(at: 0) else { return false }
        let text = pdf.string ?? ""
        let bounds = page.bounds(for: .mediaBox)
        let a4 = abs(bounds.width - 595.3) < 1 && abs(bounds.height - 841.9) < 1
        let long = LetterDocument(sender: ["A"], recipient: ["B"], place: nil, date: day, subject: "Lang",
                                  body: Array(repeating: "Ein Satz, der den Brief lang macht und noch etwas länger.", count: 120).joined(separator: "\n"))
        let pages = PDFDocument(data: long.pdfData())?.pageCount ?? 0
        let word = (try? a.wordData()) ?? Data()
        if !text.contains("Stromvertrag") { print("  pdf text: \(text.prefix(300))") }
        let recipient = text.contains("[Empfänger]") || text.contains("[Recipient]")
        return a4 && recipient && text.contains("Tobias Muster") && text.contains("Kündigung meines Stromvertrags") && text.contains("fristgerecht")
            && pages >= 2 && word.starts(with: [0x50, 0x4B]) && a.fileName(ext: "pdf", locale: german).hasPrefix("Brief Kündigung meines Stromvertrags")
    }
}
