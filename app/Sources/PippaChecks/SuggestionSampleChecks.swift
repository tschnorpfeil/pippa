import Foundation
import PippaCore

/// What the suggestion classifier gets to read from real mail and Word formats (DocumentSuggestions.sample).
func runSuggestionSampleChecks() {
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    check("mail samples are decoded MIME, not transport headers or attachment blobs") {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let latin = root.appendingPathComponent("latin1.eml")
        let latinMail = "Received: from relay.example.invalid\r\nFrom: Verein <v@example.invalid>\r\nSubject: =?iso-8859-1?Q?R=FCckfrage?=\r\n"
            + "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
            + "Könnten Sie bitte bis Freitag die Kasse übernehmen? Viele Grüße"
        try latinMail.data(using: .isoLatin1)!.write(to: latin)
        let multipart = root.appendingPathComponent("anhang.eml")
        let blob = Data(repeating: 0x41, count: 30_000).base64EncodedString()
        let mixed = "From: Stadtwerke <s@example.invalid>\nSubject: Abschlag\nContent-Type: multipart/mixed; boundary=\"b\"\n\n"
            + "--b\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n"
            + "Ihr Abschlag betr=C3=A4gt ab November 78,00 =E2=82=AC. Bitte antworten Sie bis 25.10.\n"
            + "--b\nContent-Type: application/pdf; name=\"Plan.pdf\"\nContent-Disposition: attachment; filename=\"Plan.pdf\"\n"
            + "Content-Transfer-Encoding: base64\n\n" + blob + "\n--b--\n"
        try mixed.write(to: multipart, atomically: true, encoding: .utf8)
        let bulk = root.appendingPathComponent("newsletter.eml")
        let html = Data("<p>Nur heute 20 % auf alles im Shop, solange der Vorrat reicht.</p>".utf8).base64EncodedString()
        try ("From: Shop <n@example.invalid>\nSubject: Angebote\nList-Unsubscribe: <mailto:a@example.invalid>\n"
             + "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\n" + html + "\n").write(to: bulk, atomically: true, encoding: .utf8)
        guard let a = DocumentSuggestions.sample(for: latin), let b = DocumentSuggestions.sample(for: multipart),
              let c = DocumentSuggestions.sample(for: bulk) else { return false }
        return a.hasPrefix("From: Verein") && a.contains("Subject: Rückfrage") && a.contains("Kasse übernehmen") && !a.contains("Received")
            && b.contains("beträgt ab November 78,00 €") && b.contains("Attachments: Plan.pdf") && !b.contains("QUFB") && b.count < 400
            && c.contains("List-Unsubscribe: yes") && c.contains("Nur heute 20 % auf alles")
            && DocumentSuggestions.refined(.correspondence, url: bulk, sample: c) == .report
            && DocumentSuggestions.refined(.correspondence, url: multipart, sample: b) == .correspondence
            && DocumentSuggestions.refined(.notes, url: bulk, sample: c) == .notes
    }

    check("bulk mail without List-Unsubscribe is never a reply; real letters from generic senders stay") {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func role(_ name: String, from: String, extra: String = "", html: Bool, body: String) throws -> DocumentRole {
            let url = root.appendingPathComponent(name)
            let type = html ? "text/html" : "text/plain"
            try ("From: \(from)\nSubject: Betreff\n\(extra)Content-Type: \(type); charset=utf-8\n\n\(body)\n").write(to: url, atomically: true, encoding: .utf8)
            guard let sample = DocumentSuggestions.sample(for: url) else { return .unknown }
            return DocumentSuggestions.refined(.correspondence, url: url, sample: sample)
        }
        let text = "Hallo, nur heute sparst du bis zu 40 % auf ausgewählte Sofas und Sessel. Sichere dir jetzt dein Lieblingsstück."
        let page = "<html><body><p>Nur heute sparen Sie 40 % auf ausgewählte Sofas und Sessel. Jetzt sichern.</p></body></html>"
        let letter = "Sehr geehrte Frau Mustermann, bitte bestätigen Sie uns bis zum 31.10. den Termin. Mit freundlichen Grüßen"
        // Promotional sender names are bulk whatever the body; header signals are bulk too.
        let promoText = try role("a.eml", from: "Shop <angebote@shop.example.invalid>", html: false, body: text)
        let precedence = try role("b.eml", from: "Anna <anna@example.invalid>", extra: "Precedence: junk\n", html: false, body: text)
        let listId = try role("c.eml", from: "Anna <anna@example.invalid>", extra: "List-Id: <x.example.invalid>\n", html: false, body: text)
        let listPost = try role("d.eml", from: "Anna <anna@example.invalid>", extra: "List-Post: <mailto:x@example.invalid>\n", html: false, body: text)
        let auto = try role("e.eml", from: "Anna <anna@example.invalid>", extra: "Auto-Submitted: auto-generated\n", html: false, body: text)
        // Generic senders count only with an HTML-only body.
        let noreplyHTML = try role("f.eml", from: "noreply@shop.example.invalid", html: true, body: page)
        let infoHTML = try role("g.eml", from: "\"Shop\" <info@shop.example.invalid>", html: true, body: page)
        // Real letters: text bodies from info@/noreply@, "Auto-Submitted: no", and personal HTML mail stay correspondence.
        let infoLetter = try role("h.eml", from: "Verein <info@verein.example.invalid>", html: false, body: letter)
        let noreplyLetter = try role("i.eml", from: "noreply@amt.example.invalid", html: false, body: letter)
        let autoNo = try role("j.eml", from: "Anna <anna@example.invalid>", extra: "Auto-Submitted: no\n", html: false, body: letter)
        let personalHTML = try role("k.eml", from: "Anna <anna@example.invalid>", html: true, body: "<p>\(letter)</p>")
        return [promoText, precedence, listId, listPost, auto, noreplyHTML, infoHTML].allSatisfy { $0 == .report }
            && [infoLetter, noreplyLetter, autoNo, personalHTML].allSatisfy { $0 == .correspondence }
    }

    check("Word sample reads paragraphs from document.xml, is bounded and rejects broken files") {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(ns)><w:body>"
            + "<w:p><w:r><w:t>Sehr geehrte Frau Mustermann,</w:t></w:r></w:p>"
            + "<w:p><w:r><w:t xml:space=\"preserve\">bitte teilen Sie uns bis zum 14.10. mit, ob Sie anwesend sind. </w:t></w:r>"
            + "<w:r><w:t>Mit freundlichen Grüßen</w:t></w:r></w:p></w:body></w:document>"
        let docx = root.appendingPathComponent("brief.docx")
        try storedZip(["word/document.xml": Data(xml.utf8)]).write(to: docx)
        let broken = root.appendingPathComponent("kaputt.docx")
        try Data("PK\u{3}\u{4}not a zip".utf8).write(to: broken)
        let long = root.appendingPathComponent("lang.docx")
        let paragraphs = String(repeating: "<w:p><w:r><w:t>Ein langer Absatz für die Begrenzung der Probe.</w:t></w:r></w:p>", count: 400)
        try storedZip(["word/document.xml": Data("<w:document \(ns)><w:body>\(paragraphs)</w:body></w:document>".utf8)]).write(to: long)
        return DocumentSuggestions.sample(for: docx) == "Sehr geehrte Frau Mustermann,\nbitte teilen Sie uns bis zum 14.10. mit, ob Sie anwesend sind. Mit freundlichen Grüßen"
            && DocumentSuggestions.sample(for: broken) == nil
            && DocumentSuggestions.sample(for: long)?.count == DocumentSuggestions.sampleLimit
    }
}

/// Minimal stored (uncompressed) ZIP for Office fixtures.
func storedZip(_ entries: [String: Data]) -> Data {
    func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
    func crc(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~c
    }
    var out = Data(), central = Data()
    for (name, body) in entries.sorted(by: { $0.key < $1.key }) {
        let nameData = Data(name.utf8), sum = crc(body), offset = UInt32(out.count), size = UInt32(body.count)
        out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(sum)
        out += le32(size) + le32(size) + le16(nameData.count) + le16(0) + nameData + body
        central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(sum)
        central += le32(size) + le32(size) + le16(nameData.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameData
    }
    let start = UInt32(out.count)
    out += central
    out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(start) + le16(0)
    return out
}
