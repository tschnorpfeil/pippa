import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if canImport(Quartz)
import Quartz
#endif

/// "Make smaller": images to 2048 px (JPEG 0.7, PNG if transparent, without location data), PDFs with own Quartz filter
/// (150 dpi, JPEG 0.65), otherwise text-less pages re-rasterized. Not smaller -> `.alreadySmall`.
enum Shrink {
    static let tenMB: Int64 = 10 * 1024 * 1024

    /// At least 5 % smaller, otherwise a new file is not worth it.
    static func worthIt(_ size: Int64, than original: Int64) -> Bool {
        size > 0 && size * 20 <= original * 19
    }

    static func run(_ inputs: [URL], passwords: [URL: String],
                    progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> ToolOutput {
        try await ToolRun.eachFile(.makeSmaller, inputs: inputs, skipWhy: L("I can only make images and PDFs smaller.", table: "Tools"),
                                   progress: progress) { url, folder in
            if ToolFiles.kind(of: url) == .pdf { return try pdf(url, password: passwords[url], folder: folder) }
            return try image(url, folder: folder)
        }
    }

    // MARK: Images

    static func image(_ url: URL, folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ToolImages.thumbnail(source, maxPixel: 2048) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
        let props = ToolImages.properties(source)
        let alpha = (props[kCGImagePropertyHasAlpha as String] as? Bool) == true
        let type: UTType = alpha ? .png : .jpeg
        var out = ToolImages.cleaned(props, dropGPS: true)
        if !alpha { out[kCGImageDestinationLossyCompressionQuality as String] = 0.7 }
        let temp = ResultFile.temp(in: folder)
        try ToolImages.write(alpha ? image : ToolImages.opaque(image), type: type, properties: out, to: temp)
        guard worthIt(ToolFiles.size(temp), than: ToolFiles.size(url)) else {
            try? FileManager.default.removeItem(at: temp) // our own intermediate file
            throw ToolFailure.alreadySmall
        }
        let name = ResultNaming.name(for: .makeSmaller, inputs: [url], ext: ToolImages.ext(for: type))
        return try ResultFile.place(temp, as: name, in: folder)
    }

    // MARK: PDFs

    static func pdf(_ url: URL, password: String?, folder: URL) throws -> URL {
        let text = try ToolPDF.open(url, password: password)
        guard let doc = ToolPDF.openCG(url, password: password), doc.numberOfPages > 0 else {
            throw ToolFailure.unreadable(name: url.lastPathComponent)
        }
        let original = ToolFiles.size(url)
        var current: URL?

        let first = ResultFile.temp(in: folder)
        if try filtered(doc, to: first), ToolFiles.size(first) * 10 <= original * 9 {
            current = first
        } else {
            try? FileManager.default.removeItem(at: first) // our own intermediate file
        }
        if current == nil {
            let raster = ResultFile.temp(in: folder)
            if try rasterized(doc, text: text, dpi: 150, quality: 0.65, to: raster) { current = raster }
        }
        if let candidate = current, ToolFiles.size(candidate) > tenMB {
            let again = ResultFile.temp(in: folder)
            if try rasterized(doc, text: text, dpi: 100, quality: 0.5, to: again), ToolFiles.size(again) < ToolFiles.size(candidate) {
                try? FileManager.default.removeItem(at: candidate) // our own intermediate file
                current = again
            } else {
                try? FileManager.default.removeItem(at: again) // our own intermediate file
            }
        }
        guard let result = current, ToolFiles.size(result) > 0, worthIt(ToolFiles.size(result), than: original) else {
            if let current { try? FileManager.default.removeItem(at: current) } // our own intermediate file
            throw ToolFailure.alreadySmall
        }
        return try ResultFile.place(result, as: ResultNaming.name(for: .makeSmaller, inputs: [url], ext: "pdf"), in: folder)
    }

    /// Redrawn with an own Quartz filter (150 dpi, JPEG 0.65). Apple's "Reduce File Size" is too blurry.
    static func filtered(_ doc: CGPDFDocument, to url: URL) throws -> Bool {
        #if canImport(Quartz)
        guard let filterURL = try? writeFilter() else { return false }
        defer { try? FileManager.default.removeItem(at: filterURL) } // our own filter file in the temp folder
        let loaded: QuartzFilter? = QuartzFilter(url: filterURL)
        guard let filter = loaded, let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { return false }
        _ = filter.apply(to: ctx)
        for number in 1...doc.numberOfPages {
            try Task.checkCancellation()
            guard let page = doc.page(at: number) else { continue }
            let box = ToolPDF.pageBox(page)
            ctx.beginPDFPage(ToolPDF.pageInfo(box))
            ToolPDF.draw(page, in: ctx, box: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
        #else
        return false
        #endif
    }

    /// Filter plist: images to 150 dpi and JPEG 0.65.
    static func writeFilter() throws -> URL {
        let scale: [String: Any] = ["ImageResolution": 150, "ImageScaleFactor": 0.0]
        let imageSettings: [String: Any] = ["Compression Quality": 0.65, "ImageCompression": "ImageJPEGCompress", "ImageScaleSettings": scale]
        let colorSettings: [String: Any] = ["ImageSettings": imageSettings]
        let filterData: [String: Any] = ["ColorSettings": colorSettings]
        let domains: [String: Any] = ["Applications": true, "Printing": true]
        let plist: [String: Any] = ["FilterData": filterData, "Domains": domains, "FilterType": 1, "Name": "Pippa Smaller"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-\(UUID().uuidString).qfilter")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Fallback: pages without text redone as a JPEG image (with text layer), pages with text taken over unchanged.
    static func rasterized(_ doc: CGPDFDocument, text: PDFDocument, dpi: CGFloat, quality: Double, to url: URL) throws -> Bool {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { return false }
        for number in 1...doc.numberOfPages {
            try Task.checkCancellation()
            guard let page = doc.page(at: number) else { continue }
            let box = ToolPDF.pageBox(page)
            let words = text.page(at: number - 1)?.string ?? ""
            ctx.beginPDFPage(ToolPDF.pageInfo(box))
            if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let bitmap = render(page, box: box, dpi: dpi),
               let jpeg = ToolImages.jpegData(bitmap, quality: quality),
               let image = ToolImages.jpegImage(jpeg) {
                ctx.draw(image, in: box)
                OCRLayer.draw(OCRLayer.recognize(bitmap), in: box, context: ctx)
            } else {
                ToolPDF.draw(page, in: ctx, box: box)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }

    /// Page as an image at `dpi`, on white.
    static func render(_ page: CGPDFPage, box: CGRect, dpi: CGFloat) -> CGImage? {
        let scale = dpi / 72
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0, width < 10_000, height < 10_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: ToolImages.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ToolPDF.draw(page, in: ctx, box: box)
        return ctx.makeImage()
    }
}
