import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// An image page, ready to draw: JPEG data, page size in pt, recognized text.
struct PreparedPage: Sendable {
    var jpeg: Data
    var size: CGSize
    var lines: [OCRLine]
}

/// "Make one PDF": images and PDFs in the given order into one searchable PDF.
enum MakePDF {
    static let a4 = CGSize(width: 595, height: 842)
    static let maxPixel = 2500
    static let parallelPages = 3

    /// Image aspect ratio fitted into A4 (landscape if the image is wider than tall).
    static func pageSize(for pixels: CGSize) -> CGSize {
        let portrait = pixels.width <= pixels.height
        let frame = portrait ? a4 : CGSize(width: a4.height, height: a4.width)
        guard pixels.width > 0, pixels.height > 0 else { return frame }
        let scale = min(frame.width / pixels.width, frame.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }

    /// Image → JPEG page with text layer. nil if the image cannot be read.
    static func prepare(_ url: URL) throws -> PreparedPage? {
        try Task.checkCancellation()
        guard let thumb = ToolImages.thumbnail(url, maxPixel: maxPixel) else { return nil }
        let image = ToolImages.opaque(thumb)
        guard let jpeg = ToolImages.jpegData(image, quality: 0.75) else { return nil }
        try Task.checkCancellation()
        let lines = OCRLayer.recognize(image)
        try Task.checkCancellation()
        return PreparedPage(jpeg: jpeg, size: pageSize(for: CGSize(width: image.width, height: image.height)), lines: lines)
    }

    /// Prepare all images, at most three at a time; progress per finished page. Order is kept.
    static func prepareAll(_ urls: [URL], total: Int, progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> [PreparedPage?] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, PreparedPage?).self) { group in
            var results = [PreparedPage?](repeating: nil, count: urls.count)
            var next = 0
            while next < min(parallelPages, urls.count) {
                let index = next, url = urls[index]
                group.addTask {
                    let page = try MakePDF.prepare(url)
                    return (index, page)
                }
                next += 1
            }
            var done = 0
            while let finished = try await group.next() {
                results[finished.0] = finished.1
                done += 1
                progress(ToolProgress(done: done, total: total))
                if next < urls.count {
                    let index = next, url = urls[index]
                    group.addTask {
                        let page = try MakePDF.prepare(url)
                        return (index, page)
                    }
                    next += 1
                }
            }
            return results
        }
    }

    /// A page with its own media box: JPEG-backed image (stays DCT) and invisible text on top.
    static func draw(_ page: PreparedPage, in ctx: CGContext) {
        let box = CGRect(origin: .zero, size: page.size)
        ctx.beginPDFPage(ToolPDF.pageInfo(box))
        if let image = ToolImages.jpegImage(page.jpeg) { ctx.draw(image, in: box) }
        OCRLayer.draw(page.lines, in: box, context: ctx)
        ctx.endPDFPage()
    }

    /// Writes image pages as a PDF to `url`.
    static func write(_ pages: [PreparedPage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in pages { draw(page, in: ctx) }
        ctx.closePDF()
    }

    /// One image → one PDF (for "As PDF").
    static func single(_ url: URL, folder: URL) async throws -> URL {
        guard let page = try prepare(url) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
        let temp = ResultFile.temp(in: folder)
        do {
            try write([page], to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp) // own temporary file
            throw error
        }
        return try ResultFile.place(temp, as: ResultNaming.name(for: .asPDF, inputs: [url]), in: folder)
    }

    /// Everything in tray order into one PDF. Anything else stays behind with a reason; nothing usable → `.nothingUsable`.
    static func combine(_ inputs: [URL], passwords: [URL: String],
                        progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> ToolOutput {
        let notUsable = L("I can only turn images and PDFs into a PDF.", table: "Tools")
        var skipped: [FileReason] = []
        var usable: [(url: URL, kind: ToolInputKind)] = []
        for url in inputs {
            let kind = ToolFiles.kind(of: url)
            if kind == .other { skipped.append(FileReason(name: url.lastPathComponent, why: notUsable)) } else { usable.append((url, kind)) }
        }
        guard !usable.isEmpty else { throw ToolFailure.nothingUsable(skipped: skipped) }

        // Open PDFs first: a password is asked before work piles up. The source documents live until writing.
        var documents: [URL: PDFDocument] = [:]
        for entry in usable where entry.kind == .pdf && documents[entry.url] == nil {
            do {
                documents[entry.url] = try ToolPDF.open(entry.url, password: passwords[entry.url])
            } catch ToolFailure.unreadable(let name) {
                skipped.append(FileReason(name: name, why: ToolText.unreadableWhy))
            }
        }
        let images = usable.filter { $0.kind == .image }.map { $0.url }
        let pdfPages = usable.reduce(0) { sum, entry in sum + (documents[entry.url]?.pageCount ?? 0) }
        let total = images.count + pdfPages

        let folder = try ResultsFolder.fresh()
        do {
            try ToolFiles.checkSpace(for: usable.map { $0.url }, in: folder)
            progress(ToolProgress(done: 0, total: total))
            let prepared = try await prepareAll(images, total: total, progress: progress)
            try Task.checkCancellation()
            for (index, url) in images.enumerated() where prepared[index] == nil {
                skipped.append(FileReason(name: url.lastPathComponent, why: ToolText.unreadableWhy))
            }
            let pages = prepared.compactMap { $0 }
            var used: [URL] = []
            let temp = ResultFile.temp(in: folder)

            if documents.isEmpty {
                // Only images: directly into a PDF context, without the PDFKit detour.
                guard !pages.isEmpty else { throw failure(for: usable.map { $0.url }, skipped: skipped) }
                try write(pages, to: temp)
                used = zip(images, prepared).compactMap { $0.1 == nil ? nil : $0.0 }
            } else {
                // Mixed: image pages into an intermediate PDF, then insert everything in order as copies (never the original page).
                var imageDocument: PDFDocument?
                let imageTemp = ResultFile.temp(in: folder)
                defer { try? FileManager.default.removeItem(at: imageTemp) } // own temporary file
                if !pages.isEmpty {
                    try write(pages, to: imageTemp)
                    imageDocument = PDFDocument(url: imageTemp)
                }
                let out = PDFDocument()
                var imageIndex = 0, imagePage = 0, done = images.count
                for entry in usable {
                    try Task.checkCancellation()
                    if entry.kind == .image {
                        let ready = prepared[imageIndex] != nil
                        imageIndex += 1
                        guard ready, let page = imageDocument?.page(at: imagePage), let copy = page.copy() as? PDFPage else { continue }
                        imagePage += 1
                        out.insert(copy, at: out.pageCount)
                        used.append(entry.url)
                    } else if let doc = documents[entry.url] {
                        var any = false
                        for i in 0..<doc.pageCount {
                            try Task.checkCancellation()
                            guard let page = doc.page(at: i), let copy = page.copy() as? PDFPage else { continue }
                            out.insert(copy, at: out.pageCount)
                            any = true
                            done += 1
                            progress(ToolProgress(done: done, total: total))
                        }
                        if any { used.append(entry.url) }
                    }
                }
                guard out.pageCount > 0 else { throw failure(for: usable.map { $0.url }, skipped: skipped) }
                guard out.write(to: temp) else { throw CocoaError(.fileWriteUnknown) }
            }
            try Task.checkCancellation()
            let file = try ResultFile.place(temp, as: ResultNaming.name(for: .makeOnePDF, inputs: used), in: folder)
            return ToolOutput(files: [file], consumedInputs: used, skipped: skipped, summary: file.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: folder) // only Pippa's own, fresh result folder
            throw error
        }
    }

    private static func failure(for usable: [URL], skipped: [FileReason]) -> ToolFailure {
        if usable.count == 1 { return .unreadable(name: usable[0].lastPathComponent) }
        return .nothingUsable(skipped: skipped)
    }
}
