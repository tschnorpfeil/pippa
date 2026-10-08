import CoreGraphics
import Foundation
import PDFKit
import PippaCore

/// Text recognition (PippaCore/DocumentOCR.swift): tables as Markdown without invented cells, fallback to the classic
/// request, scanned PDF pages recognized once per session. Speed only with PIPPA_PERF=1.
func runOCRChecks() async {
    typealias Cell = DocumentOCR.TableCell

    check("OCR table: cells as Markdown, missing and spanned cells stay empty, | is escaped") {
        let cells = [Cell(row: 0, column: 0, text: "Leistung"), Cell(row: 0, column: 1, text: "Betrag"), Cell(row: 0, column: 2, text: "Notiz"),
                     Cell(row: 1, column: 0, text: "Wände streichen"), Cell(row: 1, column: 1, text: "630,00 €"),
                     Cell(row: 2, column: 0, text: "Decke\nspachteln"), Cell(row: 2, column: 2, text: "a|b")]
        return DocumentOCR.markdownTable(cells) == """
            | Leistung | Betrag | Notiz |
            | --- | --- | --- |
            | Wände streichen | 630,00 € |  |
            | Decke spachteln |  | a\\|b |
            """
    }
    check("OCR table: below 2 × 2 or without text no table (stays running text)") {
        DocumentOCR.markdownTable([Cell(row: 0, column: 0, text: "a"), Cell(row: 1, column: 0, text: "b")]) == nil
            && DocumentOCR.markdownTable([Cell(row: 0, column: 0, text: ""), Cell(row: 1, column: 1, text: " ")]) == nil
            && DocumentOCR.markdownTable([]) == nil
    }
    check("OCR layout: table sits between the lines above and below, its lines not duplicated") {
        let lines: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.1, y: 0.90, width: 0.3, height: 0.02), "Rechnung 2026-0815"),
            (CGRect(x: 0.1, y: 0.60, width: 0.2, height: 0.02), "Leistung"),     // inside the table
            (CGRect(x: 0.6, y: 0.10, width: 0.3, height: 0.02), "1.739,42 €"),
            (CGRect(x: 0.1, y: 0.10, width: 0.3, height: 0.02), "Gesamtbetrag"),
        ]
        let table = (box: CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.3), markdown: "| Leistung | Betrag |\n| --- | --- |\n| Wände | 630,00 € |")
        return DocumentOCR.layout(lines: lines, tables: [table]) == """
            Rechnung 2026-0815

            | Leistung | Betrag |
            | --- | --- |
            | Wände | 630,00 € |

            Gesamtbetrag 1.739,42 €
            """
    }

    let image = ToolFixtures.textImage(["Summe 23,45 EUR", "Fällig 06.11.2026"], width: 1200, height: 900)
    check("OCR: accurate recognition reads amount, date and umlaut (default path, also macOS 15)") {
        guard let image else { return false }
        let page = DocumentOCR.recognize(image, engine: .accurate)
        return page.engine == .accurate && page.text.contains("23,45") && page.text.contains("06.11.2026") && page.text.contains("Fällig")
    }
    check("OCR: document recognition from macOS 26, else fallback to the classic one, same words") {
        guard let image else { return false }
        let page = DocumentOCR.recognize(image, engine: .documents)
        let expected: DocumentOCR.Engine
        if #available(macOS 26, *) { expected = .documents } else { expected = .accurate }
        return page.engine == expected && page.text.contains("23,45") && page.text.contains("06.11.2026")
    }
    check("OCR: image without readable content under document recognition returns empty text instead of an error") {
        guard let blank = ToolFixtures.textImage([], width: 8, height: 8) else { return false }
        return DocumentOCR.recognize(blank, engine: .documents).text.isEmpty
    }

    await checkAsync("OCR: scanned PDF is recognized only once per session; changed file anew") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = folder.appendingPathComponent("Scan.pdf")
        func write(_ marker: String) -> Bool {
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let ctx = CGContext(scan as CFURL, mediaBox: &box, nil) else { return false }
            for page in 1...3 {
                ctx.beginPDFPage(nil)
                if let image = ToolFixtures.textImage(["Mietvertrag Seite \(page)", "Kaution \(marker) Euro"], width: 900, height: 1200) { ctx.draw(image, in: box) }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            return true
        }
        guard write("1200") else { return false }
        let pages = LockedBox<[Int]>([])
        var options = TextReader.Options(maxPages: 12, ocr: true)
        options.onRecognize = { page, _ in pages.mutate { $0.append(page) } }
        let first = TextReader.read(scan, options: options)
        let firstPages = pages.value
        let again = TextReader.read(scan, options: options)
        guard write("1350") else { return false }
        let changed = TextReader.read(scan, options: options)
        return firstPages == [1, 2, 3] && pages.value == [1, 2, 3, 1, 2, 3]
            && first.usedOCR && again.usedOCR && again.pages == first.pages
            && first.pages.enumerated().allSatisfy { $0.element.contains("Seite \($0.offset + 1)") }
            && first.fullText.contains("1200") && changed.fullText.contains("1350") && !changed.fullText.contains("1200")
    }

    // Only on request (PIPPA_PERF=1, not in CI): read 5 scanned pages; target first line ≤ 3 s, whole page ≤ 2 s.
    if ProcessInfo.processInfo.environment["PIPPA_PERF"] == "1" {
        await checkAsync("OCR speed: read 5 scanned pages (300 dpi)") {
            let scan = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-ocr-perf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: scan) }
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let ctx = CGContext(scan as CFURL, mediaBox: &box, nil) else { return false }
            for page in 1...5 {
                ctx.beginPDFPage(nil)
                let lines = (1...6).map { "Zeile \($0) auf Seite \(page): Nachzahlung 286,34 EUR bis 14.11.2026, Größe ß" }
                if let image = ToolFixtures.textImage(lines, width: 2480, height: 3508) { ctx.draw(image, in: box) }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            let started = Date()
            let doc = TextReader.read(scan, options: TextReader.Options(maxPages: 12, ocr: true))
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "  5 pages: %.2f s (%.2f s/page, load %.1f, engine %@)", seconds, seconds / 5, load[0], DocumentOCR.preferred.rawValue))
            return doc.pages.count == 5 && doc.usedOCR && seconds / 5 <= 2
        }
    }
}
