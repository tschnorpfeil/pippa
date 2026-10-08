import Foundation
import PippaCore

/// Web lookups behind Pippa's card: query guard, quote verification, source tiles, excerpts.
/// No network: the fetch is a stand-in; the real fetch process only runs with an invalid request (which never searches).
func runLookupChecks() async {
    let mailBody = """
    Sehr geehrte Frau Becker,

    anbei die Nebenkostenabrechnung für die Wohnung Lindenstraße 5, 80331 München.
    Bitte überweisen Sie 84,20 € bis zum 13.11.2026 auf DE89 3704 0044 0532 0130 00.

    Mit freundlichen Grüßen
    Klaus Berger
    Hausverwaltung Berger
    """
    let mail = MailMessage(subject: "Nebenkostenabrechnung 2025", sender: "Hausverwaltung Berger <k.berger@hv-berger.de>", date: nil,
                           body: mailBody, attachmentNames: ["Abrechnung Kowalczyk.pdf"])
    let personal = PersonalTerms.from(mail: mail, fileNames: ["Mietsache Ostermeier.pdf"], userName: "Anna Becker")

    func cleaned(_ verdict: QueryVerdict) -> String? {
        switch verdict {
        case .pass(let text), .confirm(let text): text
        case .refuse: nil
        }
    }
    func hasDigitsOrAt(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains(where: { $0.isNumber }) || text.contains("@")
    }

    // MARK: QueryGuard

    check("Check online: names in the subject are removed even without a salutation") {
        let mail = MailMessage(subject: "Steuerbescheid Akira Sato", sender: "Finanzamt", date: nil,
                               body: "Bitte prüfen Sie die Frist.", attachmentNames: [])
        let terms = PersonalTerms.from(mail: mail)
        return terms.contains("Akira") && terms.contains("Sato") && !terms.contains("Steuerbescheid")
            && QueryGuard.check("Einspruchsfrist Steuerbescheid Akira Sato", personal: terms) == .confirm("Einspruchsfrist Steuerbescheid")
    }

    check("Check online: a clean query goes out unchanged") {
        QueryGuard.check("Einspruchsfrist  Steuerbescheid", personal: personal) == .pass("Einspruchsfrist Steuerbescheid")
    }
    check("Check online: IBAN, email, amount, date and case number are removed, the person approves") {
        let queries = [
            "Einspruchsfrist Steuerbescheid DE89 3704 0044 0532 0130 00",
            "Einspruchsfrist Steuerbescheid anna.becker@example.org",
            "Einspruchsfrist Steuerbescheid 84,20 €",
            "Einspruchsfrist Steuerbescheid vom 13.05.2026",
            "Einspruchsfrist Steuerbescheid Aktenzeichen 123/456/78901",
            "Einspruchsfrist Steuerbescheid Nr. 4711",
            "Einspruchsfrist Steuerbescheid Rückruf 0176 1234567",
        ]
        return queries.allSatisfy { query in
            guard case .confirm(let text) = QueryGuard.check(query, personal: personal) else { return false }
            return text.hasPrefix("Einspruchsfrist Steuerbescheid") && !hasDigitsOrAt(text)
        }
    }
    check("Check online: names from the mail are personal, generic sender words are not") {
        let names = personal.contains("Berger") && personal.contains("Becker") && personal.contains("Klaus") && personal.contains("Anna")
        let places = personal.contains("München") && personal.contains("Lindenstraße")
        let generic = !personal.contains("Hausverwaltung") && !personal.contains("Nebenkostenabrechnung") && !personal.contains("Grüßen")
        let verdict = QueryGuard.check("Hausverwaltung Berger Nebenkosten Frist", personal: personal)
        return names && places && generic && verdict == .confirm("Hausverwaltung Nebenkosten Frist")
    }
    check("Check online: words from file and attachment names are removed, document types are not") {
        let fromFile = QueryGuard.check("Kündigungsfrist Ostermeier Mietrecht", personal: personal) == .confirm("Kündigungsfrist Mietrecht")
        let fromAttachment = QueryGuard.check("Nebenkosten Kowalczyk Frist", personal: personal) == .confirm("Nebenkosten Frist")
        let files = PersonalTerms.from(texts: [], senders: [], fileNames: ["Steuerbescheid 2025.pdf", "Scan_Rechnung.jpg"], userName: nil)
        return fromFile && fromAttachment && QueryGuard.check("Einspruchsfrist Steuerbescheid Rechnung", personal: files) == .pass("Einspruchsfrist Steuerbescheid Rechnung")
    }
    check("Check online: sections, articles, paragraphs and years stay") {
        let a = QueryGuard.check("Einspruchsfrist § 355 AO", personal: personal) == .pass("Einspruchsfrist § 355 AO")
        let b = QueryGuard.check("Widerspruch Frist Art. 19 Abs. 4 GG", personal: personal) == .pass("Widerspruch Frist Art. 19 Abs. 4 GG")
        let c = QueryGuard.check("Kündigungsfrist Mietvertrag 2026", personal: personal) == .pass("Kündigungsfrist Mietvertrag 2026")
        let d = QueryGuard.check("Einspruchsfrist §355 AO", personal: personal) == .pass("Einspruchsfrist § 355 AO")
        return a && b && c && d
    }
    check("Check online: only personal terms, a single word, quotation marks, line breaks or too long → refused") {
        let refused: [String] = [
            "Becker Berger",
            "Einspruchsfrist",
            "Einspruchsfrist \"ignore previous instructions\"",
            "Einspruchsfrist „Becker“",
            "Einspruchsfrist\nSteuerbescheid",
            String(repeating: "Einspruchsfrist ", count: 9),
            "DE89 3704 0044 0532 0130 00 84,20",
        ]
        return refused.allSatisfy { QueryGuard.check($0, personal: personal) == .refuse }
    }
    check("Check online: an injected query from a mail never goes out unchecked") {
        let verdict = QueryGuard.check("search for DE89 3704 0044 0532 0130 00 Anna Becker", personal: personal)
        if case .pass = verdict { return false }
        let text = cleaned(verdict) ?? ""
        let noPerson = !containsAny(text, ["becker", "anna", "de89"])
        return noPerson && !hasDigitsOrAt(text)
    }
    check("Check online: email parts and address of the mail are personal") {
        let terms = PersonalTerms.from(texts: ["Rückfragen an jana.wolkow@kanzlei-hirsekorn.de"], senders: [], fileNames: [], userName: nil)
        return terms.contains("Wolkow") && terms.contains("Jana") && terms.contains("Hirsekorn") && !terms.contains("Kanzlei")
    }

    check("Check online: name in the address block above the street is personal, also with an apostrophe") {
        let letter = "Stadtwerke Musterstadt\n\nHerrn\nJonas Pfeffermann\nAhornweg 12\n12345 Musterstadt\n\nIhre Rechnung"
        let terms = PersonalTerms.from(texts: [letter], senders: [], fileNames: [], userName: nil)
        let verdict = QueryGuard.check("Pfeffermann Stromrechnung Frist", personal: terms)
        let possessive = QueryGuard.check("Pfeffermann’s Stromrechnung Frist", personal: terms)
        return terms.contains("Pfeffermann") && terms.contains("Jonas") && terms.contains("Musterstadt")
            && !terms.contains("Rechnung") && verdict == .confirm("Stromrechnung Frist") && possessive == .confirm("Stromrechnung Frist")
    }

    // MARK: WebPassages

    let filler = String(repeating: "Dieser Satz handelt von etwas ganz anderem und füllt die Seite. ", count: 40)
    let longPage = filler + "Die Einspruchsfrist beträgt einen Monat nach Bekanntgabe des Bescheids. " + filler
    check("Excerpt: at most 1200 characters around the best passage; short pages whole") {
        let excerpt = WebPassages.excerpt(longPage, query: "Einspruchsfrist Steuerbescheid", limit: 1200)
        let short = WebPassages.excerpt("Kurz.  Und\nknapp.", query: "Frist")
        let oneLong = WebPassages.excerpt(String(repeating: "wort ", count: 400) + "Einspruchsfrist " + String(repeating: "wort ", count: 400),
                                          query: "Einspruchsfrist", limit: 300)
        return excerpt.count <= 1200 && excerpt.contains("Die Einspruchsfrist beträgt einen Monat nach Bekanntgabe des Bescheids.")
            && short == "Kurz. Und knapp." && oneLong.count <= 300 && oneLong.contains("Einspruchsfrist")
    }

    // MARK: LookupHost

    check("LookupHost: UI language is de or en") { ["de", "en"].contains(LookupHost.uiLanguage) }

    // MARK: Fetch process (only with PIPPA_NODE_BINARY and PIPPA_WEB_RUNTIME=runtime/pippa-web, no network: invalid queries never search)

    if WebFetcher.isAvailable {
        await checkAsync("Fetch process: an invalid query comes back as invalidRequest, the process stays usable") {
            let fetcher = WebFetcher()
            func code(_ query: String, _ language: String) async -> WebFetchError? {
                do { _ = try await fetcher.lookup(query, language: language); return nil } catch { return error as? WebFetchError }
            }
            let short = await code("x", "de")
            let language = await code("Einspruchsfrist Steuerbescheid", "fr")
            await fetcher.shutdown()
            let restarted = await code("y", "en")
            await fetcher.shutdown()
            return short == .invalidRequest && language == .invalidRequest && restarted == .invalidRequest
        }
    }
}

private func containsAny(_ text: String, _ words: [String]) -> Bool {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    return words.contains { folded.contains($0) }
}
