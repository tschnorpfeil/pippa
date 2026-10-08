import Foundation

// "Check online": the core proposes a search query, the app checks it here in code before it
// leaves the Mac. Filters known personal patterns and words: names, numbers, IBAN, addresses,
// email addresses, file names. The heuristic does not prove a free query safe; LookupHost therefore requires
// a preview and approval even for `.pass`. Pure, deterministic, no model.

/// Words from the person's things that must never go into a search query (folded: lowercase, no accents, ≥ 3 letters).
public struct PersonalTerms: Sendable, Equatable {
    public var terms: Set<String>
    public init(terms: Set<String> = []) {
        self.terms = Set(terms.map(PersonalTerms.fold).filter { $0.count >= 3 })
    }

    /// Lowercase, without accents and width forms. Applied equally to query and terms.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// General words for senders and authorities. They are not personal ("Hausverwaltung" is general, "Berger" is not).
    static let genericWordList: [String] = [
        "finanzamt", "stadtwerke", "krankenkasse", "versicherung", "versicherungen", "hausverwaltung", "verwaltung", "bank", "sparkasse",
        "volksbank", "raiffeisenbank", "amt", "gmbh", "mbh", "ggmbh", "ag", "kg", "ohg", "ug", "se", "ev", "eg", "co", "ltd", "inc", "llc",
        "stadt", "gemeinde", "landratsamt", "bürgeramt", "buergeramt", "jobcenter", "agentur", "arbeit", "bundesagentur", "familienkasse",
        "rentenversicherung", "deutsche", "kasse", "praxis", "kanzlei", "steuerberater", "steuerberatung", "rechtsanwalt", "rechtsanwälte",
        "notar", "notariat", "inkasso", "service", "kundenservice", "kundendienst", "team", "info", "kontakt", "support", "noreply",
        "no-reply", "mail", "post", "poststelle", "office", "telekom", "vodafone", "rundfunkbeitrag", "beitragsservice", "zentrale",
        "abteilung", "behörde", "behoerde", "ministerium", "landesamt", "bundesamt", "zentralamt", "gericht", "amtsgericht", "landgericht",
        // salutations and courtesies that a greeting line can catch
        "damen", "herren", "frau", "herr", "kunde", "kundin", "kunden", "mitglied", "nutzer", "nutzerin", "kollegen", "kolleginnen",
        "zusammen", "sir", "madam", "customer", "ihr", "ihre", "dein", "deine", "euer", "eure", "your", "yours", "sincerely", "regards",
        "grüße", "gruesse", "grüßen", "gruessen", "freundlichen", "freundliche", "viele", "beste", "best", "kind", "auftrag",
        // common mail providers (domain parts)
        "gmail", "googlemail", "gmx", "web", "outlook", "hotmail", "icloud", "yahoo", "posteo", "t-online", "online", "freenet", "aol",
        "live", "mailbox", "proton", "protonmail", "com", "net", "org",
        // general words in file names
        "scan", "scans", "dokument", "dokumente", "document", "documents", "brief", "kopie", "copy", "seite", "anhang", "attachment",
        "datei", "file", "image", "bild", "foto", "photo", "pdf", "eml", "jpg", "jpeg", "png", "heic", "docx", "xlsx", "final", "neu", "new",
    ]
    static let genericWords: Set<String> = Set(genericWordList.map(PersonalTerms.fold))

    /// Is this not a personal word? General, stop word, document kind (from Keywords.kinds) or too short.
    static func isGeneric(_ folded: String) -> Bool {
        if folded.count < 3 || genericWords.contains(folded) || stopwords.contains(folded) { return true }
        return documentKinds.contains(folded)
    }
    static let stopwords: Set<String> = Set(SearchIndex.stopwords.map(PersonalTerms.fold))
    static let documentKinds: Set<String> = {
        var result = Set<String>()
        for kind in Keywords.kinds { result.insert(PersonalTerms.fold(kind.needle)); result.insert(PersonalTerms.fold(kind.label)) }
        return result
    }()

    /// Words made of letters (and hyphen) of a text, folded, without general words. Hyphenated names also count in parts.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        let pieces = text.split { !($0.isLetter || $0 == "-") }
        for piece in pieces {
            let word = fold(String(piece)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard word.count >= 3 else { continue }
            if !isGeneric(word) { out.append(word) }
            if word.contains("-") {
                for part in word.split(separator: "-") where part.count >= 3 && !isGeneric(String(part)) { out.append(String(part)) }
            }
        }
        return out
    }

