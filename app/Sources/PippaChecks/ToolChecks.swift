import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// Failure of a tool run, nil on success (or on a different error).
private func toolFailure(_ tool: ToolID, _ inputs: [URL], passwords: [URL: String] = [:]) async -> ToolFailure? {
    do {
        _ = try await OneAnswerTools.run(tool, inputs: inputs, passwords: passwords)
        return nil
    } catch let failure as ToolFailure {
        return failure
    } catch {
        return nil
    }
}

private func pdfText(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }

/// One-answer tools: results only in the results folder, originals unchanged.
func runToolChecks() async {
    // Results go to the check folder instead of ~/Library/Caches (like PIPPA_LOG_DIR).
    let results = dir("tools-results")
    setenv("PIPPA_RESULTS_DIR", results.path, 1)

    let folder = dir("tools")
    let png = folder.appendingPathComponent("Mietvertrag.png")
    let jpeg = folder.appendingPathComponent("Seite 2.jpg")
    let sideways = folder.appendingPathComponent("Quer.jpg")
    let heic = folder.appendingPathComponent("IMG_0001.heic")
    let video = folder.appendingPathComponent("video.mov")
    let letter = folder.appendingPathComponent("Brief.pdf")
    let noise = folder.appendingPathComponent("Rauschen.pdf")
    let locked = folder.appendingPathComponent("Geschützt.pdf")
    let bigPhoto = folder.appendingPathComponent("Groß.jpg")
    let tiny = folder.appendingPathComponent("Punkt.png")

    let text = ["Mietvertrag", "Pippa 4711"]
    ToolFixtures.writeImage(ToolFixtures.textImage(text, width: 1200, height: 1600), type: .png, to: png)
    ToolFixtures.writeImage(ToolFixtures.textImage(text, width: 1200, height: 1600), type: .jpeg, to: jpeg)
    // Shot sideways, EXIF 6: displayed upright.
    ToolFixtures.writeImage(ToolFixtures.textImage(text, width: 1600, height: 1000), type: .jpeg, to: sideways, orientation: 6)
    let hasHEIC = ToolFixtures.canWriteHEIC
        && ToolFixtures.writeImage(ToolFixtures.textImage(text, width: 1600, height: 1000), type: .heic, to: heic, orientation: 6)
    write("kein Video", video)
    makePDF(["Brief Seite eins", "Brief Seite zwei"], at: letter)
    ToolFixtures.noisePDF(pages: 2, at: noise)
    ToolFixtures.lockedPDF(["Geheim Seite eins", "Geheim Seite zwei"], password: "pw", at: locked)
    ToolFixtures.writeImage(ToolFixtures.noiseImage(width: 3000, height: 2000, seed: 42), type: .jpeg, to: bigPhoto, quality: 1.0)
    ToolFixtures.writeImage(ToolFixtures.textImage([], width: 16, height: 16), type: .png, to: tiny)

    var inputs = [png, jpeg, sideways, video, letter, noise, locked, bigPhoto, tiny]
    if hasHEIC { inputs.append(heic) }
    let before = inputs.map { ToolFixtures.identity($0) }

    // MARK: IDs, accepted inputs, texts

    check("Tools: IDs as in the task log, titles not empty, Codable") {
        let ids = ToolID.allCases.map(\.rawValue)
        let data = try JSONEncoder().encode(ToolID.allCases)
        let back = try JSONDecoder().decode([ToolID].self, from: data)
        return ids == ["make-one-pdf", "make-smaller", "as-pdf", "as-jpg", "as-png"] && back == ToolID.allCases
            && ToolID.allCases.allSatisfy { !$0.title.isEmpty && !$0.workingTitle.isEmpty }
    }
    check("Tools: what they accept") {
        OneAnswerTools.accepts(.makeOnePDF, png) && OneAnswerTools.accepts(.makeOnePDF, letter) && !OneAnswerTools.accepts(.makeOnePDF, video)
            && OneAnswerTools.accepts(.asPDF, jpeg) && !OneAnswerTools.accepts(.asPDF, letter) && !OneAnswerTools.accepts(.asJPEG, letter)
            && OneAnswerTools.accepts(.makeSmaller, letter) && OneAnswerTools.accepts(.makeSmaller, noise) && !OneAnswerTools.accepts(.makeSmaller, folder)
    }
    check("Tools: every failure is one sentence, without a path") {
        let failures: [ToolFailure] = [.locked(locked), .wrongPassword(locked), .nothingUsable(skipped: [FileReason(name: "video.mov", why: "x")]),
                                       .nothingUsable(skipped: []), .alreadySmall, .notEnoughSpace, .unreadable(name: "kaputt.pdf")]
        return failures.allSatisfy { f in
            guard let s = f.errorDescription else { return false }
            return !s.isEmpty && !s.contains(folder.path)
        } && ToolFailure.nothingUsable(skipped: [FileReason(name: "video.mov", why: "x")]).errorDescription?.contains("video.mov") == true
    }

    await checkAsync("Tools: same-named sources stay distinguishable by their URL") {
        let good = dir("tools-same-good").appendingPathComponent("Scan.jpg")
        let bad = dir("tools-same-bad").appendingPathComponent("Scan.jpg")
        guard ToolFixtures.writeImage(ToolFixtures.textImage(["Test"], width: 200, height: 200), type: .jpeg, to: good) else { return false }
        write("not an image", bad)
        let output = try await OneAnswerTools.run(.asPNG, inputs: [good, bad])
        return output.files.count == 1 && output.consumedInputs == [good]
            && output.skipped.map(\.name) == ["Scan.jpg"]
            && fm.fileExists(atPath: good.path) && fm.fileExists(atPath: bad.path)
    }

    await checkAsync("Tools: cancelling at the last progress step releases no result") {
        let task = Task {
            try await OneAnswerTools.run(.asPNG, inputs: [jpeg]) { progress in
                if progress.done == progress.total {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; return false }
        catch is CancellationError { return true }
    }

    // MARK: Names

    check("Names: German and English, PDFs only \"Combined\", single files with a suffix") {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 6; parts.hour = 12
        guard let date = Calendar(identifier: .gregorian).date(from: parts) else { return false }
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        let pdf = URL(fileURLWithPath: "/tmp/Brief.pdf"), photo = URL(fileURLWithPath: "/tmp/IMG_0001.heic")
        return ResultNaming.name(for: .makeOnePDF, inputs: [png, jpeg], date: date, locale: de) == "Scans 06.10.2026.pdf"
            && ResultNaming.name(for: .makeOnePDF, inputs: [png, pdf], date: date, locale: en) == "Scans 2026-10-06.pdf"
            && ResultNaming.name(for: .makeOnePDF, inputs: [pdf, pdf], date: date, locale: en) == "Combined 2026-10-06.pdf"
            && ResultNaming.name(for: .makeSmaller, inputs: [pdf], date: date, locale: en) == "Brief (smaller).pdf"
            && ResultNaming.name(for: .makeSmaller, inputs: [pdf], date: date, locale: de) == "Brief (kleiner).pdf"
            && ResultNaming.name(for: .asJPEG, inputs: [photo], date: date, locale: en) == "IMG_0001.jpg"
            && ResultNaming.name(for: .asPDF, inputs: [URL(fileURLWithPath: "/tmp/../a:b.png")], date: date, locale: en) == "a-b.pdf"
    }

    // MARK: One PDF

    await checkAsync("OCR: large heading and fine print with umlauts, amount and date stay searchable") {
        let input = dir("tools-fineprint").appendingPathComponent("Kleindruck.png")
        guard let ctx = CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        let rows: [(String, CGFloat, CGFloat)] = [
            ("Mietvertrag", 90, 1400),
            ("Müller Straße", 28, 1250),
            ("Betrag 312,50 EUR", 28, 1190),
            ("Bitte bis 06.11.2026 zahlen.", 28, 1130),
        ]
        for (text, size, y) in rows {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            ctx.textPosition = CGPoint(x: 70, y: y)
            CTLineDraw(line, ctx)
        }
        guard ToolFixtures.writeImage(ctx.makeImage(), type: .png, to: input) else { return false }
        let original = ToolFixtures.identity(input)
        let output = try await OneAnswerTools.run(.asPDF, inputs: [input])
        guard let file = output.files.first, let document = PDFDocument(url: file) else { return false }
        let recognized = (document.string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return document.pageCount == 1 && recognized.contains("Mietvertrag") && recognized.contains("Müller Straße")
            && recognized.contains("312,50") && recognized.contains("06.11.2026")
            && ToolFixtures.identity(input).sha == original.sha
            && original.fingerprint?.matches(FileFingerprint.of(input)) == true
    }

    await checkAsync("One PDF: 3 images → 1 PDF with 3 pages, searchable, in the results folder") {
        let log = ToolProgressLog()
        let third = hasHEIC ? heic : sideways
        let output = try await OneAnswerTools.run(.makeOnePDF, inputs: [png, jpeg, third]) { log.add($0) }
        guard output.files.count == 1, let file = output.files.first, let doc = PDFDocument(url: file),
              let last = doc.page(at: 2) else { return false }
        let bounds = last.bounds(for: .mediaBox)
        print("  One PDF: \(ToolFixtures.size(file) / 1024) KB, \(file.lastPathComponent)")
        return doc.pageCount == 3 && (doc.string ?? "").contains("4711")
            && ResultsFolder.contains(file) && !ResultsFolder.contains(png)
            && file.pathExtension == "pdf" && file.lastPathComponent.hasPrefix("Scans ")
            && output.summary == file.lastPathComponent && output.skipped.isEmpty && output.skippedSentence == nil
            && bounds.height > bounds.width          // EXIF 6 applied: upright
            && log.all.last == ToolProgress(done: 3, total: 3)
    }
    await checkAsync("One PDF: mixed with video and PDF → video named, pages in order") {
        let output = try await OneAnswerTools.run(.makeOnePDF, inputs: [png, video, letter])
        guard let file = output.files.first, let doc = PDFDocument(url: file) else { return false }
        let firstPage = doc.page(at: 0)?.string ?? ""
        let secondPage = doc.page(at: 1)?.string ?? ""
        return doc.pageCount == 3 && output.skipped.map(\.name) == ["video.mov"]
            && output.skippedSentence?.contains("video.mov") == true
            && firstPage.contains("4711") && secondPage.contains("Brief Seite eins")
    }
    await checkAsync("One PDF: only a video → \"nothingUsable\" with name") {
        await toolFailure(.makeOnePDF, [video]) == .nothingUsable(skipped: [FileReason(name: "video.mov", why: L("I can only turn images and PDFs into a PDF.", table: "Tools"))])
    }
    await checkAsync("One PDF: locked → asks, wrong password → keeps asking, correct → continues") {
        let ask = await toolFailure(.makeOnePDF, [png, locked])
        let wrong = await toolFailure(.makeOnePDF, [png, locked], passwords: [locked: "falsch"])
        let output = try await OneAnswerTools.run(.makeOnePDF, inputs: [png, locked], passwords: [locked: "pw"])
        guard let file = output.files.first, let doc = PDFDocument(url: file) else { return false }
        return ask == .locked(locked) && wrong == .wrongPassword(locked)
            && doc.pageCount == 3 && !doc.isLocked && (doc.string ?? "").contains("Geheim Seite zwei")
    }
    await checkAsync("One PDF: cancelled → CancellationError") {
        let task = Task { try await OneAnswerTools.run(.makeOnePDF, inputs: [png, jpeg]) }
        task.cancel()
        do { _ = try await task.value; return false } catch is CancellationError { return true }
    }

    // MARK: Smaller

    await checkAsync("Smaller: noise PDF gets smaller, pages stay") {
        let output = try await OneAnswerTools.run(.makeSmaller, inputs: [noise])
        guard let file = output.files.first, let doc = PDFDocument(url: file) else { return false }
        print("  Smaller: \(ToolFixtures.size(noise) / 1024) KB → \(ToolFixtures.size(file) / 1024) KB")
        return ToolFixtures.size(file) < ToolFixtures.size(noise) && doc.pageCount == 2
            && file.lastPathComponent == ResultNaming.name(for: .makeSmaller, inputs: [noise]) && ResultsFolder.contains(file)
    }
    await checkAsync("Smaller: large photo → ≤ 2048 px, smaller, orientation 1") {
        let output = try await OneAnswerTools.run(.makeSmaller, inputs: [bigPhoto])
        guard let file = output.files.first else { return false }
        let size = ToolFixtures.pixelSize(file)
        return ToolFixtures.size(file) < ToolFixtures.size(bigPhoto) && max(size.width, size.height) <= 2048 && size.orientation == 1
            && ToolFixtures.imageType(file) == UTType.jpeg.identifier
    }
    await checkAsync("Smaller: tiny image → \"already small\", nothing stays in the results folder") {
        let countBefore = (try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0
        let failure = await toolFailure(.makeSmaller, [tiny])
        let countAfter = (try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0
        return failure == .alreadySmall && countBefore == countAfter
    }

    // MARK: Convert

    if hasHEIC {
        await checkAsync("Convert: HEIC → JPG, type JPEG, orientation 1, upright") {
            let output = try await OneAnswerTools.run(.asJPEG, inputs: [heic])
            guard let file = output.files.first else { return false }
            let size = ToolFixtures.pixelSize(file)
            return ToolFixtures.imageType(file) == UTType.jpeg.identifier && size.orientation == 1
                && size.width == 1000 && size.height == 1600 && file.lastPathComponent == "IMG_0001.jpg"
        }
    } else {
        check("Convert: HEIC → JPG (no HEIC encoder here, skipped)") { true }
    }
    await checkAsync("Convert: JPEG with EXIF 6 → PNG, upright, orientation 1") {
        let output = try await OneAnswerTools.run(.asPNG, inputs: [sideways])
        guard let file = output.files.first else { return false }
        let size = ToolFixtures.pixelSize(file)
        return ToolFixtures.imageType(file) == UTType.png.identifier && size.width == 1000 && size.height == 1600 && size.orientation == 1
    }
    await checkAsync("Convert: two images as PDF → two searchable PDFs, PDF skipped") {
        let output = try await OneAnswerTools.run(.asPDF, inputs: [png, jpeg, letter])
        let names = output.files.map(\.lastPathComponent)
        return output.files.count == 2 && names == ["Mietvertrag.pdf", "Seite 2.pdf"]
            && output.files.allSatisfy { pdfText($0).contains("4711") }
            && output.skipped.map(\.name) == ["Brief.pdf"]
            && output.summary == L("%lld images as PDF", table: "Tools", 2)
    }

    // MARK: Speed (log only; CI is slower)

    // Only on request (PIPPA_PERF=1): on CI runners without a Neural Engine, text recognition of 30 pages takes very long.
    if ProcessInfo.processInfo.environment["PIPPA_PERF"] == "1" {
    await checkAsync("One PDF: 30 pages") {
        let started = Date()
        let log = ToolProgressLog()
        let output = try await OneAnswerTools.run(.makeOnePDF, inputs: Array(repeating: jpeg, count: 30)) { log.add($0) }
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "  30 pages: %.1f s (target ≤ 10 s on an M1)", seconds))
        guard let file = output.files.first else { return false }
        return PDFDocument(url: file)?.pageCount == 30 && log.all.count >= 30
    }
    }

    // MARK: Originals and cleanup

    check("Originals: bytes and fingerprint unchanged") {
        let after = inputs.map { ToolFixtures.identity($0) }
        return zip(before, after).allSatisfy { old, new in
            old.sha == new.sha && old.fingerprint != nil && old.fingerprint?.matches(new.fingerprint) == true
        }
    }
    check("Originals: no result in the originals' folder") {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let allowed = Set(inputs.map(\.lastPathComponent) + [heic.lastPathComponent])
        return !names.isEmpty && Set(names).isSubset(of: allowed)
    }
    check("Results folder: cleanup keeps what is still needed") {
        let kept = try ResultsFolder.fresh(), gone = try ResultsFolder.fresh()
        let keptFile = kept.appendingPathComponent("Scans.pdf")
        write("x", keptFile)
        write("y", gone.appendingPathComponent("Alt.pdf"))
        let removed = ResultsFolder.prune(keeping: [keptFile], maxAge: 60, now: Date().addingTimeInterval(3600))
        return removed >= 1 && fm.fileExists(atPath: keptFile.path) && !fm.fileExists(atPath: gone.path)
            && ResultsFolder.contains(keptFile) && !ResultsFolder.contains(results)
    }
}
