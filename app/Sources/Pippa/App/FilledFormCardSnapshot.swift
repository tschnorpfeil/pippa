import AppKit
import PDFKit
import PippaCore
import SwiftUI

#if DEBUG
/// The filled form card at 400 points, for a synthetic copy in the results folder. No save panel, viewer, model or
/// personal file.
@MainActor enum FilledFormCardSnapshot {
    static func run(directory: URL) async -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): filled form card \(name)") }
        do {
            let file = try ResultsFolder.fresh().appendingPathComponent("Mitgliedsantrag Sportverein (ausgefüllt).pdf")
            try makePDF(at: file)
            let card = FilledFormCard(file: file, source: "Mitgliedsantrag Sportverein.pdf", pageCount: 1, filled: 6,
                                      stillEmpty: ["Telefon (tagsüber)", "Unterschrift", "Datum"])
            check(ResultsFolder.contains(file) && PDFDocument(url: file)?.pageCount == 1, "copy is a PDF in the results folder")
            let stored = try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(ResultCard.filledForm(card)))
            check(stored == .filledForm(card), "survives storage with the answer")
            await render(card, name: "filled-form-card", directory: directory, checks: &checks)
        } catch { check(false, "fixture: \(error)") }
        return checks
    }

    private static func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Mitgliedsantrag" as NSString).draw(at: NSPoint(x: 30, y: 440), withAttributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
    }

    /// Like ChartCardSnapshot.render: the card at 400 points in a window, captured as PNG.
    private static func render(_ card: FilledFormCard, name: String, directory: URL, checks: inout [String]) async {
        let host = NSHostingView(rootView: FilledFormCardView(card: card).padding(12).frame(width: 400).background(Theme.paper))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = host; panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(200))
        let size = host.fittingSize
        checks.append("\(size.width <= 400.5 && size.height < 700 ? "PASS" : "FAIL"): \(name) fits 400 points")
        host.frame = NSRect(x: 0, y: 0, width: 400, height: ceil(size.height)); panel.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { checks.append("FAIL: \(name) renders"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { checks.append("FAIL: \(name) capture"); return }
        do { try png.write(to: directory.appendingPathComponent(name + ".png")); checks.append("PASS: \(name) captured") }
        catch { checks.append("FAIL: \(name) capture file") }
    }
}
#endif
