import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Realistic German test corpus (system frameworks only: CoreText for PDFs, CoreGraphics for images).
/// The ground truth is in `Truth` so `LiveRun` can check results.
enum Corpus {
    struct InvoiceTruth { var file: String; var date: String; var senderNeedle: String; var amount: Decimal }

    static let invoices: [InvoiceTruth] = [
        InvoiceTruth(file: "Rechnung_2026_08.pdf", date: "12.08.2026", senderNeedle: "stadtwerke", amount: Decimal(string: "84.20")!),
        InvoiceTruth(file: "RE_4711083920.pdf", date: "03.09.2026", senderNeedle: "telekom", amount: Decimal(string: "39.95")!),
        InvoiceTruth(file: "Scan_20260721.pdf", date: "21.07.2026", senderNeedle: "hoffmann", amount: Decimal(string: "1234.56")!),
        InvoiceTruth(file: "Scan Kassenbon.png", date: "14.08.2026", senderNeedle: "apotheke", amount: Decimal(string: "23.45")!),
    ]
    static let lease = "Mietvertrag Lindenstraße.pdf"
    static let letter = "Brief Hausverwaltung.pdf"
    static let mobile = "Vertrag Mobilfunk.pdf"
    static let mail = "Terminbestätigung.eml"

    static func build(at dir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        pdf(dir.appendingPathComponent("Rechnung_2026_08.pdf"), [stadtwerke])
        pdf(dir.appendingPathComponent("RE_4711083920.pdf"), telekom)
        pdf(dir.appendingPathComponent("Scan_20260721.pdf"), [zahnarzt])
        pdf(dir.appendingPathComponent(lease), leasePages)
        pdf(dir.appendingPathComponent(letter), [hausverwaltung])
        pdf(dir.appendingPathComponent(mobile), mobilfunk)
        pdf(dir.appendingPathComponent("download.pdf"), [flyer])
        pdf(dir.appendingPathComponent("Dokument (3).pdf"), [""])     // blank page, like a failed scan
        try mailText.write(to: dir.appendingPathComponent(mail), atomically: true, encoding: .utf8)
        scan(kassenbon, to: dir.appendingPathComponent("Scan Kassenbon.png"))
        let shots: [(String, String, CGColor)] = [
            ("IMG_4021.JPG", "2026:07:14 10:22:01", CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)),
            ("IMG_4022.JPG", "2026:07:14 10:25:43", CGColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1)),
            ("IMG_4100.JPG", "2026:08:02 18:01:10", CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1)),
            ("IMG_4101.JPG", "2025:12:24 19:45:00", CGColor(red: 0.7, green: 0.2, blue: 0.2, alpha: 1)),
        ]
        for (name, date, color) in shots { photo(dir.appendingPathComponent(name), date: date, color: color) }
    }

    // MARK: Texts

    static let stadtwerke = """
    Stadtwerke Lindau GmbH · Kemptener Straße 23 · 88131 Lindau

    Frau
    Anna Becker
    Lindenstraße 5
    88131 Lindau

    Rechnung Strom
    Rechnungsnummer: 2026-118734
    Kundennummer: 40 118 223
    Rechnungsdatum: 12.08.2026
    Abrechnungszeitraum: 01.07.2026 – 31.07.2026

    Arbeitspreis 214 kWh × 0,2890 €            61,85 €
    Grundpreis Juli                              8,91 €
    Nettobetrag                                 70,76 €
    zzgl. 19 % MwSt.                            13,44 €
    Gesamtbetrag                                84,20 €

    Der Gesamtbetrag wird am 26.08.2026 von Ihrem Konto DE12 7335 0000 0000 4711 08 abgebucht.
    Vielen Dank, dass Sie Strom aus Lindau beziehen.
    """

    static let telekom = [
        """
        Telekom Deutschland GmbH
        Postfach 30 00 · 53105 Bonn

        Anna Becker · Lindenstraße 5 · 88131 Lindau

        Ihre Rechnung für September 2026
        Rechnungsnummer 4711 0839 20
        Kundennummer 552 001 877 4
        Datum 03.09.2026

        Seite 1 von 2

        Zusammenfassung
        MagentaZuhause M (Festnetz und Internet)      33,57 €
        Summe netto                                   33,57 €
        Umsatzsteuer 19 %                              6,38 €
        Rechnungsbetrag                               39,95 €

        Der Rechnungsbetrag wird frühestens am 10.09.2026 von Ihrem Konto abgebucht.
        """,
        """
        Seite 2 von 2
        Einzelverbindungsnachweis
        Keine kostenpflichtigen Verbindungen im Abrechnungszeitraum.
        Fragen zur Rechnung? telekom.de/hilfe oder 0800 33 01000.
        """,
    ]

    static let zahnarzt = """
    Zahnarztpraxis Dr. med. dent. Julia Hoffmann
    Bahnhofplatz 2 · 88131 Lindau · Tel. 08382 55 21 0

    Frau Anna Becker
    Lindenstraße 5
    88131 Lindau

    Lindau, 21.07.2026

    Liquidation nach GOZ – Rechnung Nr. 2026/0712
    Behandlungszeitraum 02.06.2026 bis 15.07.2026

    GOZ 2210 Vollkrone (Tangentialpräparation)      1 x    1.012,73 €
    GOZ 2197 Adhäsive Befestigung                     1 x       16,82 €
    Material- und Laborkosten (§ 9 GOZ)                       205,01 €

    Rechnungsbetrag                                         1.234,56 €

    Bitte überweisen Sie den Betrag innerhalb von 30 Tagen nach Erhalt dieser Rechnung.
    IBAN DE44 7315 0000 0120 3344 55 · Sparkasse Memmingen-Lindau-Mindelheim
    """

    static let leasePages = [
        """
        Mietvertrag über Wohnraum

        zwischen
        Hausverwaltung Berger & Söhne GmbH, Seestraße 12, 88131 Lindau
        – im Folgenden „Vermieterin“ –
        und
        Anna Becker, bisher wohnhaft in Kempten
        – im Folgenden „Mieterin“ –

        § 1 Mietsache
        Vermietet wird die Wohnung im 2. Obergeschoss links des Hauses Lindenstraße 5, 88131 Lindau, bestehend aus drei Zimmern, Küche, Bad und Balkon. Die Wohnfläche beträgt 74 Quadratmeter.
        """,
        """
        § 2 Mietzeit
        Das Mietverhältnis beginnt am 01.04.2021 und läuft auf unbestimmte Zeit.

        § 3 Miete und Nebenkosten
        Die monatliche Grundmiete beträgt 820,00 €. Zusätzlich zahlt die Mieterin eine Vorauszahlung auf die Betriebskosten von 190,00 € monatlich. Über die Vorauszahlungen wird jährlich abgerechnet.
        Die Miete ist monatlich im Voraus, spätestens am dritten Werktag des Monats, auf das Konto der Vermieterin zu zahlen.
        """,
        """
        § 4 Kaution
        Die Mieterin leistet eine Mietsicherheit in Höhe von drei Monatsmieten, also 2.460,00 €. Die Kaution kann in drei gleichen monatlichen Teilzahlungen erbracht werden.

        § 5 Schönheitsreparaturen
        Die Mieterin übernimmt keine Schönheitsreparaturen. Kleine Instandhaltungen bis 100,00 € je Einzelfall trägt die Mieterin, höchstens jedoch 8 % der Jahresgrundmiete.

        § 6 Tierhaltung
        Kleintiere sind erlaubt. Für Hunde und Katzen ist die vorherige schriftliche Zustimmung der Vermieterin nötig.
        """,
        """
        § 9 Kündigung
        Das Mietverhältnis kann von der Mieterin schriftlich mit einer Kündigungsfrist von drei Monaten zum Monatsende gekündigt werden. Für die Vermieterin gelten die gesetzlichen Fristen nach § 573c BGB.
        Die Kündigung muss spätestens am dritten Werktag eines Kalendermonats zugehen.

        § 10 Schlüssel
        Die Mieterin erhält zwei Haustür- und zwei Wohnungsschlüssel sowie einen Briefkastenschlüssel.
        """,
        """
        § 11 Sonstiges
        Änderungen und Ergänzungen dieses Vertrages bedürfen der Schriftform.

        Lindau, den 14.03.2021

        Hausverwaltung Berger & Söhne GmbH            Anna Becker
        (Vermieterin)                                  (Mieterin)
        """,
    ]

    static let hausverwaltung = """
    Hausverwaltung Berger & Söhne GmbH
    Seestraße 12 · 88131 Lindau · Telefon 08382 94 11 0

    Frau Anna Becker
    Lindenstraße 5, 2. OG links
    88131 Lindau

    Lindau, 22.09.2026

    Nebenkostenabrechnung für das Jahr 2025
    Objekt: Lindenstraße 5, Wohnung 2. OG links

    Sehr geehrte Frau Becker,

    anbei erhalten Sie die Abrechnung der Betriebskosten für den Zeitraum 01.01.2025 bis 31.12.2025.

    Gesamtkosten Ihrer Wohnung                     2.592,48 €
    abzüglich Ihrer Vorauszahlungen (12 × 190,00 €) 2.280,00 €
    Nachzahlung                                      312,48 €

    Bitte überweisen Sie die Nachzahlung in Höhe von 312,48 € bis zum 31.10.2026 auf unser Konto bei der Sparkasse Memmingen-Lindau-Mindelheim, IBAN DE21 7315 0000 0099 8877 66.
    Ab dem 01.01.2027 beträgt Ihre monatliche Vorauszahlung 215,00 €.

    Einwände gegen diese Abrechnung können Sie innerhalb von zwölf Monaten nach Zugang erheben.

    Mit freundlichen Grüßen
    Hausverwaltung Berger & Söhne
    """

    static let mobilfunk = [
        """
        Vodafone GmbH · Ferdinand-Braun-Platz 1 · 40549 Düsseldorf

        Vertragszusammenfassung Mobilfunkvertrag
        Kundin: Anna Becker, Lindenstraße 5, 88131 Lindau
        Vertragsnummer: MF-2025-338120
        Datum: 18.02.2025

        Tarif: GigaMobil S, 15 GB Datenvolumen, Allnet-Flat
        Monatlicher Grundpreis: 29,99 €
        Einmaliger Bereitstellungspreis: 39,99 €

        Vertragsbeginn: 01.03.2025
        Mindestvertragslaufzeit: 24 Monate. Die Mindestvertragslaufzeit endet am 28.02.2027.
        """,
        """
        Kündigung
        Der Vertrag kann mit einer Frist von einem Monat zum Ende der Mindestvertragslaufzeit gekündigt werden. Danach verlängert er sich auf unbestimmte Zeit und ist jederzeit mit einer Frist von einem Monat kündbar.
        """,
    ]

    static let flyer = """
    Sommerfest im Kleingartenverein Aeschach e.V.
    Samstag, 12. September 2026, ab 14 Uhr
    Kaffee und Kuchen, Flohmarkt, Kinderschminken.
    Wer einen Kuchen mitbringen mag, trägt sich bitte bis 05.09.2026 in die Liste am Vereinsheim ein.
    """

    static let kassenbon = """
    Apotheke am Markt
    Maximilianstraße 9
    88131 Lindau
    Tel. 08382 4321

    14.08.2026  10:41  Kasse 2

    Ibuprofen 400 akut 20 St.     5,95
    Bepanthen Wundsalbe 20 g      6,50
    Sonnencreme LSF 50           11,00

    SUMME EUR                    23,45
    Bar                          30,00
    Rückgeld                      6,55

    MwSt 19 %  netto 19,71  MwSt 3,74
    Vielen Dank und gute Besserung!
    """

    static let mailText = """
    From: Zahnarztpraxis Dr. Hoffmann <praxis@zahnarzt-hoffmann-lindau.de>
    To: Anna Becker <anna.becker@example.org>
    Date: Mon, 28 Sep 2026 09:12:44 +0200
    Subject: =?utf-8?Q?Terminbest=C3=A4tigung_Kontrolltermin?=
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Liebe Frau Becker,

    hiermit best=C3=A4tigen wir Ihren Kontrolltermin am 15.10.2026 um 10:30 Uhr.
    Bitte bringen Sie Ihre Versichertenkarte mit. Falls Sie den Termin nicht wahrnehmen k=C3=B6nnen, sagen Sie bitte bis 13.10.2026 ab.

    Viele Gr=C3=BC=C3=9Fe
    Ihr Praxisteam Dr. Hoffmann
    """

    // MARK: Generation

    static func pdf(_ url: URL, _ pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        let font = NSFont(name: "Helvetica", size: 10.5) ?? NSFont.systemFont(ofSize: 10.5)
        for page in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: page, attributes: [.font: font])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Text as an image, slightly skewed and grey like a phone scan, without photo data.
    static func scan(_ text: String, to url: URL) {
        let w = 1100, h = 1500
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: 0.012)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        let font = NSFont(name: "Courier", size: 30) ?? NSFont.monospacedSystemFont(ofSize: 30, weight: .regular)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 120, y: 80, width: w - 200, height: h - 160), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static func photo(_ url: URL, date: String, color: CGColor) {
        let w = 640, h = 480
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.5)); ctx.fillEllipse(in: CGRect(x: 200, y: 140, width: 240, height: 200))
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifDateTimeDigitized: date],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 15", kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFDateTime: date],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
