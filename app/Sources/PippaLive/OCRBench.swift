import AppKit
import CoreImage
import CoreText
import Foundation
import PDFKit
import PippaCore

/// OCR benchmark (FLOW-5): classic Vision text recognition (accurate/fast) against `RecognizeDocumentsRequest`
/// on synthetic scans with known text. Only synthetic documents.
///
///   PIPPA_LIVE=1 swift run -c release PippaLive ocr-bench <accurate|fast|documents> [runs]
///   PIPPA_LIVE=1 swift run -c release PippaLive ocr-bench parallel <engine>
///
/// One engine per process, so the first page is a cold start for that engine.
enum OCRBench {
    struct Fixture { var name: String; var image: CGImage; var truth: String; var tokens: [String] }

    static func run(_ args: [String]) {
        if args.first == "pdf" { pdf(); return }
        if args.first == "size", args.count >= 3, let w = Int(args[1]), let h = Int(args[2]) {
            // Is a first recognition at a new image size slow (model compiled per shape)?
            let image = draw(width: w, height: h) { text("Summe 23,45 EUR am 06.11.2026", size: CGFloat(h) / 40, at: CGPoint(x: 40, y: CGFloat(h) / 2), in: $0) }
            for i in 1...2 {
                let (wall, cpu, page) = measure { DocumentOCR.recognize(image, engine: DocumentOCR.preferred) }
                print(String(format: "  %dx%d run %d: %.2f s wall, %.2f s CPU, %@ (load %@)", w, h, i, wall, cpu, page.text, load()))
            }
            return
        }
        if args.first == "parallel" { parallel(engine: DocumentOCR.Engine(rawValue: args.dropFirst().first ?? "") ?? .documents); return }
        guard let engine = DocumentOCR.Engine(rawValue: args.first ?? "") else { print("ocr-bench <accurate|fast|documents> [runs]"); return }
        let runs = Int(args.dropFirst().first ?? "") ?? 3
        print("engine=\(engine.rawValue) load=\(load())")
        var first = true
        for fixture in fixtures() {
            var walls: [Double] = [], cpus: [Double] = []
            var page: DocumentOCR.Page?
            for run in 0..<(runs + 1) {
                let (wall, cpu, result) = measure { DocumentOCR.recognize(fixture.image, engine: engine) }
                if run == 0 {
                    if first { print(String(format: "  cold first page (%@): %.2f s wall, %.2f s CPU", fixture.name, wall, cpu)); first = false }
                    page = result
                    continue
                }
                walls.append(wall); cpus.append(cpu)
            }
            guard let page else { continue }
            let got = plain(page.text)
            let cer = Double(distance(Array(got), Array(plain(fixture.truth)))) / Double(max(1, plain(fixture.truth).count))
            let missing = fixture.tokens.filter { !got.contains($0) }
            print(String(format: "  %@ %dx%d: warm median %.2f s wall, %.2f s CPU, CER %.1f %%, tokens %d/%d, tables %d, lines %d, engine %@",
                         fixture.name, fixture.image.width, fixture.image.height, median(walls), median(cpus), cer * 100,
                         fixture.tokens.count - missing.count, fixture.tokens.count, page.tables, page.lineCount, page.engine.rawValue))
            if !missing.isEmpty { print("    missing: \(missing.joined(separator: " · "))") }
            if ProcessInfo.processInfo.environment["OCR_BENCH_DUMP"] == "1" { print("----\n\(page.text)\n----") }
        }
        print("load after=\(load())")
    }

    /// 5-page letter: one page after the other vs 2 and 3 at a time.
    static func parallel(engine: DocumentOCR.Engine) {
        let pages = (1...5).compactMap { letterPage($0).image }
        _ = DocumentOCR.recognize(pages[0], engine: engine)   // warm
        print("engine=\(engine.rawValue) load=\(load())")
        for width in [1, 2, 3] {
            let (wall, cpu, _) = measure { () -> Int in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = width
                for image in pages { queue.addOperation { _ = DocumentOCR.recognize(image, engine: engine) } }
                queue.waitUntilAllOperationsAreFinished()
                return 0
            }
            print(String(format: "  5 pages, %d at a time: %.2f s wall (%.2f s/page), %.2f s CPU", width, wall, wall / 5, cpu))
        }
        print("load after=\(load())")
    }

