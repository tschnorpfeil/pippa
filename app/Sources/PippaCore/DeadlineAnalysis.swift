import Foundation

/// Pi decides which passage is a deadline. Swift checks source and date.
public struct DeadlineAnalysis: Decodable, Sendable {
    public struct Calculation: Decodable, Sendable {
        public enum Unit: String, Decodable, Sendable { case days, weeks, months, years }
        public var baseDate: String
        public var baseQuote: String
        public var basePage: Int
        public var unit: Unit
        public var amount: Int
    }
    public struct CalculationChoice: Decodable { public var baseID: String; public var unit: Calculation.Unit; public var amount: Int }
    public struct DateSource: Sendable { public var id: String; public var date: DayDate; public var quote: String; public var page: Int }

    /// All date passages, without any substantive selection. Pi picks the meaning from the literal context.
    public static func dateSources(in doc: DocumentText) -> [DateSource] {
        var result: [DateSource] = []
        for (page, text) in doc.pages.prefix(10).enumerated() {
            for match in GermanText.dates(in: text) {
                guard result.count < 80 else { return result }
                // A separate line per date prevents mixing up the context of a neighbouring date.
                let startOfLine = text[..<match.range.lowerBound].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
                let endOfLine = text[match.range.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
                let lower = max(startOfLine, text.index(match.range.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex)
                let upper = min(endOfLine, text.index(match.range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex)
                result.append(DateSource(id: "date-\(result.count)", date: match.value, quote: String(text[lower..<upper]), page: page + 1))
            }
        }
        return result
    }

    public static func sourceQuote(_ value: String) -> String {
        Verify.stripMarkers(value).replacingOccurrences(of: #"\s*\(Seite \d+(?:,\s*§\s*\d+)?\)\s*$"#, with: "", options: .regularExpression)
    }
    /// Structural evidence, not a substantive selection: a deadline needs a quoted date or a numbered duration.
    /// Addresses, names and prices without a time indication must not become calendar suggestions.
    public static func hasTemporalEvidence(_ quote: String) -> Bool {
        !GermanText.dates(in: quote).isEmpty || durationPattern.firstMatch(in: quote, range: NSRange(quote.startIndex..., in: quote)) != nil
    }
    private static let durationPattern: NSRegularExpression = {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "de_DE"); formatter.numberStyle = .spellOut
        let words = (2...365).compactMap { formatter.string(from: NSNumber(value: $0)) }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?i)\\b(?:[1-9][0-9]{0,5}|ein(?:e|em|en|er|es)?|" + words + ")\\s+(?:tag(?:e|en|es)?|woche(?:n)?|monat(?:e|en|s)?|jahr(?:e|en|es)?)\\b")
    }()

    public struct Item: Decodable, Sendable {
        public var kind: Deadline.Kind
        public var datum: String
        public var title: String
        public var quote: String
        public var page: Int
        public var note: String
        public var sender: String
        public var documentKind: String
        public var calculation: Calculation?
    }
    public var items: [Item]

    public func verified(in doc: DocumentText, today: DayDate = DayDate(Date())) -> [Deadline] {
        var seen = Set<String>()
        return items.prefix(12).compactMap { raw in
            var item = raw; item.quote = Self.sourceQuote(item.quote)
            guard item.page > 0, item.page <= doc.pages.count, !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.count <= 160, item.quote.count >= 8, item.quote.count <= 1500,
                  GermanText.isVerbatim(item.quote, in: doc.pages[item.page - 1], minLength: 8), Self.hasTemporalEvidence(item.quote), seen.insert(item.quote).inserted else { return nil }
            let quotedDates = GermanText.dates(in: item.quote)
            if !quotedDates.isEmpty, quotedDates.allSatisfy({ $0.value < today }) { return nil }
            let date = GermanText.parseDate(item.datum)
            // A computed/invented date must not get calendar approval.
            let confirmed = date.flatMap { d in GermanText.dates(in: item.quote).contains(where: { $0.value == d }) ? d : nil }
            let computed = item.calculation.flatMap { Self.calculate($0, intervalQuote: item.quote, doc: doc) }.flatMap { $0 >= today ? $0 : nil }
            let shown = confirmed ?? computed
            if let confirmed, confirmed < today { return nil }
            // Note for the person: how the date came about (only without a literally quoted date).
            var note: String? = nil
            if confirmed == nil {
                let hint: String
                if let computed {
                    hint = L("Worked out from the period in the document: %@. Please check.", table: "Analysis", computed.german)
                } else {
                    hint = L("Please check the date and choose one.", table: "Analysis")
                }
                let detail = String(item.note.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
                note = detail.isEmpty ? hint : hint + " " + detail
            }
            return Deadline(kind: item.kind, date: shown, title: item.title, quote: item.quote, source: doc.url,
                            location: doc.isPaged ? "S. \(item.page)" : nil, certainty: confirmed == nil ? .unsure : .sure,
                            note: note,
                            documentKind: item.documentKind.isEmpty ? nil : String(item.documentKind.prefix(100)),
                            sender: item.sender.isEmpty ? nil : String(item.sender.prefix(100)))
        }
    }

    /// Only arithmetic and source check: Pi determines the context, so the deadline stays "please check".
    private static func calculate(_ value: Calculation, intervalQuote: String, doc: DocumentText) -> DayDate? {
        guard value.basePage > 0, value.basePage <= doc.pages.count, (-365...365).contains(value.amount), value.amount != 0,
              GermanText.isVerbatim(value.baseQuote, in: doc.pages[value.basePage - 1], minLength: 8),
              let base = GermanText.parseDate(value.baseDate), GermanText.dates(in: value.baseQuote).contains(where: { $0.value == base }) else { return nil }
        let n = abs(value.amount)
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "de_DE"); formatter.numberStyle = .spellOut
        let written = NSRegularExpression.escapedPattern(for: formatter.string(from: NSNumber(value: n)) ?? "")
        let number = n == 1 ? "(?:1|ein|eine|einem|einen|einer|eines)" : "(?:\(n)|\(written))"
        let unit: String
        switch value.unit { case .days: unit = "tag(?:e|en|es)?"; case .weeks: unit = "woche(?:n)?"; case .months: unit = "monat(?:e|en|s)?"; case .years: unit = "jahr(?:e|en|es)?" }
        guard intervalQuote.range(of: "(?i)\\b" + number + "\\s+" + unit + "\\b", options: .regularExpression) != nil else { return nil }
        switch value.unit {
        case .days: return base.adding(days: value.amount)
        case .weeks: return base.adding(days: value.amount * 7)
        case .months: return base.adding(months: value.amount)
        case .years: return base.adding(months: value.amount * 12)
        }
    }
}