    // Salutation with name: "Sehr geehrte Frau Becker", "Hallo Anna", "Dear Mr. Smith". Only the salutation itself is case-insensitive,
    // the name must start uppercase so "Hallo, wie geht’s" doesn't yield a name. Not across line end.
    static let greeting = try! NSRegularExpression(pattern:
        #"(?i:sehr geehrte[rs]?|liebe[rs]?|hallo|guten tag|dear|hi)[ \t]+(?:(?i:frau|herr|mr\.?|mrs\.?|ms\.?|dr\.?|prof\.?)[ \t]+)*([A-ZÄÖÜ][\p{L}-]+(?:[ \t]+[A-ZÄÖÜ][\p{L}-]+)?)"#)
    static let closing = try! NSRegularExpression(pattern:
        #"(?i)(mit freundlichen grüßen|mit freundlichen gruessen|freundliche grüße|freundliche gruesse|viele grüße|viele gruesse|beste grüße|liebe grüße|best regards|kind regards|regards|sincerely)"#)
    static let street = try! NSRegularExpression(pattern: #"(?i)[\p{L}-]+(straße|strasse|str\.|weg|gasse|allee|platz|ring|damm)[ \t]*\d+"#)
    static let postalCity = try! NSRegularExpression(pattern: #"\b\d{5}[ \t]+([A-ZÄÖÜ][\p{L}-]+)"#)
    static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    static func matches(_ expression: NSRegularExpression, in text: String, group: Int) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.range(at: group).location != NSNotFound, let range = Range(match.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Personal items from texts: names after a salutation, up to three lines after a greeting, streets, places after a
    /// postal code, parts of email addresses.
    static func personalWords(inText text: String) -> [String] {
        var out: [String] = []
        for name in matches(greeting, in: text, group: 1) { out += words(name) }
        for line in matches(street, in: text, group: 0) { out += words(line) }
        for city in matches(postalCity, in: text, group: 1) { out += words(city) }
        for address in matches(email, in: text, group: 0) { out += emailWords(address) }
        let lines = text.components(separatedBy: .newlines)
        // Address field: if a street is at the start of a line, the (up to two) short lines before it are name and addition
        // ("Anna Becker" / "c/o Ostermeier" above "Lindenstraße 5").
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let hit = street.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)), hit.range.location == 0 else { continue }
            var taken = 0
            var previous = index - 1
            while previous >= 0, taken < 2 {
                let candidate = lines[previous].trimmingCharacters(in: .whitespaces)
                previous -= 1
                if candidate.isEmpty { break }
                guard candidate.split(separator: " ").count <= 4 else { break }
                out += words(candidate)
                taken += 1
            }
        }
        // Signature: up to three non-empty lines after the closing phrase.
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard closing.firstMatch(in: line, range: range) != nil else { continue }
            var taken = 0
            var next = index + 1
            while next < lines.count, taken < 3 {
                let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                next += 1
                if candidate.isEmpty { continue }
                out += words(candidate)
                taken += 1
            }
        }
        return out
    }

    /// "anna.becker@hv-berger.de" → anna, becker, berger (general parts like "info" or "gmail" stay out).
    static func emailWords(_ address: String) -> [String] {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        var out: [String] = []
        for piece in parts[0].split(whereSeparator: { ".-_+%".contains($0) }) { out += words(String(piece)) }
        let labels = parts[1].split(separator: ".").map(String.init)
        // The ending ("de", "com") is not personal.
        for label in labels.dropLast() { out += words(label) }
        return out
    }

    /// Sender without legal form and general words: "Hausverwaltung Berger <info@hv-berger.de>" → berger.
    static func senderWords(_ sender: String) -> [String] {
        var out: [String] = []
        for address in matches(email, in: sender, group: 0) { out += emailWords(address) }
        let name = sender.components(separatedBy: "<").first ?? sender
        out += words(Heuristics.stripLegalForm(name.replacingOccurrences(of: "\"", with: " ")))
        return out
    }

    /// File names without extension; general words and document kinds ("Steuerbescheid", "Scan") are not personal.
    static func fileWords(_ fileName: String) -> [String] {
        let base = (fileName as NSString).lastPathComponent
        return words((base as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " "))
    }

    public static func from(texts: [String], senders: [String], fileNames: [String], userName: String?) -> PersonalTerms {
        var all: [String] = []
        for sender in senders { all += senderWords(sender) }
        for text in texts { all += personalWords(inText: text) }
        for file in fileNames { all += fileWords(file) }
        if let userName { all += words(userName) }
        var result = PersonalTerms()
        result.terms = Set(all)
        return result
    }

    /// Sender line, text, subject and attachment names of a mail. Subject lines can contain names too.
    public static func from(mail: MailMessage, fileNames: [String] = [], userName: String? = nil) -> PersonalTerms {
        var result = from(texts: [mail.body], senders: [mail.sender], fileNames: mail.attachmentNames + fileNames, userName: userName)
        result.terms.formUnion(words(mail.subject))
        return result
    }

    /// Is `token` (or a part of it, split at hyphen, apostrophe or period: "Becker’s", "Becker-Wohnung") personal?
    public func contains(_ token: String) -> Bool {
        let folded = PersonalTerms.fold(token).trimmingCharacters(in: CharacterSet.letters.inverted)
        guard folded.count >= 3 else { return false }
        if terms.contains(folded) { return true }
        return folded.split { !$0.isLetter }.contains { $0.count >= 3 && terms.contains(String($0)) }
    }
}

public enum QueryVerdict: Sendable, Equatable {
    /// Unchanged clean: may go out as is.
    case pass(String)
    /// Personal items removed: the person sees the cleaned query and approves it.
    case confirm(String)
    /// Nothing usable left or suspicious (quotation marks, line breaks, too long).
    case refuse
}

/// Rules (in this order):
/// 1. Line breaks, control characters or quotation marks („“"«»`) → refuse. That way no multi-line or quoted
///    letter text gets out.
/// 2. Removed (personal): email addresses, URLs and domains, IBANs (GermanText.ibans), phone numbers (+… or 0…),
///    every word with a digit — except a year 1990–2099 and a number with ≤ 4 digits (and at most one
///    letter) directly after "§", "Art." or "Abs." (not after "Nr.": file, customer and invoice numbers) —,
///    every word from `personal`.
/// 3. Punctuation except "§" is dropped, whitespace is collapsed.
/// 4. Nothing removed, ≤ maxLength characters, ≥ 2 words → `.pass`. Something removed and ≥ 2 words left (≤ maxLength) →
///    `.confirm`. Otherwise `.refuse`. A "word" is every remaining piece except "§"; at least one needs letters.
public enum QueryGuard {
    public static let maxLength = 120