    /// End to end through TextReader: 5-page scanned PDF (300-dpi page images), first read and the same file again.
    static func pdf() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ocr-bench-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for n in 1...5 { ctx.beginPDFPage(nil); ctx.draw(letterPage(n).image, in: box); ctx.endPDFPage() }
        ctx.closePDF()
        print("engine=\(DocumentOCR.preferred.rawValue) load=\(load())")
        let options = TextReader.Options(maxPages: 12, ocr: true)
        for label in ["first read", "same file again"] {
            let (wall, cpu, doc) = measure { TextReader.read(url, options: options) }
            let tokens = (1...5).map { letterPage($0).tokens }.joined().filter { doc.fullText.contains($0) }.count
            print(String(format: "  %@: %.2f s wall (%.2f s/page), %.2f s CPU, %d pages, OCR %@, tokens %d/50",
                         label, wall, wall / 5, cpu, doc.pages.count, doc.usedOCR ? "yes" : "no", tokens))
        }
        print("load after=\(load())")
    }

    // MARK: Measuring

    static func measure<T>(_ body: () -> T) -> (Double, Double, T) {
        let c0 = cpuSeconds(), t0 = Date()
        let r = body()
        return (Date().timeIntervalSince(t0), cpuSeconds() - c0, r)
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func load() -> String {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return String(format: "%.1f/%.1f/%.1f", l[0], l[1], l[2])
    }

    static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

    /// Text without Markdown table syntax and with collapsed whitespace, for character error rate.
    static func plain(_ s: String) -> String {
        s.split(separator: "\n").filter { !$0.hasPrefix("| ---") }.joined(separator: " ")
            .replacingOccurrences(of: "|", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1..<(b.count + 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: Fixtures (synthetic)

    static func fixtures() -> [Fixture] {
        var all: [Fixture] = []
        // ToolChecks "Kleindruck": big heading, small print with umlauts, amount, date.
        let fine: [(String, CGFloat, CGFloat)] = [("Mietvertrag", 90, 1400), ("Müller Straße", 28, 1250), ("Betrag 312,50 EUR", 28, 1190), ("Bitte bis 06.11.2026 zahlen.", 28, 1130)]
        all.append(Fixture(name: "kleindruck", image: draw(width: 1200, height: 1600) { ctx in
            for (t, size, y) in fine { text(t, size: size, at: CGPoint(x: 70, y: y), in: ctx) }
        }, truth: fine.map(\.0).joined(separator: "\n"), tokens: ["Mietvertrag", "Müller Straße", "312,50", "06.11.2026"]))
        // Thought Line scan page.
        all.append(Fixture(name: "thoughtline", image: draw(width: 900, height: 1200) { ctx in
            text("Mietvertrag Seite 1", size: 90, at: CGPoint(x: 54, y: 1020), in: ctx)
            text("Kaution 1200 Euro", size: 90, at: CGPoint(x: 54, y: 840), in: ctx)
        }, truth: "Mietvertrag Seite 1\nKaution 1200 Euro", tokens: ["Mietvertrag Seite 1", "Kaution 1200 Euro"]))
        let letter = letterPage(1)
        all.append(Fixture(name: "brief-300dpi", image: letter.image, truth: letter.truth, tokens: letter.tokens))
        let invoice = invoicePage()
        all.append(Fixture(name: "rechnung-tabelle", image: invoice.image, truth: invoice.truth, tokens: invoice.tokens))
        all.append(Fixture(name: "handyfoto", image: phonePhoto(letter.image), truth: letter.truth, tokens: letter.tokens))
        return all
    }

    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        return ctx.makeImage()!
    }

    static func text(_ s: String, size: CGFloat, at p: CGPoint, in ctx: CGContext, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes) as CFAttributedString)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    /// A4 at 300 dpi (2480 × 3508), 11 pt body text.
    static func letterPage(_ n: Int) -> (image: CGImage, truth: String, tokens: [String]) {
        let body = [
            "Stadtwerke Großenhain GmbH · Kundenservice · Bahnhofstraße 12 · 01558 Großenhain",
            "Frau Jürgen-Weiß, Schloßallee 7, 80331 München",
            "München, den 0\(n).10.2026",
            "Betreff: Jahresabrechnung Strom und Gas, Kundennummer 4711-\(n)08",
            "Sehr geehrte Frau Jürgen-Weiß,",
            "anbei erhalten Sie Ihre Jahresabrechnung für den Zeitraum 01.01.2025 bis 31.12.2025.",
            "Ihr Verbrauch beträgt 3.412 kWh Strom und 11.870 kWh Gas. Gegenüber dem Vorjahr",
            "ist der Verbrauch um 4,7 % gesunken. Die monatlichen Abschläge betrugen 142,00 EUR.",
            "Aus der Abrechnung ergibt sich eine Nachzahlung in Höhe von 286,34 EUR.",
            "Bitte überweisen Sie den Betrag bis zum 14.11.2026 auf folgendes Konto:",
            "IBAN DE89 3704 0044 0532 0130 00 · BIC COBADEFFXXX · Commerzbank Köln",
            "Verwendungszweck: Rechnung 2026-\(n)417 / Kundennummer 4711-\(n)08",
            "Ab dem 01.12.2026 beträgt Ihr neuer Abschlag 155,00 EUR monatlich.",
            "Die Preisänderung beruht auf gestiegenen Netzentgelten gemäß § 41 EnWG.",
            "Sie haben ein Sonderkündigungsrecht bis zum 30.11.2026 (schriftlich oder per E-Mail).",
            "Fragen beantworten wir gern werktags von 8 bis 18 Uhr unter 0351 / 468-2290.",
            "Mit freundlichen Grüßen",
            "Ihre Stadtwerke Großenhain – Abteilung Abrechnung",
            "Seite \(n) von 5",
        ]
        let image = draw(width: 2480, height: 3508) { ctx in
            var y: CGFloat = 3208
            for (i, line) in body.enumerated() {
                text(line, size: 46, at: CGPoint(x: 236, y: y), in: ctx, bold: i == 3)
                y -= (i == 2 || i == 3 || i == 4 || i == 15 || i == 17) ? 140 : 76
            }
        }
        return (image, body.joined(separator: "\n"),
                ["Großenhain", "Jürgen-Weiß", "Schloßallee", "0\(n).10.2026", "286,34 EUR", "14.11.2026", "DE89 3704 0044 0532 0130 00", "Grüßen", "§ 41", "4,7 %"])
    }

    /// Invoice with a ruled 4-column table.
    static func invoicePage() -> (image: CGImage, truth: String, tokens: [String]) {
        let head = ["Rechnung Nr. 2026-0815", "Malerbetrieb Höß & Söhne, Fürstenweg 3, 90402 Nürnberg", "Rechnungsdatum: 02.10.2026"]
        let rows = [["Pos.", "Leistung", "Menge", "Betrag"],
                    ["1", "Wände streichen, Wohnzimmer", "42 m²", "630,00 €"],
                    ["2", "Decke spachteln und schleifen", "18 m²", "414,50 €"],
                    ["3", "Türrahmen lackieren (weiß)", "4 Stk.", "236,00 €"],
                    ["4", "Abdeckmaterial und Entsorgung", "1 psch.", "85,20 €"],
                    ["5", "Anfahrt München–Nürnberg", "2 x", "96,00 €"]]
        let foot = ["Nettobetrag 1.461,70 €", "zzgl. 19 % USt. 277,72 €", "Gesamtbetrag 1.739,42 €", "Zahlbar bis 16.10.2026 ohne Abzug. IBAN DE12 7605 0101 0001 2345 67"]
        let image = draw(width: 2480, height: 3508) { ctx in
            var y: CGFloat = 3208
            for (i, h) in head.enumerated() { text(h, size: i == 0 ? 70 : 46, at: CGPoint(x: 236, y: y), in: ctx, bold: i == 0); y -= 110 }
            y -= 60
            let xs: [CGFloat] = [236, 420, 1500, 1880, 2244]
            let rowH: CGFloat = 100
            let top = y + 70
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); ctx.setLineWidth(3)
            for r in 0...rows.count { ctx.move(to: CGPoint(x: xs[0], y: top - CGFloat(r) * rowH)); ctx.addLine(to: CGPoint(x: xs[4], y: top - CGFloat(r) * rowH)) }
            for x in xs { ctx.move(to: CGPoint(x: x, y: top)); ctx.addLine(to: CGPoint(x: x, y: top - CGFloat(rows.count) * rowH)) }
            ctx.strokePath()
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.enumerated() { text(cell, size: 44, at: CGPoint(x: xs[c] + 24, y: top - CGFloat(r) * rowH - 66), in: ctx, bold: r == 0) }
            }
            y = top - CGFloat(rows.count) * rowH - 140
            for f in foot { text(f, size: 46, at: CGPoint(x: f.hasPrefix("Zahlbar") ? 236 : 1500, y: y), in: ctx, bold: f.hasPrefix("Gesamt")); y -= 90 }
        }
        let truth = (head + rows.map { $0.joined(separator: " ") } + foot).joined(separator: "\n")
        return (image, truth, ["Höß", "Fürstenweg", "02.10.2026", "630,00 €", "414,50 €", "85,20 €", "1.739,42 €", "16.10.2026", "DE12 7605 0101 0001 2345 67", "42 m²"])
    }

    /// The letter page as a phone photo: slight perspective and rotation, warm paper, soft focus, noise, 12 MP JPEG.
    static func phonePhoto(_ page: CGImage) -> CGImage {
        let ci = CIImage(cgImage: page)
        let w = ci.extent.width, h = ci.extent.height
        let persp = ci.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 90, y: h - 40), "inputTopRight": CIVector(x: w - 30, y: h + 10),
            "inputBottomLeft": CIVector(x: 20, y: 60), "inputBottomRight": CIVector(x: w - 110, y: -20)])
            .transformed(by: CGAffineTransform(rotationAngle: 0.025))
        let canvas = CGRect(x: -200, y: -200, width: 3024, height: 4032)
        let paper = CIImage(color: CIColor(red: 0.55, green: 0.5, blue: 0.42)).cropped(to: canvas)
        var img = persp.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.97, y: 0, z: 0, w: 0),
                                                                    "inputGVector": CIVector(x: 0, y: 0.93, z: 0, w: 0),
                                                                    "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0)])
            .composited(over: paper)
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.6])
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: canvas)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0.06, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputBiasVector": CIVector(x: -0.03, y: -0.03, z: -0.03, w: 1)])
        img = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: canvas)
        let context = CIContext()
        let cg = context.createCGImage(img, from: canvas)!
        // Round-trip through JPEG like a camera would.
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data, nil)!
        // Pippa reads images as thumbnails of at most 3000 px (TextReader.loadCGImage).
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 3000] as CFDictionary)!
    }
}
