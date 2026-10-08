import Foundation
import PippaCore

/// Host-side source fidelity. Answers below are real raw model answers (Apple FM, Gemma 4 12B baseline);
/// sources are the fixture texts as LocalEngine.snapshots reads them.
func runSourceFidelityChecks() {
    typealias S = SourceFidelity
    let contract = DocumentSnapshot(name: "Vertrag.txt", text: "Vertrag\n§ 4 Installation: Die Installation findet am 14.10.2026 um 09:00 Uhr statt.\n")
    let confirmationLater = DocumentSnapshot(name: "Bestaetigung.txt", text: "Bestätigung\nAbsatz 2: Wir bestätigen die Installation am 15.10.2026 um 09:00 Uhr.\n")
    let missing = DocumentSnapshot(name: "Bestaetigung.txt", text: "Diese angehängte Quelle ist nicht mehr verfügbar oder konnte nicht gelesen werden.", truncated: true, readStatus: .unavailable)
    let empty = DocumentSnapshot(name: "Bestaetigung.txt", text: "Kein lesbarer Text verfügbar (empty).", readStatus: .unreadable)
    let offer = DocumentSnapshot(name: "Angebot.txt", text: "Angebot\nLiefertermin: 08.12.2026 um 10 Uhr.\n")
    let partial = DocumentSnapshot(name: "Bestaetigung.txt", text: "Bestätigung\nDie Angaben zur Lieferung folgen nach den allgemeinen Bedingungen.\n\n"
        + String(repeating: "Allgemeine Bedingungen: Verpackung und Lagerung werden gesondert besprochen.\n\n", count: 40), truncated: true, readStatus: .partial)
    let offerExcluded = DocumentSnapshot(name: "Angebot.txt", text: "Angebot\nDie Lieferung ist nicht im Preis enthalten. Lieferkosten werden separat vereinbart.\n")
    let open = "**" + L("Open:", table: "Core", language: "de") + "**"

    check("Source fidelity: missing source – \"kein Widerspruch\" is dropped, read status comes from code") {
        let answer = """
        **Kein Terminwiderspruch** – nur eine Quelle liefert klare Daten.

        - **Vertrag.txt** zeigt einen Termin: Installation am 14.10.2026 um 09:00 Uhr – Quelle 1.
        - **Bestaetigung.txt** ist nicht verfügbar – Inhalt unbekannt, keine Belege – Quelle 2.

        Die Vergleichsanalyse ergibt: **kein Widerspruch**, da nur der erste Text lesbar ist. Die fehlende Quelle verhindert eine vollständige Bewertung.
        """
        let review = S.review(answer: answer, question: "Vergleiche die Dokumente: Gibt es einen Terminwiderspruch?", snapshots: [contract, missing], fileCount: 2)
        let folded = review.text.lowercased()
        return review.text.hasPrefix(open) && !folded.contains("kein terminwiderspruch") && !folded.contains("kein widerspruch")
            && review.text.contains("Installation am 14.10.2026 um 09:00 Uhr") && review.text.contains("Bestaetigung.txt** ist nicht verfügbar")
            && review.text.contains(L("Whether the details match therefore remains open.", table: "Core", language: "de"))
            && review.findings.filter { if case .verdictWithIncompleteSource = $0 { return true }; return false }.count == 2
    }
    check("Source fidelity: empty source – verdict is dropped, \"unentschieden\" stays") {
        let answer = """
        Mir ist klar, der einzige lesbare Teil kommt aus dem Vertrag.txt.

        - **Kein Terminwiderspruch** – der Termin ist klar: Installation am 14.10.2026 um 09:00 Uhr (Quelle: Vertrag.txt).
        - **Unentschieden** – die Bestätigung.txt ist nicht gelesen, daher ist kein Vergleich möglich (Quelle: Bestätigung.txt – Inhalt unbekannt).
        """
        let review = S.review(answer: answer, question: "Vergleiche die Dokumente: Gibt es einen Terminwiderspruch?", snapshots: [contract, empty], fileCount: 2)
        return !review.text.contains("Kein Terminwiderspruch") && review.text.contains("**Unentschieden**") && review.text.hasPrefix(open)
    }
    check("Source fidelity: partially read source – no claim of absence or deviation") {
        let answer = """
        **Liefertermin-Vergleich – Quelle 1 vs. Quelle 2**

        - **Liefertermin in [Angebot.txt]: 08.12.2026 um 10 Uhr** – klar belegt, Quelle 1.
        - **Liefertermin in [Bestaetigung.txt]: kein konkreter Termin genannt** – Vergleich offen, da der gesamte Text nur teilweise gelesen ist, Quelle 2.

        **Ergebnis:** Es gibt eine Abweichung – der Zeitpunkt ist in der Bestätigung nicht spezifiziert, während der Auftrag einen festen Termin hat. Die Bestätigung enthält keine Angaben zum Lieferzeitpunkt. Die Lücke liegt bei der vollständigen Analyse von Quelle 2.
        """
        let review = S.review(answer: answer, question: "Vergleiche die Liefertermine: Gibt es eine Abweichung?", snapshots: [offer, partial], fileCount: 2)
        return !review.text.contains("kein konkreter Termin") && !review.text.contains("Es gibt eine Abweichung")
            && !review.text.contains("enthält keine Angaben") && review.text.contains("08.12.2026 um 10 Uhr")
            && review.text.contains("Die Lücke liegt bei der vollständigen Analyse von Quelle 2.") && review.text.hasPrefix(open)
    }
    check("Source fidelity: partially read source – Gemma table loses only the invented row") {
        let answer = """
        Ein direkter Vergleich der Liefertermine ist nicht möglich, da die Bestätigung keinen Termin nennt.

        | Quelle | Liefertermin | Status |
        | :--- | :--- | :--- |
        | Angebot.txt | 08.12.2026 um 10 Uhr | Festgelegt |
        | Bestaetigung.txt | Nicht angegeben | Verweis auf allgemeine Bedingungen |
        """
        let review = S.review(answer: answer, question: "Vergleiche die Liefertermine: Gibt es eine Abweichung?", snapshots: [offer, partial], fileCount: 2)
        return !review.text.contains("keinen Termin nennt") && !review.text.contains("Nicht angegeben")
            && review.text.contains("| Angebot.txt | 08.12.2026 um 10 Uhr | Festgelegt |") && review.text.contains("| :--- | :--- | :--- |")
            && review.text.hasPrefix(open)
    }
    check("Source fidelity: partially read source – \"keine Abweichung, Termin fehlt\" and \"enthält lediglich\" are dropped") {
        let answer = """
        Ein direkter Vergleich ist nicht möglich, da in der Bestätigung kein konkretes Datum genannt wird.

        | Quelle | Liefertermin | Status |
        | :--- | :--- | :--- |
        | [Angebot.txt] | 08.12.2026 um 10 Uhr | Bekannt |
        | [Bestaetigung.txt] | Nicht angegeben | Unbekannt (Verweis auf allgemeine Bedingungen) |

        **Abweichung:**
        Es liegt keine Abweichung vor, da der Liefertermin in der Bestätigung fehlt. Die Datei [Bestaetigung.txt] enthält lediglich den Hinweis, dass die Angaben zur Lieferung den allgemeinen Bedingungen folgen.
        """
        let review = S.review(answer: answer, question: "Vergleiche die Liefertermine: Gibt es eine Abweichung?", snapshots: [offer, partial], fileCount: 2)
        return review.text == open + " " + L("I could read only part of “%@”; the rest is unknown.", table: "Core", language: "de", "Bestaetigung.txt") + " "
            + L("Whether the details match therefore remains open.", table: "Core", language: "de")
            + "\n\n| Quelle | Liefertermin | Status |\n| :--- | :--- | :--- |\n| [Angebot.txt] | 08.12.2026 um 10 Uhr | Bekannt |"
            && review.findings.count == 4 && review.findings.allSatisfy(\.removes)
    }
    check("Source fidelity: only the judging trailing clause is dropped, the read fact stays") {
        let missingAnswer = """
        - Quelle 1 [Vertrag.txt]: Termin am 14.10.2026 um 09:00 Uhr – kein Widerspruch belegt (1/1 Abschnitt).
        - Quelle 2 [Bestaetigung.txt]: nicht verfügbar – Inhalt unbekannt (0/0 Abschnitte).

        Kein Widerspruch in Quelle 1; Quelle 2 fehlt.
        """
        let unreadableAnswer = "- Quelle 2 [Bestaetigung.txt]: nicht gelesen – Inhalt unbekannt, keine Angaben zu Terminen"
        let partialAnswer = "- Liefertermin [Angebot.txt]: 08.12.2026 um 10 Uhr\n- Liefertermin [Bestaetigung.txt]: nicht belegt (nur allgemeine Bedingungen, keine konkrete Zeit)"
        let missingReview = S.review(answer: missingAnswer, question: "Gibt es einen Terminwiderspruch?", snapshots: [contract, missing], fileCount: 2)
        let unreadableReview = S.review(answer: unreadableAnswer, question: "Gibt es einen Terminwiderspruch?", snapshots: [contract, empty], fileCount: 2)
        let partialReview = S.review(answer: partialAnswer, question: "Gibt es eine Abweichung?", snapshots: [offer, partial], fileCount: 2)
        return missingReview.text.contains("- Quelle 1 [Vertrag.txt]: Termin am 14.10.2026 um 09:00 Uhr.\n")
            && !missingReview.text.contains("Widerspruch") && missingReview.text.contains("Quelle 2 [Bestaetigung.txt]: nicht verfügbar")
            && unreadableReview.text.hasSuffix("- Quelle 2 [Bestaetigung.txt]: nicht gelesen")
            && !partialReview.text.contains("keine konkrete Zeit") && partialReview.text.contains("08.12.2026 um 10 Uhr")
    }
    check("Source fidelity: absence claims about a source shown only as excerpts are dropped; questions and single-source checks stay") {
        let letter = DocumentSnapshot(name: "Schreiben_Abschlag.txt", text: "Ab dem 01.11.2026 beträgt Ihr monatlicher Abschlag 84,00 Euro brutto.\n\nDer erste Abschlag wird am 15.11.2026 abgebucht.")
        let invoice = DocumentSnapshot(name: "Zahlungsuebersicht_November.txt", text: "Abschlag Strom November 2026: 94,00 Euro brutto. Abbuchung am 15.11.2026.")
        let answer = "- **Abschlag Strom November 2026**: 94,00 Euro brutto – Quelle 2\n\nDie Zahl von 94,00 Euro brutto ist in Quelle 2 belegt; Quelle 1 nennt keine konkrete Höhe für den ersten Abschlag."
        let review = S.review(answer: answer, question: "Passt die Zahlungsübersicht zum Schreiben?", snapshots: [letter, invoice], fileCount: 2, excerptOnly: [0])
        let question = S.review(answer: "Gibt es Kosten, die im Schreiben nicht erwähnt werden?", question: "Was muss ich klären?", snapshots: [letter, invoice], fileCount: 2, excerptOnly: [0])
        let single = S.review(answer: "- Expansion nach Spanien 2027\n\nKeine Abweichung zwischen den Quellen.", question: "Was ist das?",
                              snapshots: [.init(name: "Strategie.txt", text: "Expansion nach Spanien 2027.")], fileCount: 1)
        let inside = S.review(answer: "Die Summe stimmt mit den Einzelposten überein.", question: "Stimmt die Rechnung?",
                              snapshots: [.init(name: "Rechnung.txt", text: "Posten 10,00 Euro. Posten 5,00 Euro. Summe 15,00 Euro.")], fileCount: 1)
        let list = S.review(answer: "- **Abschlagswert:**\n  - Quelle 1: kein Wert genannt\n  - Quelle 2: 94,00 Euro brutto", question: "Passt die Zahlungsübersicht zum Schreiben?",
                            snapshots: [letter, invoice], fileCount: 2, excerptOnly: [0])
        return !review.text.contains("nennt keine konkrete Höhe") && review.text.contains("94,00 Euro brutto")
            && !list.text.contains("kein Wert genannt") && list.text.contains("  - Quelle 2: 94,00 Euro brutto")
            && review.text.hasPrefix(open + " " + L("I looked only at excerpts of “%@” for this answer; anything else in it is unchecked.", table: "Core", language: "de", "Schreiben_Abschlag.txt"))
            && !question.changed && !single.text.contains("Keine Abweichung") && !inside.changed
    }
    check("Source fidelity: notes follow the conversation's language, not the Mac's") {
        let english = S.review(answer: "The contract says 14.10.2026. There is no conflict.", question: "Do the documents conflict?", snapshots: [contract, missing], fileCount: 2)
        return english.text.hasPrefix("**Open:** “Bestaetigung.txt” is not available") && !english.text.contains("no conflict")
    }
    check("Source fidelity: unknown counter-source – invented equality is dropped, backed negation stays") {
        let answer = """
        **Lieferungsbedingungen – Vergleich aus den Dokumenten**

        - **Lieferung ist nicht im Preis enthalten** – belegt in [Angebot.txt], erste Zeile
        - **Lieferkosten werden separat vereinbart** – identisch mit der Aussage aus [Angebot.txt]

        **Ergebnis:** Die Bedingungen sind gleich. Beide Dokumente bestätigen dass die Lieferung nicht im Preis enthalten ist und die Kosten separat geregelt werden. Keine Abweichung ist ersichtlich.
        """
        let review = S.review(answer: answer, question: "Vergleiche die Lieferung in beiden Dokumenten: Sind die Bedingungen gleich?", snapshots: [offerExcluded, missing], fileCount: 2)
        return review.text.contains("Lieferung ist nicht im Preis enthalten** – belegt in [Angebot.txt]")
            && !review.text.contains("sind gleich") && !review.text.contains("Beide Dokumente") && !review.text.contains("Keine Abweichung")
            && !review.text.contains("identisch") && review.text.hasPrefix(open)
    }
    check("Source fidelity: unknown counter-source – a correct Gemma answer stays unchanged") {
        let answer = """
        Ein Vergleich der Lieferbedingungen ist aktuell nicht möglich, da der Inhalt von Quelle 2 fehlt.

        | Merkmal | Quelle 1 [Angebot.txt] | Quelle 2 [Bestaetigung.txt] | Status |
        | :--- | :--- | :--- | :--- |
        | **Lieferbedingungen** | Nicht im Preis enthalten; Kosten separat zu vereinbaren. | Inhalt unbekannt | Fehlender Vergleich |

        **Quelle 2 [Bestaetigung.txt]:** Nicht verfügbar (Inhalt unbekannt).
        """
        let review = S.review(answer: answer, question: "Vergleiche die Lieferung in beiden Dokumenten: Sind die Bedingungen gleich?", snapshots: [offerExcluded, missing], fileCount: 2)
        return !review.changed && review.text == answer
    }
    check("Source fidelity: wrong time span (\"eine Stunde\") is dropped, backed dates stay") {
        let answer = """
        - **Vertrag.txt** nennt den Termin **14.10.2026 um 09:00 Uhr** als Installationsdatum.
        - **Bestaetigung.txt** gibt den späteren Termin **15.10.2026 um 09:00 Uhr** an.

        Die Abweichung liegt beim Zeitpunkt der Installation: einerseits 14.10.2026, andererseits 15.10.2026. Du musst klären, welches Datum korrekt ist. Die Differenz beträgt eine Stunde.
        """
        let review = S.review(answer: answer, question: "Welche Abweichung muss ich klären?", snapshots: [contract, confirmationLater], fileCount: 2)
        let right = S.review(answer: "Die Bestätigung nennt einen Tag später, den 15.10.2026.", question: "", snapshots: [contract, confirmationLater], fileCount: 2)
        return !review.text.contains("eine Stunde") && review.text.contains("Du musst klären, welches Datum korrekt ist.")
            && review.findings == [.unsupportedSpan("Die Differenz beträgt eine Stunde.")] && !review.text.contains(open) && !right.changed
    }
    check("Source fidelity: fully read comparisons stay unchanged") {
        let date = """
        Du musst den Installationstermin klären, da die Daten in den Dokumenten voneinander abweichen.

        | Fakt | Vertrag.txt | Bestaetigung.txt | Status |
        | :--- | :--- | :--- | :--- |
        | Datum | 14.10.2026 | 15.10.2026 | Abweichung |
        | Uhrzeit | 09:00 Uhr | 09:00 Uhr | Übereinstimmung |

        Das Dokument **Bestaetigung.txt** nennt den späteren Termin (15.10.2026).
        """
        let price = """
        Du musst folgende Abweichungen klären:

        | Merkmal | Angebot.txt | Bestaetigung.txt | Abweichung |
        | :--- | :--- | :--- | :--- |
        | **Gesamtpreis** | 1.250,00 Euro netto | 1.520,00 Euro netto | +270,00 Euro in der Bestätigung |
        | **Lieferung** | im Preis enthalten | nicht im Preis enthalten | In der Bestätigung extra |
        """
        let offerPrice = DocumentSnapshot(name: "Angebot.txt", text: "Angebot\nAbsatz 3: Gesamtpreis 1.250,00 Euro netto. Die Lieferung ist im Preis enthalten.\n")
        let confirmationPrice = DocumentSnapshot(name: "Bestaetigung.txt", text: "Auftragsbestätigung\nAbsatz 3: Gesamtpreis 1.520,00 Euro netto. Die Lieferung ist nicht im Preis enthalten.\n")
        let sameA = DocumentSnapshot(name: "Termin.txt", text: contract.text), sameB = DocumentSnapshot(name: "Termin.txt", text: confirmationLater.text)
        let sameName = """
        | Quelle | Dokumentteil | Datum | Uhrzeit |
        | :--- | :--- | :--- | :--- |
        | Quelle 1 [Termin.txt] | § 4 Installation | 14.10.2026 | 09:00 Uhr |
        | Quelle 2 [Termin.txt] | Absatz 2 | 15.10.2026 | 09:00 Uhr |
        """
        return !S.review(answer: date, question: "", snapshots: [contract, confirmationLater], fileCount: 2).changed
            && !S.review(answer: price, question: "", snapshots: [offerPrice, confirmationPrice], fileCount: 2).changed
            && !S.review(answer: sameName, question: "", snapshots: [sameA, sameB], fileCount: 2).changed
    }
    check("Source fidelity: swapped and invented values are marked, values from an unread source are removed") {
        let sameA = DocumentSnapshot(name: "Termin.txt", text: contract.text), sameB = DocumentSnapshot(name: "Termin.txt", text: confirmationLater.text)
        let swapped = S.review(answer: "| Quelle | Datum |\n| --- | --- |\n| Quelle 1 [Termin.txt] | 15.10.2026 |\n| Quelle 2 [Termin.txt] | 14.10.2026 |",
                               question: "", snapshots: [sameA, sameB], fileCount: 2)
        let invented = S.review(answer: "Der Vertrag nennt 14.10.2026; Zahlung bis 30.10.2026.", question: "", snapshots: [contract, confirmationLater], fileCount: 2)
        let unread = S.review(answer: "- **Bestaetigung.txt**: Installation am 15.10.2026.\n- **Vertrag.txt**: 14.10.2026.", question: "", snapshots: [contract, missing], fileCount: 2)
        let both = S.review(answer: "- **Vertrag.txt** nennt 14.10.2026; die Bestätigung weicht mit dem 15.10.2026 ab.", question: "",
                            snapshots: [contract, confirmationLater], fileCount: 2)
        let check = L("please check: not in this source", table: "Core", language: "de"), nowhere = L("please check: not in the sources I read", table: "Core", language: "de")
        return swapped.text.contains("15.10.2026 (\(check))") && swapped.text.contains("14.10.2026 (\(check))") && !both.changed
            && invented.text.contains("30.10.2026 (\(nowhere))") && !invented.text.contains("14.10.2026 (")
            && !unread.text.contains("15.10.2026") && unread.text.contains("**Vertrag.txt**: 14.10.2026.") && unread.text.hasPrefix(open)
    }
    check("Source fidelity: only one source – \"beide Quellen\" is dropped; an unmentioned reading gap is added") {
        let strategy = DocumentSnapshot(name: "Strategie.txt", text: "Strategie Nordstern\nWir planen die Expansion nach Spanien 2027. Vertrieb soll drei neue Standorte eröffnen.\n")
        let answer = "- Expansion nach Spanien 2027 (Strategie Nordstern) – Strategie.txt\n- Drei neue Standorte für Vertrieb – Strategie.txt\n\nBeide Quellen belegen die Expansion und die drei Standorte. Die Strategie.txt enthält diese Angaben."
        let one = S.review(answer: answer, question: "Was ist das?", snapshots: [strategy], fileCount: 1)
        let silent = S.review(answer: "Der Vertrag nennt den 14.10.2026 um 09:00 Uhr.", question: "", snapshots: [contract, missing], fileCount: 2)
        return !one.text.contains("Beide Quellen") && one.text.contains("Die Strategie.txt enthält diese Angaben.")
            && silent.text.hasPrefix("Der Vertrag nennt den 14.10.2026 um 09:00 Uhr.") && silent.text.hasSuffix(L("“%@” is not available, so I couldn’t read it.", table: "Core", language: "de", "Bestaetigung.txt"))
            && silent.findings == [.unstatedReadGap("Bestaetigung.txt")]
    }
    check("Source fidelity: backed absence in a fully read text and read-status sentences stay") {
        let answer = "Ob es einen Widerspruch gibt, lässt sich nicht sagen: Bestaetigung.txt ist nicht verfügbar. Im Vertrag ist keine Uhrzeit für den Abbau genannt."
        let review = S.review(answer: answer, question: "", snapshots: [contract, missing], fileCount: 2)
        let scoped = S.review(answer: "Im gelesenen Teil von Bestaetigung.txt steht kein Liefertermin; der Rest ist unbekannt.", question: "", snapshots: [offer, partial], fileCount: 2)
        return !review.changed && !scoped.changed
    }
}
