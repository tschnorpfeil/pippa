import AppKit
import Contacts
import Foundation

// "As Letter" under a draft: the text in a German business-letter layout (DIN 5008, form B) as a PDF to print or
// attach, or as a Word file. Plain code, no model: the sender comes from "My Card" in Contacts, the subject from the
// draft's "Betreff:" line, the date is today. What is missing stays a placeholder in [brackets], shown in yellow.

public struct LetterDocument: Sendable, Hashable {
    /// Name first, then street, postcode and town, maybe email.
    public var sender: [String]
    public var recipient: [String]
    /// Town for the date line ("Köln, 11. Oktober 2026"); nil writes the date alone.
    public var place: String?
    public var date: Date
    public var subject: String?
    public var body: String

    public init(sender: [String], recipient: [String], place: String?, date: Date, subject: String?, body: String) {
        self.sender = sender; self.recipient = recipient; self.place = place; self.date = date; self.subject = subject; self.body = body
    }

    /// Placeholders where nothing is known yet; yellow in the letter.
    public static var senderPlaceholder: [String] { [L("[Your name]", table: "Tools"), L("[Street and number]", table: "Tools"), L("[Postcode and town]", table: "Tools")] }
    public static var recipientPlaceholder: [String] { [L("[Recipient]", table: "Tools"), L("[Street and number]", table: "Tools"), L("[Postcode and town]", table: "Tools")] }

