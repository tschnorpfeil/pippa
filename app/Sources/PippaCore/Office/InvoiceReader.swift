import Foundation

// "Invoices as a spreadsheet" without a model doing sums: code finds the total, the date, the currency and a guess at
// the sender in the read text, says which of them it is sure about, and the table marks the rest in yellow. The model
// (system model when there is one) may only point at one of the amounts code found (`InvoiceReader.choose`); it never
// types a number. Plain code over the text `TextReader` returns (with text recognition for photos).

public struct InvoiceRow: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable, CaseIterable { case sender, date, amount }

    public var file: String
    public var sender: String?
    public var date: Date?
    public var amount: Double?
    public var currency: String
    /// The line with the total, verbatim, so the person can find it in the invoice.
    public var evidence: String?
    /// Fields code is not sure about; the table shows them in yellow.
    public var unsure: Set<Field>
    /// Every amount code found on a total line, for the model to point at (as written in the text).
    public var candidates: [InvoiceReader.Amount]

    public init(file: String, sender: String? = nil, date: Date? = nil, amount: Double? = nil, currency: String = "EUR",
                evidence: String? = nil, unsure: Set<Field> = [], candidates: [InvoiceReader.Amount] = []) {
        self.file = file; self.sender = sender; self.date = date; self.amount = amount; self.currency = currency
        self.evidence = evidence; self.unsure = unsure; self.candidates = candidates
    }
}

public enum InvoiceReader {
    /// An amount in the text: its value, how it was written, the line and how much the line says "total".
    public struct Amount: Sendable, Hashable {
        public var value: Double
        public var written: String
        public var line: String
        public var score: Int
    }

    /// Words of a total line, strong ones first. Matched on the lowercased line.
    static let strong = ["gesamtbetrag", "rechnungsbetrag", "endbetrag", "zu zahlen", "zahlbetrag", "bruttobetrag", "gesamtsumme",
                         "summe brutto", "brutto", "amount due", "total due", "grand total", "zahlbar", "zu überweisen", "total amount"]
    static let medium = ["summe", "gesamt", "total", "betrag", "amount"]
    /// Lines that carry an amount that is not the total.
    static let never = ["netto", "mwst", "ust", "umsatzsteuer", "steuer", "tax", "vat", "zwischensumme", "subtotal", "sub-total",
                        "gegeben", "rückgeld", "wechselgeld", "rabatt", "skonto", "net", "trinkgeld", "pfand"]

