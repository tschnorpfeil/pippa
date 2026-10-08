import Foundation

/// A calendar date without time of day.
public struct DayDate: Sendable, Hashable, Comparable, Codable {
    public var year: Int, month: Int, day: Int
    public init?(year: Int, month: Int, day: Int) {
        guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: c), cal.component(.day, from: date) == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }
    public init(_ date: Date) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        year = c.year ?? 1970; month = c.month ?? 1; day = c.day ?? 1
    }
    /// DD.MM.YYYY
    public var german: String { String(format: "%02d.%02d.%04d", day, month, year) }
    /// YYYY-MM
    public var yearMonth: String { String(format: "%04d-%02d", year, month) }
    /// YYYY-MM-DD
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (a: DayDate, b: DayDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    /// Days since 30.12.1899 (Excel serial number).
    public var excelSerial: Int {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var base = DateComponents(); base.year = 1899; base.month = 12; base.day = 30; base.hour = 12
        return cal.dateComponents([.day], from: cal.date(from: base)!, to: cal.date(from: c)!).day ?? 0
    }
}

public struct TextMatch<Value: Sendable>: Sendable {
    public var value: Value
    public var range: Range<String.Index>
    public var text: String
}

/// German patterns: date, amount, IBAN, keywords. No model, deterministic.
public enum GermanText {
    /// Lowercase, umlauts spelled out ("Prüfung" → "pruefung"). For comparisons (source verification).
    static func fold(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    static let months: [String: Int] = [
        "januar": 1, "jan": 1, "jänner": 1, "februar": 2, "feb": 2, "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "april": 4, "apr": 4, "mai": 5, "juni": 6, "jun": 6, "juli": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "november": 11, "nov": 11, "dezember": 12, "dez": 12,
    ]

    static let numericDate = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?![\d])"#)
    static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    static let wordDate = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})\.?\s+(Januar|Jänner|Februar|März|Maerz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|Jan|Feb|Mär|Mrz|Apr|Jun|Jul|Aug|Sept|Sep|Okt|Nov|Dez)\.?\s+(\d{4})(?!\d)"#,
        options: [.caseInsensitive])
    static let amountNumber = try! NSRegularExpression(pattern: #"(?<![\d.,])-?(\d{1,3}(?:[.\x{202F}\x{00A0} ]\d{3})+|\d+),(\d{2})(?![\d,])"#)
    static let iban = try! NSRegularExpression(pattern: #"\b([A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?)\b"#)

    static func ns(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    /// All dates in the text, in order.
    public static func dates(in text: String) -> [TextMatch<DayDate>] {
        var out: [TextMatch<DayDate>] = []
        for m in numericDate.matches(in: text, range: ns(text)) {
            guard let r = Range(m.range, in: text),
                  let d = Int(text[Range(m.range(at: 1), in: text)!]), let mo = Int(text[Range(m.range(at: 2), in: text)!]),
                  var y = Int(text[Range(m.range(at: 3), in: text)!]) else { continue }
            if y < 100 { y += y < 70 ? 2000 : 1900 }
            if let date = DayDate(year: y, month: mo, day: d) { out.append(TextMatch(value: date, range: r, text: String(text[r]))) }
        }
        for m in isoDate.matches(in: text, range: ns(text)) {
            guard let r = Range(m.range, in: text),
                  let y = Int(text[Range(m.range(at: 1), in: text)!]), let mo = Int(text[Range(m.range(at: 2), in: text)!]),
                  let d = Int(text[Range(m.range(at: 3), in: text)!]), let date = DayDate(year: y, month: mo, day: d) else { continue }
            out.append(TextMatch(value: date, range: r, text: String(text[r])))
        }
        for m in wordDate.matches(in: text, range: ns(text)) {
            guard let r = Range(m.range, in: text),
                  let d = Int(text[Range(m.range(at: 1), in: text)!]),
                  let mo = months[text[Range(m.range(at: 2), in: text)!].lowercased()],
                  let y = Int(text[Range(m.range(at: 3), in: text)!]), let date = DayDate(year: y, month: mo, day: d) else { continue }
            out.append(TextMatch(value: date, range: r, text: String(text[r])))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// A single date such as "12.03.2026", "12. März 2026" or "2026-03-12".
    public static func parseDate(_ text: String) -> DayDate? { dates(in: text).first?.value }

    /// All amounts in German format (1.234,56) in the text.
    public static func amounts(in text: String) -> [TextMatch<Decimal>] {
        amountNumber.matches(in: text, range: ns(text)).compactMap { m in
            guard let r = Range(m.range, in: text), let value = parseAmount(String(text[r])) else { return nil }
            return TextMatch(value: value, range: r, text: String(text[r]))
        }
    }

    /// "1.234,56 €", "EUR 84,20", "84,20", "-5,00" → Decimal. Period as decimal separator only without a comma and with exactly 2 decimal places.
    public static func parseAmount(_ raw: String) -> Decimal? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["€", "EUR", "Euro", "eur"] { s = s.replacingOccurrences(of: token, with: "") }
        s = s.filter { !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" }
        guard !s.isEmpty else { return nil }
        if s.contains(",") {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) == 3, s.filter({ $0 == "." }).count == 1 {
            // 84.20 (English notation) stays
        } else {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard s.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// 1234.5 → "1.234,50 €"
    public static func formatAmount(_ value: Decimal, currency: Bool = true) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        let s = f.string(from: value as NSDecimalNumber) ?? "\(value)"
        return currency ? s + " €" : s
    }

    public static func ibans(in text: String) -> [String] {
        iban.matches(in: text, range: ns(text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Lowercase, uniform quotation marks and dashes, whitespace collapsed.
    /// Ligatures ("ﬁ") and special forms are resolved (NFKC). Hyphens between letters are dropped, also with
    /// whitespace or a line break after them, so "Kündigungs-\nfrist", "Kündigungs- frist" and "Kündigungsfrist" are the
    /// same. Applied to quote and source alike, so the check stays verbatim apart from layout.
    public static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00AD}", with: "").precomposedStringWithCompatibilityMapping
        let map: [Character: Character] = ["„": "\"", "“": "\"", "”": "\"", "‚": "'", "‘": "'", "’": "'", "«": "\"", "»": "\"",
                                           "–": "-", "—": "-", "‐": "-", "‑": "-", "\u{00A0}": " ", "\u{202F}": " "]
        s = String(s.map { map[$0] ?? $0 })
        s = s.replacingOccurrences(of: #"(?<=\p{L})-\s*(?=\p{L})"#, with: "", options: .regularExpression) // hyphen between letters
        s = s.replacingOccurrences(of: #"-\s*\n\s*"#, with: "", options: .regularExpression) // hyphenation at line end
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return s.lowercased()
    }

    /// Is `quote` contained verbatim (after normalization) in `text`?
    public static func isVerbatim(_ quote: String, in text: String, minLength: Int = 4) -> Bool {
        let q = normalize(quote)
        guard q.count >= minLength else { return false }
        return normalize(text).contains(q)
    }
}

/// Rough kind of a document, from patterns only.
public enum DocCategory: String, Sendable, Codable, CaseIterable {
    case invoice, contract, photo, other

    /// Display name in the system language. Folders on disk are named by `Naming.folder` (stay German).
    public var label: String {
        switch self {
        case .invoice: L("Invoices", table: "Analysis")
        case .contract: L("Contracts", table: "Analysis")
        case .photo: L("Photos", table: "Analysis")
        case .other: L("Other", table: "Analysis")
        }
    }
}

public enum Keywords {
    static let invoice = ["rechnung", "rechnungsnummer", "rechnungsdatum", "rechnungsbetrag", "gesamtbetrag", "zu zahlen", "zahlbar",
                          "quittung", "kassenbon", "beleg", "invoice", "abrechnung", "beitragsrechnung", "mahnung", "ust-id", "mwst", "umsatzsteuer", "netto"]
    static let contract = ["vertrag", "mietvertrag", "kündigung", "kuendigung", "vereinbarung", "vollmacht", "versicherungsschein",
                           "police", "vertragsnummer", "unterschrift", "kündigungsfrist", "arbeitsvertrag", "laufzeit", "bescheid"]

    /// Known document kinds, longest first. Returns the kind as it should appear in the name.
    static let kinds: [(needle: String, label: String)] = [
        ("nebenkostenabrechnung", "Nebenkostenabrechnung"), ("beitragsrechnung", "Beitragsrechnung"), ("mietvertrag", "Mietvertrag"),
        ("mobilfunkvertrag", "Mobilfunkvertrag"), ("handyvertrag", "Mobilfunkvertrag"), ("stromvertrag", "Stromvertrag"), ("gasvertrag", "Gasvertrag"),
        ("darlehensvertrag", "Darlehensvertrag"), ("leasingvertrag", "Leasingvertrag"), ("versicherungsvertrag", "Versicherungsvertrag"),
        ("arbeitsvertrag", "Arbeitsvertrag"), ("kaufvertrag", "Kaufvertrag"), ("versicherungsschein", "Versicherungsschein"),
        ("kündigungsbestätigung", "Kündigungsbestätigung"), ("kündigung", "Kündigung"), ("kuendigung", "Kündigung"),
        ("mahnung", "Mahnung"), ("gutschrift", "Gutschrift"), ("quittung", "Quittung"), ("kassenbon", "Kassenbon"),
        ("kontoauszug", "Kontoauszug"), ("lohnabrechnung", "Lohnabrechnung"), ("gehaltsabrechnung", "Gehaltsabrechnung"),
        ("steuerbescheid", "Steuerbescheid"), ("bescheid", "Bescheid"), ("angebot", "Angebot"), ("vollmacht", "Vollmacht"),
        ("vereinbarung", "Vereinbarung"), ("rechnung", "Rechnung"), ("invoice", "Rechnung"), ("vertrag", "Vertrag"), ("abrechnung", "Abrechnung"),
    ]

    static func score(_ words: [String], in lower: String) -> Int {
        words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    /// Classification via keywords in name and text.
    public static func category(text: String, fileName: String) -> DocCategory? {
        let lower = (fileName + "\n" + text.prefix(4000)).lowercased()
        let inv = score(invoice, in: lower) + (GermanText.amounts(in: String(text.prefix(4000))).isEmpty ? 0 : 1)
        let con = score(contract, in: lower)
        if inv == 0 && con == 0 { return nil }
        if lower.contains("mietvertrag") || lower.contains("kündigung") || lower.contains("kuendigung") { return con >= inv - 1 ? .contract : .invoice }
        return inv >= con ? .invoice : .contract
    }

    /// Kind of the document ("Rechnung", "Mietvertrag" …), from file name or start of text. Name and letterhead first
    /// (about 400 characters), so a heading like "Mobilfunkvertrag" counts before a later section "Kündigung".
    public static func kind(text: String, fileName: String) -> String? {
        for limit in [400, 1500] {
            let head = (fileName + "\n" + text.prefix(limit)).lowercased()
            if let k = kinds.first(where: { head.contains($0.needle) }) { return k.label }
        }
        return nil
    }
}