    /// A letter from a draft: an address block at the top becomes the recipient, a "Betreff:"/"Subject:" line the
    /// subject (or a short first line before the greeting), Markdown bold marks go, the rest is the text.
    public static func from(draft: String, sender: [String]?, place: String?, recipient: [String]? = nil, date: Date = Date()) -> LetterDocument {
        var lines = draft.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let address = recipient?.isEmpty == false ? nil : addressBlock(&lines)
        var subject: String?
        if let index = lines.firstIndex(where: { isSubjectLine($0) }) {
            let line = lines[index]
            subject = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
            lines.remove(at: index)
        } else if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let line = lines[first].trimmingCharacters(in: .whitespaces)
            let next = lines.indices.contains(first + 1) ? lines[first + 1].trimmingCharacters(in: .whitespaces) : ""
            if line.count <= 80, next.isEmpty, !isGreeting(line), let last = line.last, !".,!?:;".contains(last) {
                subject = line.hasPrefix("#") ? line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : line
                lines.remove(at: first)
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return LetterDocument(sender: sender?.isEmpty == false ? sender! : senderPlaceholder,
                              recipient: recipient?.isEmpty == false ? recipient! : address ?? recipientPlaceholder,
                              place: place, date: date, subject: subject?.isEmpty == true ? nil : subject, body: body)
    }

    /// One of the draft's first two blocks when it reads like an address (2 to 6 short lines, one with postcode and town,
    /// no greeting, no subject), before any greeting or subject: taken out of the lines and returned. Nil otherwise, and
    /// the lines stay. Two blocks, because a draft may open with a note line ("Hinweis: …").
    static func addressBlock(_ lines: inout [String]) -> [String]? {
        var start = 0
        for _ in 0..<2 {
            guard let first = lines[start...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            var end = first
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
            let block = lines[first..<end].map { $0.trimmingCharacters(in: .whitespaces) }
            if block.contains(where: { isGreeting($0) || isSubjectLine($0) }) { return nil }
            if (2...6).contains(block.count), block.allSatisfy({ $0.count <= 60 }),
               block.contains(where: { $0.range(of: #"^(?:[A-Z]{1,2}-)?\d{4,5}\s+\p{L}"#, options: .regularExpression) != nil }) {
                lines.removeSubrange(first..<end)
                return block
            }
            start = end
        }
        return nil
    }

    static func isSubjectLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        return (lower.hasPrefix("betreff:") || lower.hasPrefix("subject:") || lower.hasPrefix("betreff :")) && lower.count > 9
    }

    static func isGreeting(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["sehr geehrte", "hallo", "liebe", "lieber", "guten tag", "dear", "hello", "hi ", "moin", "servus"].contains { lower.hasPrefix($0) }
    }

    /// "Köln, 11. Oktober 2026" in the letter's language (German style for German).
    public func dateLine(locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .long
        f.timeStyle = .none
        let day = f.string(from: date)
        return place.map { "\($0), \(day)" } ?? day
    }

    // MARK: Layout (A4, points)

    static let mm = 72.0 / 25.4
    static let page = CGSize(width: 210 * mm, height: 297 * mm)
    static let left = 25 * mm, right = 20 * mm, bottom = 25 * mm
    static var font: NSFont { NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11) }
    static var bold: NSFont { NSFont(name: "Helvetica-Bold", size: 11) ?? .boldSystemFont(ofSize: 11) }
    static var small: NSFont { NSFont(name: "Helvetica", size: 7) ?? .systemFont(ofSize: 7) }
    static var highlight: NSColor { NSColor(srgbRed: 1, green: 0.95, blue: 0.66, alpha: 1) }

    /// Text with [placeholders] marked yellow.
    static func text(_ s: String, font: NSFont, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineHeightMultiple = 1.15
        let out = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        if let pattern = try? NSRegularExpression(pattern: #"\[[^\[\]\n]{1,60}\]"#) {
            for m in pattern.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                out.addAttribute(.backgroundColor, value: highlight, range: m.range)
            }
        }
        return out
    }

    /// The letter's parts with their place on page 1 (from the top) and the body, for PDF and Word alike.
    var parts: (header: NSAttributedString, returnLine: NSAttributedString, recipient: NSAttributedString, date: NSAttributedString,
                subject: NSAttributedString?, body: NSAttributedString) {
        let headerText = NSMutableAttributedString(attributedString: Self.text(sender.first ?? "", font: Self.bold, alignment: .right))
        if sender.count > 1 {
            headerText.append(Self.text("\n" + sender.dropFirst().joined(separator: "\n"), font: Self.font, alignment: .right))
        }
        let returnLine = Self.text(sender.prefix(3).joined(separator: " · "), font: Self.small)
        return (headerText, returnLine, Self.text(recipient.joined(separator: "\n"), font: Self.font),
                Self.text(dateLine(), font: Self.font, alignment: .right), subject.map { Self.text($0, font: Self.bold) },
                Self.text(body, font: Self.font))
    }

    /// The letter as a PDF: page 1 with letterhead, address window, date, subject; the text runs on over further pages.
    public func pdfData() -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: Self.page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let p = parts
        let width = Self.page.width - Self.left - Self.right
        let storage = NSTextStorage(attributedString: p.body)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let firstTop = (p.subject == nil ? 100 : 112) * Self.mm, nextTop = 20 * Self.mm
        var containers: [NSTextContainer] = []
        repeat {
            let top = containers.isEmpty ? firstTop : nextTop
            let container = NSTextContainer(size: CGSize(width: width, height: Self.page.height - top - Self.bottom))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 30

        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for (index, container) in containers.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: Self.page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            func draw(_ s: NSAttributedString, x: Double, top: Double, width: Double, height: Double) {
                s.draw(with: CGRect(x: x, y: top, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            if index == 0 {
                draw(p.header, x: 110 * Self.mm, top: 15 * Self.mm, width: Self.page.width - 110 * Self.mm - Self.right, height: 30 * Self.mm)
                draw(p.returnLine, x: Self.left, top: 47 * Self.mm, width: 85 * Self.mm, height: 4 * Self.mm)
                draw(p.recipient, x: Self.left, top: 52 * Self.mm, width: 85 * Self.mm, height: 38 * Self.mm)
                draw(p.date, x: 110 * Self.mm, top: 92 * Self.mm, width: Self.page.width - 110 * Self.mm - Self.right, height: 6 * Self.mm)
                if let subject = p.subject { draw(subject, x: Self.left, top: 101 * Self.mm, width: width, height: 10 * Self.mm) }
            }
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: Self.left, y: index == 0 ? firstTop : nextTop)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            if containers.count > 1 {
                let number = Self.text(L("Page %lld of %lld", table: "Tools", index + 1, containers.count), font: Self.small, alignment: .right)
                draw(number, x: Self.left, top: Self.page.height - 15 * Self.mm, width: width, height: 4 * Self.mm)
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// The same letter as a Word file (.docx), written by macOS: sender, recipient, date, subject and text one after
    /// the other, placeholders yellow. Word's own layout, no address window.
    public func wordData() throws -> Data {
        let p = parts
        let doc = NSMutableAttributedString()
        for piece in [p.header, Self.text("\n\n", font: Self.font), p.recipient, Self.text("\n\n", font: Self.font), p.date,
                      Self.text("\n\n", font: Self.font)] { doc.append(piece) }
        if let subject = p.subject { doc.append(subject); doc.append(Self.text("\n\n", font: Self.font)) }
        doc.append(p.body)
        return try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    /// File name: "Brief <subject>" or "Brief <date>", without characters a file name cannot have.
    public func fileName(ext: String, locale: Locale = .current) -> String {
        let german = locale.language.languageCode?.identifier == "de"
        let word = german ? "Brief" : "Letter"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = german ? "dd.MM.yyyy" : "yyyy-MM-dd"
        var base = Naming.sanitize(word + " " + (subject ?? f.string(from: date)), maxLength: 80)
        if base.isEmpty { base = word }
        return base + "." + ext
    }

    /// Writes the PDF (or the Word file) into a fresh results folder.
    public func write(word: Bool = false) throws -> URL {
        let folder = try ResultsFolder.fresh()
        let temp = ResultFile.temp(in: folder)
        try (word ? wordData() : pdfData()).write(to: temp, options: .atomic)
        return try ResultFile.place(temp, as: fileName(ext: word ? "docx" : "pdf"), in: folder)
    }
}

/// "My Card" in Contacts as letter sender: name, street, postcode and town, email; the town for the date line.
/// Asks for Contacts once (macOS shows the prompt); nil without permission or without a card.
public enum MeCard {
    public static func sender() async -> (lines: [String], place: String?)? {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        default: return nil
        }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                                       CNContactPostalAddressesKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return nil }
        return lines(name: [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " "), organization: me.organizationName,
                     address: me.postalAddresses.first?.value, email: me.emailAddresses.first.map { $0.value as String })
    }

    /// The lines from the card's fields; a missing part becomes a placeholder, so the letter shows what to fill in.
    public static func lines(name: String, organization: String, address: CNPostalAddress?, email: String?) -> (lines: [String], place: String?) {
        let shownName = name.isEmpty ? (organization.isEmpty ? L("[Your name]", table: "Tools") : organization) : name
        var out = [shownName]
        if let address, !address.street.isEmpty || !address.city.isEmpty {
            out.append(address.street.isEmpty ? L("[Street and number]", table: "Tools") : address.street.replacingOccurrences(of: "\n", with: ", "))
            let town = [address.postalCode, address.city].filter { !$0.isEmpty }.joined(separator: " ")
            out.append(town.isEmpty ? L("[Postcode and town]", table: "Tools") : town)
        } else {
            out += [L("[Street and number]", table: "Tools"), L("[Postcode and town]", table: "Tools")]
        }
        if let email, !email.isEmpty { out.append(email) }
        return (out, address?.city.isEmpty == false ? address?.city : nil)
    }
}
