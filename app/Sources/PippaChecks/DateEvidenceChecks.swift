import PippaCore

/// Dates in an answer against what the turn read (the Stadtwerke letter from the acceptance runs).
func runDateEvidenceChecks() {
    let letter = """
    Musterstadt, 20. Oktober 2026
    Bitte überweisen Sie den Betrag bis zum 15. November 2026. Einwände können Sie innerhalb von vier Wochen nach Zugang erheben.
    """
    func read(_ text: String = letter) -> DateEvidence {
        var e = DateEvidence()
        e.toolStarted(id: "r", isWrite: false, arguments: "{}")
        e.toolEnded(id: "r", done: true, result: text)
        return e
    }

    check("Dates: a worked-out objection date is named, quoted dates in another form are not") {
        read().unsupported(in: "Zahlen bis 15.11.2026 (Brief vom 2026-10-20). Einwände bis 19. November 2026.") == ["19. November 2026"]
    }
    check("Dates: English answers, each day once") {
        read().unsupported(in: "Pay by November 15, 2026. Object by 17th November 2026, i.e. Nov 17 2026.") == ["17th November 2026"]
    }
    check("Dates: a close date no source shows is named (receipt date unknown, 17 Nov worked out)") {
        let unknownReceipt = """
        Datum: 20.10.2026. Bitte zahlen Sie bis 30.11.2026. Einwände sind innerhalb von 4 Wochen nach Zugang möglich.
        """
        return read(unknownReceipt).unsupported(in: "Frist bis 30.11.2026, Einwände bis 17.11.2026.") == ["17.11.2026"]
    }
    check("Dates: a close date a successful calendar result shows is supported") {
        let calendar = read(#"{"events":[{"title":"Zahnarzt","start":"2026-11-03T09:00:00"}]}"#)
        return calendar.unsupported(in: "Eingetragen ist Dienstag, 03.11.2026.").isEmpty
            && calendar.unsupported(in: "Dienstag, 04.11.2026.") == ["04.11.2026"]
    }
    check("Dates: nothing read, nothing checked; a failed read is no source") {
        var failed = DateEvidence()
        failed.toolStarted(id: "x", isWrite: false, arguments: "")
        failed.toolEnded(id: "x", done: false, result: letter)
        return DateEvidence().unsupported(in: "Weihnachten ist am 25.12.2026.").isEmpty
            && !failed.hasSources
    }
    check("Dates: the person's own words and a confirmed write's arguments count, an unconfirmed write's do not") {
        var e = read()
        e.add(prompt: "Trag mir den 30.11.2026 ein.")
        e.toolStarted(id: "w1", isWrite: true, arguments: #"{"date":"2026-12-04"}"#)
        e.toolEnded(id: "w1", done: true, result: #"{"done":true}"#)
        e.toolStarted(id: "w2", isWrite: true, arguments: #"{"date":"2026-12-09"}"#)
        e.toolEnded(id: "w2", done: false, result: #"{"done":false}"#)
        return e.unsupported(in: "30.11.2026, 04.12.2026 und 09.12.2026") == ["09.12.2026"]
    }
}

/// Mail search retries a German plural once as its singular.
func runMailSingularChecks() {
    check("Mail search: plural to a stem Mail finds, single words only") {
        PippaMCPTools.mailSingular("Zahlungseingänge") == "Zahlungseingang" && PippaMCPTools.mailSingular("Rechnungen") == "Rechnung"
            && PippaMCPTools.mailSingular("Verträge") == "Vertrag" && PippaMCPTools.mailSingular("Vertrag") == nil
            && PippaMCPTools.mailSingular("Zahlung Juni") == nil && PippaMCPTools.mailSingular("Mai") == nil
    }
}

/// read_document asks for awk once a document holds a table of amounts.
func runAmountHintChecks() {
    check("read_document: five euro amounts ask for awk, a letter with one does not") {
        PippaMCPTurnTools.manyAmounts("Jan 5.231.992 € Feb 17.683.220 € Mär 15.263.114 € Apr 23.826.152 € Mai 1.000,50 EUR")
            && !PippaMCPTurnTools.manyAmounts("Nachzahlung von 184,37 Euro bis zum 15. November 2026.")
    }
}
