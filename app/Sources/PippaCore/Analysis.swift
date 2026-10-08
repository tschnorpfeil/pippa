import Foundation

/// What Pippa knows about a document: from patterns, optionally supplemented by the model, always verified in code.
public struct DocInsight: Sendable {
    public var url: URL
    public var facts: FileFacts
    public var text: DocumentText?
    public var category: DocCategory
    public var kind: String?          // e.g. "Rechnung" (invoice), "Mietvertrag" (lease) …
    public var sender: String?
    public var date: DayDate?
    public var subject: String?       // "Wohnung" (apartment) for leases
    public var draft = false
    public var reason: String
    public var certainty: Certainty
    public var skipReason: String?    // set: file stays unchanged
    /// Fixed target folder from the pre-sort (`PreSort`), relative to the scope; the file name stays.
    public var folder: String? = nil
    /// The model answered for this classification (otherwise patterns only).
    public var fromModel = false
    /// Byte-identical copy of this file (which stays): the copy goes to the Trash.
    public var duplicateOf: URL? = nil
}

/// Model answers (JSON per schema).
struct ClassifyJSON: Decodable, Sendable { var kategorie: String; var absender: String; var art: String; var datum: String; var betreff: String; var entwurf: Bool; var beleg: String?; var entwurf_beleg: String? }

/// Patterns without a model.
public enum Heuristics {
    static let legalForms = [" GmbH & Co. KG", " GmbH & Co KG", " gGmbH", " GmbH", " mbH", " AG", " SE", " KG", " OHG", " e.V.", " eG", " UG (haftungsbeschränkt)", " UG", " Ltd.", " Inc."]
    static let senderMarkers = ["gmbh", " ag", " kg", "e.v.", "stadtwerke", "praxis", "dr.", "versicherung", "bank", "sparkasse", "telekom",
                                "vodafone", "o2", "verwaltung", "hausverwaltung", "finanzamt", "krankenkasse", "aok", "barmer", "techniker", "amt ", "gmbh&"]
    static let skipLines = ["rechnung", "seite", "datum", "kundennummer", "rechnungsnummer", "betreff", "sehr geehrte", "tel.", "telefon", "fax", "e-mail", "www.", "http", "iban", "bic", "ust-id", "ust.", "steuernummer"]

