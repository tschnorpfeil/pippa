import Foundation
import CoreText
import AppKit
// Invented documents for the agentic model comparison (README.md next to this file). Same approach as
// make-search-corpus.swift: real PDFs with a text layer, written only below an explicit fake HOME. Never reads personal files.
// Writes `.agentic-corpus.json` (path -> pages) for the MCP mock's read_document, like `.search-corpus.json`.
guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasSuffix("/dist/model-compare-home") else {
    fatalError("Set CFFIXED_USER_HOME to the isolated dist/model-compare-home fixture directory.")
}
let base = URL(fileURLWithPath: home)
let icloud = "Library/Mobile Documents/com~apple~CloudDocs"
let cloud = "Library/CloudStorage/TestDrive"

// Person: Maria Beispiel, Musterstraße 5, 12345 Musterstadt. All companies, numbers and addresses are invented.
let docs: [(String, [String])] = [
    // --- Invoices 2024 (five, sum 865,30 EUR) and decoys ---
    ("Documents/Rechnungen/scan_0412.pdf", ["""
    Elektro Blitz GmbH · Lampenweg 3 · 12345 Musterstadt
    Frau Maria Beispiel, Musterstraße 5, 12345 Musterstadt
    RECHNUNG Nr. 2024-118
    Rechnungsdatum: 12.04.2024
    Leistung: Austausch einer defekten Steckdose im Bad, Material und Arbeitszeit
    Nettobetrag 120,00 EUR, zzgl. 19 % MwSt 22,80 EUR
    Gesamtbetrag: 142,80 EUR
    Bitte überweisen Sie den Betrag innerhalb von 14 Tagen.
    """]),
    ("Downloads/invoice_7731.pdf", ["""
    Zahnarztpraxis Dr. Muster · Am Markt 1 · 12345 Musterstadt
    Patientin: Maria Beispiel
    Rechnung vom 03.07.2024
    Professionelle Zahnreinigung (Privatleistung)
    Rechnungsbetrag: 95,00 EUR
    Zahlbar bis 31.07.2024.
    """]),
    ("Downloads/handwerker.pdf", ["""
    Malerbetrieb Farbe & Söhne · Pinselstraße 9 · 12345 Musterstadt
    Rechnung Nr. 0228
    Datum: 28.02.2024
    Kunde: Maria Beispiel
    Streichen Flur und Wohnzimmer
    Zwischensumme 260,50 EUR
    darin enthalten 19 % MwSt: 49,50 EUR
    Endbetrag: 310,00 EUR
    """]),
    ("Documents/Haushalt/kaufbeleg.pdf", ["""
    Möbelhaus Beispiel · Sesselallee 12 · 12345 Musterstadt
    Rechnung / Kaufbeleg
    Datum: 21.09.2024
    1 Bürostuhl „Ergo“ 249,00 EUR
    Summe: 249,00 EUR (bar bezahlt)
    """]),
    ("\(icloud)/Belege/r-2024-11.pdf", ["""
    Fahrradladen Speiche · Kettenweg 2 · 12345 Musterstadt
    Rechnung 2024/311
    Datum: 05.11.2024
    Jahresinspektion Fahrrad, neue Bremsbeläge
    Zu zahlen: 68,50 EUR
    """]),
    ("Documents/Rechnungen/scan_0399.pdf", ["""
    Elektro Blitz GmbH · Lampenweg 3 · 12345 Musterstadt
    RECHNUNG Nr. 2023-301
    Rechnungsdatum: 14.12.2023
    Leistung: Prüfung der Hausinstallation
    Gesamtbetrag: 120,00 EUR
    """]),
    ("Downloads/beleg_feb.pdf", ["""
    Schlüsseldienst Schnell · Torweg 4 · 12345 Musterstadt
    Rechnung Nr. 25-017
    Datum: 08.02.2025
    Türöffnung am 07.02.2025
    Rechnungsbetrag: 89,00 EUR
    """]),
    ("Downloads/angebot_kueche.pdf", ["""
    Küchenstudio Beispiel · Herdgasse 7 · 12345 Musterstadt
    ANGEBOT vom 10.10.2024 – keine Zahlungsaufforderung
    Neue Arbeitsplatte inklusive Montage
    Angebotspreis: 1.200,00 EUR, gültig 4 Wochen
    """]),

    // --- Lease and service charges ---
    ("Documents/Wohnung/mv_scan.pdf", ["""
    Mietvertrag für Wohnraum
    Zwischen Hausverwaltung Beispiel GmbH (Vermieterin) und Frau Maria Beispiel (Mieterin)
    Mietobjekt: Musterstraße 5, 2. OG links, 12345 Musterstadt
    Mietbeginn: 01.03.2021
    § 3 Miete
    Die monatliche Grundmiete (kalt) beträgt 780,00 EUR.
    Daneben zahlt die Mieterin monatlich eine Vorauszahlung auf die Betriebskosten von 180,00 EUR
    und eine Vorauszahlung auf die Heiz- und Warmwasserkosten von 70,00 EUR.
    Die monatliche Gesamtzahlung beträgt somit 1.030,00 EUR.
    """, """
    § 4 Betriebskosten
    Über die Vorauszahlungen wird jährlich abgerechnet. Nach einer Abrechnung kann jede Seite die Vorauszahlungen
    auf eine angemessene Höhe anpassen.
    § 5 Kaution
    Die Kaution beträgt 2.340,00 EUR.
    Musterstadt, 15.01.2021
    """]),
    ("Downloads/abrechnung_hv.pdf", ["""
    Hausverwaltung Beispiel GmbH · Verwalterweg 1 · 12345 Musterstadt
    Frau Maria Beispiel, Musterstraße 5, 2. OG links
    Nebenkostenabrechnung 2024
    Abrechnungszeitraum: 01.01.2024 bis 31.12.2024
    Betriebskosten (Wasser, Müll, Grundsteuer, Hausmeister, Gebäudeversicherung, Treppenhausreinigung): 2.310,00 EUR
    Heiz- und Warmwasserkosten: 960,00 EUR
    Ihre Kosten gesamt: 3.270,00 EUR
    Ihre geleisteten Vorauszahlungen 2024: 12 × 250,00 EUR = 3.000,00 EUR
    Ergebnis: Nachzahlung 270,00 EUR, fällig bis 15.07.2025
    Wir empfehlen, die monatliche Vorauszahlung ab 01.08.2025 auf 275,00 EUR anzuheben.
    """]),
    ("Documents/Wohnung/nk2023.pdf", ["""
    Hausverwaltung Beispiel GmbH
    Nebenkostenabrechnung 2023, Abrechnungszeitraum 01.01.2023 bis 31.12.2023
    Ihre Kosten gesamt: 2.915,00 EUR
    Ihre Vorauszahlungen: 3.000,00 EUR
    Ergebnis: Guthaben 85,00 EUR
    """]),

    // --- Insurance documents (six) and non-insurance decoys ---
    ("Documents/Versicherungen/hausrat_police.pdf", ["""
    Beispiel Versicherung AG · Policenstraße 1 · 12345 Musterstadt
    Versicherungsschein Hausratversicherung
    Versicherungsnummer: HR-4471-0815
    Versicherungsnehmerin: Maria Beispiel, Musterstraße 5, 12345 Musterstadt
    Versicherungsbeginn: 01.12.2023, 0 Uhr
    Ablauf: 30.11. eines jeden Jahres
    Jahresbeitrag: 96,00 EUR
    """, """
    Vertragsdauer und Kündigung
    Der Vertrag läuft ein Jahr und verlängert sich danach jeweils um ein weiteres Jahr, wenn er nicht gekündigt wird.
    Die Kündigung muss spätestens drei Monate vor Ablauf, also bis zum 31.08. eines Jahres, bei uns eingegangen sein.
    Die Kündigung bedarf der Textform (Brief, Fax oder E-Mail an kuendigung@beispiel-versicherung.example).
    """]),
    ("Documents/Versicherungen/phv.pdf", ["""
    Beispiel Versicherung AG
    Versicherungsschein Privathaftpflichtversicherung
    Versicherungsnummer: PH-2210-3344
    Versicherungsnehmerin: Maria Beispiel
    Deckungssumme: 10 Mio. EUR, Jahresbeitrag 58,00 EUR
    """]),
    ("Downloads/kfz_beitrag_2026.pdf", ["""
    Auto-Schutz Beispiel VVaG
    Beitragsrechnung Kfz-Versicherung 2026
    Fahrzeug: M-XY 123, Haftpflicht und Teilkasko
    Versicherungsnummer: KF-9981-22
    Jahresbeitrag 2026: 412,30 EUR, fällig am 01.01.2026
    """]),
    ("Desktop/scan_kk.pdf", ["""
    Beispiel BKK · Gesundheitsweg 2 · 12345 Musterstadt
    Mitgliedsbescheinigung
    Frau Maria Beispiel ist seit 01.04.2019 Mitglied der Beispiel BKK (gesetzliche Krankenversicherung).
    Versichertennummer: A123456789
    """]),
    ("\(icloud)/Versicherung/zzv.pdf", ["""
    Zahnplus Versicherung AG
    Versicherungsschein Zahnzusatzversicherung
    Tarif ZahnKomfort, Versicherungsnummer ZZ-55-7710
    Versicherte Person: Maria Beispiel, Monatsbeitrag 18,90 EUR
    """]),
    ("\(cloud)/rs_2025.pdf", ["""
    Recht & Ruhe Rechtsschutzversicherung AG
    Versicherungsschein Rechtsschutzversicherung
    Versicherungsnummer: RS-3003-1990, Beginn 01.01.2025
    Bausteine: Privat, Beruf, Wohnen. Jahresbeitrag 239,00 EUR
    """]),
    ("Documents/Haushalt/garantie_waschmaschine.pdf", ["""
    Herstellergarantie
    Waschmaschine WM 8000, gekauft am 02.05.2024
    Garantiezeit: 2 Jahre ab Kaufdatum. Bitte Kaufbeleg aufbewahren.
    """]),

    // --- Multi-page letter for summarising (no insurance) ---
    ("Downloads/Brief_Hausverwaltung.pdf", ["""
    Hausverwaltung Beispiel GmbH · Verwalterweg 1 · 12345 Musterstadt
    Frau Maria Beispiel, Musterstraße 5, 2. OG links, 12345 Musterstadt
    Musterstadt, 02.10.2026
    Ankündigung von Modernisierungsmaßnahmen nach § 555c BGB
    Sehr geehrte Frau Beispiel,
    hiermit kündigen wir an, dass in Ihrer Wohnung alle Fenster gegen neue, dreifach verglaste Fenster ausgetauscht werden.
    Die Arbeiten finden vom 12.01.2027 bis 16.01.2027 statt. Für Ihre Wohnung ist der 13.01.2027 vorgesehen,
    jeweils zwischen 8 und 16 Uhr. Die Arbeiten führt die Firma Glasbau Beispiel aus.
    """, """
    Was wir von Ihnen brauchen
    Bitte senden Sie uns den beiliegenden Rückmeldebogen bis spätestens 20.11.2026 ausgefüllt zurück.
    Darauf geben Sie an, ob Sie am 13.01.2027 selbst zu Hause sind oder wer uns die Wohnung öffnet.
    Bitte räumen Sie am Tag der Arbeiten die Fensterbänke frei und halten Sie etwa einen Meter vor den Fenstern frei.
    Möbel müssen nicht abgebaut werden; Böden werden von der Firma abgedeckt.
    """, """
    Auswirkungen auf die Miete
    Nach Abschluss der Arbeiten erhöht sich Ihre monatliche Grundmiete ab 01.04.2027 um 38,50 EUR.
    Die Betriebskostenvorauszahlung bleibt unverändert.
    Sie haben ein Sonderkündigungsrecht: Sie können bis zum Ablauf des Monats, der auf den Zugang dieser Mitteilung folgt,
    außerordentlich zum Ablauf des übernächsten Monats kündigen.
    Bei Fragen erreichen Sie Herrn Kurz unter 01234 567890.
    Mit freundlichen Grüßen
    Hausverwaltung Beispiel GmbH
    Anlage: Rückmeldebogen
    """]),

    // --- Letter with a deadline for the reminder task ---
    ("Downloads/Buergeramt_Abholung.pdf", ["""
    Stadt Musterstadt · Bürgeramt · Rathausplatz 1 · 12345 Musterstadt
    Frau Maria Beispiel, Musterstraße 5, 12345 Musterstadt
    Musterstadt, 06.10.2026
    Ihr Antrag vom 02.10.2026 – Reisepass zur Abholung bereit
    Sehr geehrte Frau Beispiel,
    Ihr neuer Reisepass liegt ab sofort zur Abholung im Bürgeramt bereit.
    Bitte holen Sie ihn spätestens bis zum 27.11.2026 persönlich ab und bringen Sie Ihren alten Reisepass mit.
    Öffnungszeiten: Montag bis Freitag 8 bis 12 Uhr, Donnerstag zusätzlich 14 bis 18 Uhr.
    Nicht abgeholte Dokumente werden nach Ablauf der Frist an die Bundesdruckerei zurückgegeben.
    Mit freundlichen Grüßen, Ihr Bürgeramt
    """]),
]

var manifest: [String: [String]] = [:]
var shown: [String: [String: Any]] = [:]
for (path, pages) in docs {
    let url = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let cleaned = pages.map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
    for page in cleaned {
        ctx.beginPDFPage(nil)
        let string = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    manifest[url.path] = cleaned
    // Size as PiShownContext.describe prints it, for the "shown" prompt of the summary and reminder tasks.
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    shown[url.path] = ["pages": cleaned.count, "size": ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)]
}
try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: base.appendingPathComponent(".agentic-corpus.json"))
try JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys, .prettyPrinted]).write(to: base.appendingPathComponent(".agentic-shown.json"))
print("\(docs.count) documents in \(home)")