    static let quoteCharacters: Set<Character> = ["\"", "„", "“", "”", "«", "»", "`", "‟", "〝", "〞", "＂"]
    static let phone = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(?:\+|0)\d[\d ()/.-]{4,}\d"#)
    static let url = try! NSRegularExpression(pattern: #"(?i)\b(?:https?://|www\.)\S+|\b[\p{L}\d-]+(?:\.[\p{L}\d-]+)*\.(?:de|com|net|org|eu|info|at|ch|io|gov|uk|biz|me|app)\b(?:/\S*)?"#)
    static let year = try! NSRegularExpression(pattern: #"^(?:199\d|20\d\d)$"#)
    static let sectionNumber = try! NSRegularExpression(pattern: #"^\d{1,4}[a-z]?$"#)
    static let markers: Set<String> = ["§", "§§", "art", "art.", "abs", "abs."]
    /// Characters that may stay in a word (the rest separates): "§", "Art.", hyphen, apostrophe.
    static let tokenMarks: Set<Character> = ["§", ".", "-", "'", "’"]

    static func whole(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Removes all matches of `expression` (replaced by spaces). `true` if something was removed.
    static func strip(_ expression: NSRegularExpression, from text: inout String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard expression.firstMatch(in: text, range: range) != nil else { return false }
        text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return true
    }

    public static func check(_ query: String, personal: PersonalTerms) -> QueryVerdict {
        // 1. Suspicious characters
        let lineBreaks = CharacterSet.newlines.union(.controlCharacters)
        if query.unicodeScalars.contains(where: { lineBreaks.contains($0) && $0 != "\t" }) { return .refuse }
        if query.contains(where: { quoteCharacters.contains($0) }) { return .refuse }
        if query.count > 400 { return .refuse }

        // 2a. Patterns across several words: email, URL, IBAN, phone
        var text = query.replacingOccurrences(of: "\t", with: " ")
        var removed = false
        if strip(PersonalTerms.email, from: &text) { removed = true }
        if strip(url, from: &text) { removed = true }
        for iban in GermanText.ibans(in: text.uppercased()) {
            // The IBAN is uppercase in the match; in the text it can be lowercase.
            if let range = text.range(of: iban, options: .caseInsensitive) { text.replaceSubrange(range, with: " "); removed = true }
        }
        if strip(phone, from: &text) { removed = true }

        // 2b./3. Words: drop punctuation (except "§" and the period after Art./Abs.), remove digits and personal items.
        let spaced = text.replacingOccurrences(of: "§", with: " § ")
        let rawTokens = spaced.split { character in
            !(character.isLetter || character.isNumber || tokenMarks.contains(character))
        }.map(String.init)
        var kept: [String] = []
        var previous = ""
        for raw in rawTokens {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
            let folded = PersonalTerms.fold(token)
            defer { previous = folded }
            guard !token.isEmpty else { continue }
            if folded == "§" || folded == "§§" { kept.append(token); continue }
            if folded == "art." || folded == "abs." { kept.append(token); continue }
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let foldedBare = PersonalTerms.fold(bare)
            guard !bare.isEmpty else { continue }
            if bare.contains(where: { $0.isNumber }) {
                let isYear = whole(year, foldedBare)
                let afterMarker = markers.contains(previous) && whole(sectionNumber, foldedBare)
                if isYear || afterMarker { kept.append(bare) } else { removed = true }
                continue
            }
            if personal.contains(bare) { removed = true; continue }
            kept.append(bare)
        }

        // 4. Verdict
        let cleaned = kept.joined(separator: " ")
        let wordCount = kept.filter { $0 != "§" && $0 != "§§" }.count
        let hasLetters = kept.contains { piece in piece.contains(where: { $0.isLetter }) }
        guard wordCount >= 2, hasLetters, cleaned.count <= maxLength else { return .refuse }
        return removed ? .confirm(cleaned) : .pass(cleaned)
    }
}