    public static func stripLegalForm(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: ".&"))))
        for form in legalForms where s.hasSuffix(form) { s = String(s.dropLast(form.count)); break }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,-·"))
    }

    /// Sender from the letterhead (first lines) or the mail header line.
    public static func sender(text: String, headers: [String: String] = [:]) -> String? {
        if let from = headers["from"] {
            let name = from.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
            if name.count >= 2 && !name.contains("@") { return stripLegalForm(name) }
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(15)
        if let marked = lines.first(where: { l in
            let lower = " " + l.lowercased()
            return l.count <= 60 && senderMarkers.contains { lower.contains($0) } && !skipLines.contains { lower.contains($0) }
        }) { return clean(marked) }
        if let first = lines.first(where: { l in
            let lower = l.lowercased()
            let digits = l.filter(\.isNumber).count
            return (3...40).contains(l.count) && digits <= 2 && l.filter(\.isLetter).count >= 3 && !skipLines.contains { lower.contains($0) }
                && !l.hasPrefix("[S.") && GermanText.dates(in: l).isEmpty
        }) { return clean(first) }
        return nil
    }

    static func clean(_ line: String) -> String {
        // „Stadtwerke Musterstadt GmbH · Hauptstr. 1“ → „Stadtwerke Musterstadt“
        var head = line.components(separatedBy: CharacterSet(charactersIn: "·|•,")).first ?? line
        // Contract header "zwischen Hausverwaltung Berger und Anna Becker" → "Hausverwaltung Berger"
        if head.lowercased().hasPrefix("zwischen ") {
            head = String(head.dropFirst("zwischen ".count))
            if let und = head.range(of: " und ") { head = String(head[..<und.lowerBound]) }
        }
        return displayName(head)
    }

    /// Sender for names and tables: without legal form and without additions to the doctor title
    /// ("Zahnarztpraxis Dr. med. dent. Julia Hoffmann" → "Zahnarztpraxis Dr. Julia Hoffmann"), shortened at word boundaries.
    public static func displayName(_ raw: String, maxLength: Int = 40) -> String {
        var s = " " + stripLegalForm(raw) + " "
        s = s.replacingOccurrences(of: #"(?i)(?<=\s)(med|dent|rer|nat|jur|phil|vet|habil|oec|pol|h\.\s?c)\.\s+"#, with: "", options: .regularExpression)
        return Naming.sanitize(s, maxLength: maxLength)
    }

    /// Document date: prefers lines with "Rechnungsdatum", "Datum", "vom"; otherwise the first plausible date.
    public static func documentDate(text: String, notAfter: Date = Date().addingTimeInterval(86400 * 60)) -> DayDate? {
        let limit = DayDate(notAfter)
        let plausible = { (d: DayDate) in d.year >= 1990 && d <= limit }
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if ["rechnungsdatum", "belegdatum", "datum", "ausgestellt", " vom "].contains(where: { lower.contains($0) }),
               let d = GermanText.dates(in: line).map(\.value).first(where: plausible) { return d }
        }
        return GermanText.dates(in: text).map(\.value).first(where: plausible)
    }

    static let strongTotals = ["gesamtbetrag", "rechnungsbetrag", "endbetrag", "zu zahlen", "zahlbetrag", "bruttobetrag", "gesamtsumme", "summe brutto", "total",
                               "rechnungssumme", "nachzahlung"]
    static let weakTotals = ["summe", "gesamt", "betrag"]

    /// Does a receipt line contain a word for the total amount? (Otherwise the model may have quoted a single item.)
    public static func mentionsTotal(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard !lower.contains("netto"), !lower.contains("mwst"), lower.range(of: #"\bust\b"#, options: .regularExpression) == nil else { return false }
        return (strongTotals + weakTotals).contains { lower.contains($0) }
    }

    /// A line starting with "Summe" (receipt: "SUMME EUR 23,45") counts as a strong total amount; "Zwischensumme" (subtotal) does not.
    static func isStrongTotal(_ lower: String) -> Bool {
        strongTotals.contains { lower.contains($0) } || lower.trimmingCharacters(in: .whitespaces).hasPrefix("summe")
    }

    /// Amount with evidence passage without a model. `sure` only for an unambiguous line like "Gesamtbetrag 84,20 €".
    public static func invoiceAmount(text: String) -> (amount: Decimal, evidence: String, sure: Bool)? {
        let lines = text.components(separatedBy: .newlines)
        for sure in [true, false] {
            for (i, line) in lines.enumerated() {
                let lower = line.lowercased()
                guard sure ? isStrongTotal(lower) : weakTotals.contains(where: { lower.contains($0) }), !lower.contains("netto"), !lower.contains("mwst"), lower.range(of: #"\bust\b"#, options: .regularExpression) == nil else { continue }
                if let a = GermanText.amounts(in: line).last { return (a.value, line.trimmingCharacters(in: .whitespaces), sure) }
                if i + 1 < lines.count, let a = GermanText.amounts(in: lines[i + 1]).first {
                    return (a.value, (line + "\n" + lines[i + 1]).trimmingCharacters(in: .whitespacesAndNewlines), sure)
                }
            }
        }
        // Largest amount with a currency sign on the same line
        var best: (Decimal, String)?
        for line in lines where line.contains("€") || line.uppercased().contains("EUR") {
            for a in GermanText.amounts(in: line) where best == nil || a.value > best!.0 { best = (a.value, line.trimmingCharacters(in: .whitespaces)) }
        }
        return best.map { ($0.0, $0.1, false) }
    }

    /// Receipt instead of photo: text with a totals line including amount and a recognizable sender (merchant, practice …).
    public static func looksLikeReceipt(text: String) -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20,
              let total = invoiceAmount(text: text), mentionsTotal(total.evidence) else { return false }
        return sender(text: text) != nil
    }

    /// Classification of an image. Camera photos (photo data) stay photos, without text recognition; otherwise the recognized text decides.
    public static func imageCategory(captureDate: Date?, cameraModel: String?, ocrText: String?) -> DocCategory {
        if captureDate != nil || cameraModel != nil { return .photo }
        if let t = ocrText, looksLikeReceipt(text: t) { return .invoice }
        return .photo
    }

    static let subjects = ["Wohnung", "Garage", "Stellplatz", "Haus", "Büro", "Gewerbe", "Auto", "Fahrzeug", "Strom", "Gas", "Internet", "Mobilfunk", "Fitnessstudio"]

    public static func subject(text: String) -> String? {
        // Whole words: "Hausverwaltung" is not a "Haus", "Wohnungsschlüssel" not a "Wohnung".
        let head = String(text.prefix(3000))
        return subjects.first { head.range(of: "\\b\($0)\\b", options: [.caseInsensitive, .regularExpression]) != nil }
    }

    public static func isDraft(text: String, fileName: String) -> Bool {
        let lower = (fileName + " " + text.prefix(2000)).lowercased()
        return lower.contains("entwurf") || lower.contains("draft")
    }
}

/// Checks model answers against the text. Only verbatim evidence counts as sure.
public enum Verify {
    /// Page markers that exist only in the text for the model ("[S. 4]") are not part of the quote.
    static func stripMarkers(_ quote: String) -> String {
        quote.replacingOccurrences(of: #"\[S\. \d+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "„“\"'")))
    }

    /// Every number and time span of the full answer also appears in the selected quote.
    public static func numbersBacked(_ answer: String, by passage: String) -> Bool {
        func numbers(_ s: String) -> Set<String> {
            let re = try! NSRegularExpression(pattern: #"\d+"#)
            return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
        }
        return numbers(answer).isSubset(of: numbers(passage)) && durations(answer).isSubset(of: durations(passage))
    }

    private static let durationWords: [String: Int] = {
        let formatter = NumberFormatter(); formatter.numberStyle = .spellOut
        var result: [String: Int] = [:]
        for locale in ["de_DE", "en_US", "en_GB"] {
            formatter.locale = Locale(identifier: locale)
            for n in 0...365 {
                if let word = formatter.string(from: NSNumber(value: n)) { result[word.lowercased()] = n }
            }
        }
        for word in ["ein", "eine", "einem", "einen", "einer", "eines"] { result[word] = 1 }
        result["a"] = 1; result["an"] = 1
        return result
    }()
    private static let durationRegex: NSRegularExpression = {
        let words = durationWords.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?i)\\b([0-9]+|" + words + ")\\s+(tag(?:e|en|es)?|woche(?:n)?|monat(?:e|en|s)?|jahr(?:e|en|es)?|days?|weeks?|months?|years?)\\b")
    }()
    private static func durations(_ text: String) -> Set<String> {
        Set(durationRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let nr = Range(match.range(at: 1), in: text), let ur = Range(match.range(at: 2), in: text),
                  let amount = Int(text[nr]) ?? durationWords[text[nr].lowercased()] else { return nil }
            let unit = text[ur].lowercased()
            let canonical = unit.hasPrefix("tag") || unit.hasPrefix("day") ? "day"
                : unit.hasPrefix("woche") || unit.hasPrefix("week") ? "week"
                : unit.hasPrefix("monat") || unit.hasPrefix("month") ? "month" : "year"
            return "\(amount):\(canonical)"
        })
    }
}