    static let amountPattern = try! NSRegularExpression(
        pattern: #"(?<![\d.,])[-−]?(?:\d{1,3}(?:[.  ' ]\d{3})+|\d+)[,.]\d{2}(?![\d])(?![.,]\d)"#)
    static let germanDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?!\d)"#)
    static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)

    /// Reads one invoice's text. `nil` amount when the text names no amount at all (then it is probably no invoice).
    public static func read(file: String, text: String) -> InvoiceRow {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var row = InvoiceRow(file: file)
        let amounts = lines.flatMap(amounts(in:))
        row.candidates = amounts.filter { $0.score > 0 }
        if let pick = pickTotal(amounts) {
            row.amount = pick.amount.value
            row.evidence = pick.amount.line
            if !pick.sure { row.unsure.insert(.amount) }
        }
        let date = findDate(lines)
        row.date = date?.date
        if date?.sure != true { row.unsure.insert(.date) }
        row.currency = currency(in: row.evidence ?? "") ?? currency(in: text) ?? "EUR"
        row.sender = guessSender(lines)
        row.unsure.insert(.sender)
        return row
    }

    /// The amounts on one line, scored by its words: strong total words 3, others 2, words for something else -3.
    static func amounts(in line: String) -> [Amount] {
        let range = NSRange(line.startIndex..., in: line)
        let lower = line.lowercased()
        let words = Set(lower.split { !$0.isLetter && $0 != "-" }.map(String.init))
        // Long words also inside compounds ("Rechnungsbetrag", "Nettobetrag"); short ones only as words ("USt", not "Kunst").
        func has(_ word: String) -> Bool { word.count >= 5 || word.contains(" ") ? lower.contains(word) : words.contains(word) }
        var score = 0
        if strong.contains(where: has) { score = 3 } else if medium.contains(where: has) { score = 2 }
        if never.contains(where: has) { score = -3 }
        return amountPattern.matches(in: line, range: range).compactMap { match in
            guard let r = Range(match.range, in: line) else { return nil }
            let written = String(line[r])
            guard let value = SheetNumber.parse(written.replacingOccurrences(of: "−", with: "-")) else { return nil }
            return Amount(value: value, written: written, line: line, score: score)
        }
    }

    /// The total: the amounts on the best total lines; sure when they all say the same number. Without a total word,
    /// the largest amount, never sure.
    static func pickTotal(_ amounts: [Amount]) -> (amount: Amount, sure: Bool)? {
        let positive = amounts.filter { $0.value > 0 }
        guard let best = positive.map(\.score).max() else { return nil }
        if best <= 0 {
            return positive.filter { $0.score == 0 }.max { $0.value < $1.value }.map { ($0, false) }
        }
        let top = positive.filter { $0.score == best }
        let values = Set(top.map { ($0.value * 100).rounded() })
        // Lines that say "Summe" next to lines that say "zu zahlen" with another number: the strong one, not sure.
        let rival = positive.contains { $0.score > 0 && $0.score < best && !values.contains(($0.value * 100).rounded()) }
        guard let chosen = top.max(by: { $0.value < $1.value }) else { return nil }
        return (chosen, values.count == 1 && !(best < 3 && rival))
    }

    /// The invoice date: a date on a line that says so ("Rechnungsdatum", "Datum", "Date"), else the only date.
    static func findDate(_ lines: [String]) -> (date: Date, sure: Bool)? {
        var found: [(date: Date, labelled: Bool)] = []
        for line in lines {
            let lower = line.lowercased()
            let labelled = ["rechnungsdatum", "belegdatum", "datum", "date", "invoice date", "ausgestellt"].contains { lower.contains($0) }
                && !["fällig", "due", "lieferdatum", "leistungsdatum", "zahlbar bis"].contains { lower.contains($0) }
            for date in dates(in: line) { found.append((date, labelled)) }
        }
        if let labelled = found.first(where: { $0.labelled }) { return (labelled.date, true) }
        let distinct = Set(found.map { $0.date })
        guard let first = found.first else { return nil }
        return (first.date, distinct.count == 1)
    }

    static func dates(in line: String) -> [Date] {
        var out: [Date] = []
        let range = NSRange(line.startIndex..., in: line)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d), (1990...2100).contains(y) else { return nil }
            let parts = DateComponents(year: y, month: m, day: d)
            guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        for m in germanDate.matches(in: line, range: range) {
            let g = (1...3).compactMap { Range(m.range(at: $0), in: line).flatMap { Int(line[$0]) } }
            guard g.count == 3 else { continue }
            if let date = make(g[2] < 100 ? 2000 + g[2] : g[2], g[1], g[0]) { out.append(date) }
        }
        for m in isoDate.matches(in: line, range: range) {
            let g = (1...3).compactMap { Range(m.range(at: $0), in: line).flatMap { Int(line[$0]) } }
            if g.count == 3, let date = make(g[0], g[1], g[2]) { out.append(date) }
        }
        return out
    }

    static func currency(in text: String) -> String? {
        let upper = text.uppercased()
        if upper.contains("€") || upper.contains("EUR") { return "EUR" }
        if upper.contains("CHF") { return "CHF" }
        if upper.contains("£") || upper.contains("GBP") { return "GBP" }
        if upper.contains("$") || upper.contains("USD") { return "USD" }
        return nil
    }

    /// A guess at the sender: the first line at the top that reads like a name, without legal form ("GmbH").
    static func guessSender(_ lines: [String]) -> String? {
        let skip = ["rechnung", "invoice", "quittung", "kassenbon", "beleg", "seite", "page", "datum", "date", "tel", "fax", "www",
                    "http", "@", "ust-id", "steuer", "kunden", "iban", "bic", "an:", "lieferschein", "angebot", "herr", "frau"]
        for line in lines.prefix(8) {
            let lower = line.lowercased()
            let letters = line.filter(\.isLetter).count
            guard letters >= 3, letters * 2 >= line.count, !skip.contains(where: { lower.contains($0) }) else { continue }
            // Address lines: postcode and town, or a street with a number.
            if line.range(of: #"\b\d{4,5}\s+\p{L}"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"(str\.|straße|strasse|weg|platz|allee|gasse)\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let name = withoutLegalForm(line)
            if !name.isEmpty { return String(name.prefix(40)) }
        }
        return nil
    }

    static func withoutLegalForm(_ name: String) -> String {
        var s = name
        for form in [" GmbH & Co. KG", " GmbH & Co KG", " GmbH", " mbH", " AG", " KG", " UG (haftungsbeschränkt)", " UG", " e.K.", " e. K.", " OHG", " GbR", " Inc.", " Ltd.", " LLC", " SE"] {
            if let r = s.range(of: form, options: [.caseInsensitive, .backwards]), r.upperBound == s.endIndex
                || s[r.upperBound...].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).isEmpty {
                s = String(s[..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
    }

    /// A model's pick among the candidates: taken only when it names one of them; the row becomes sure when the pick and
    /// code agree, and takes the pick (not sure) when they differ. A sender is taken only when it appears in the text.
    public static func choose(_ row: InvoiceRow, amount picked: String?, sender: String?, text: String) -> InvoiceRow {
        var out = row
        if let picked, let match = row.candidates.first(where: { $0.written == picked.trimmingCharacters(in: .whitespaces) }) {
            if let amount = row.amount, SheetCheck.same(amount, match.value) {
                out.unsure.remove(.amount)
            } else {
                out.amount = match.value
                out.evidence = match.line
                out.unsure.insert(.amount)
            }
        }
        if let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines), sender.count >= 2,
           text.range(of: sender, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            out.sender = String(withoutLegalForm(sender).prefix(40))
            out.unsure.remove(.sender)
        }
        return out
    }
}
