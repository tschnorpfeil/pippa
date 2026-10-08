import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Read text of a document, page by page (index 0 = page 1).
public struct DocumentText: Sendable {
    public enum Problem: String, Sendable { case none, noText, protected, unsupported, cloudOnly
        /// File cannot be opened (damaged). Unlike `noText`: there was nothing to read there, here something went wrong.
        case damaged
        /// Real read error: the answer might hinge on this file. Images without text, empty PDFs and foreign types don't count.
        public var isReadFailure: Bool { self == .protected || self == .cloudOnly || self == .damaged }
    }
    public var url: URL
    public var pages: [String]
    public var isPaged: Bool              // PDF: page references make sense
    public var usedOCR: Bool
    public var attachments: [String] = [] // .eml
    public var headers: [String: String] = [:]
    public var problem: Problem = .none
    public var isTruncated: Bool = false
    /// Pages in the whole file (PDF), even when fewer were read; `nil` for unpaged formats.
    public var pageCount: Int?

    public var fullText: String { pages.joined(separator: "\n\n") }
    public var hasText: Bool { pages.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 15 } }

    /// Text shortened to about 1,500 tokens, with page markers for PDFs.
    public func capped(maxChars: Int = 6000) -> String {
        var out = ""
        for (i, page) in pages.enumerated() {
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let chunk = isPaged ? "[S. \(i + 1)]\n\(trimmed)\n" : trimmed + "\n"
            if out.count + chunk.count > maxChars {
                out += String(chunk.prefix(max(0, maxChars - out.count)))
                break
            }
            out += chunk
        }
        return out
    }
}

public extension DocumentText {
    /// For checks and tools: provide read text directly.
    init(url: URL, pages: [String], isPaged: Bool, usedOCR: Bool, headers: [String: String]) {
        self.init(url: url, pages: pages, isPaged: isPaged, usedOCR: usedOCR, attachments: [], headers: headers, problem: .none)
    }
}

/// Reads text from PDF (PDFKit, Vision for scans), images (Vision), Office/RTF (NSAttributedString), text, HTML and .eml.
public enum TextReader {
    public struct Options: Sendable {
        public var maxPages: Int
        public var ocr: Bool
        /// Called right before text recognition starts on a page (`page` counts from 1, `pages` = pages to read).
        public var onRecognize: (@Sendable (_ page: Int, _ pages: Int) -> Void)?
        public init(maxPages: Int = 50, ocr: Bool = true) { self.maxPages = maxPages; self.ocr = ocr }
        public static let quick = Options(maxPages: 1, ocr: false)
    }

    public static func read(_ url: URL, options: Options = Options()) -> DocumentText {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let ext = url.pathExtension.lowercased()
        if FileFacts.isCloudPlaceholder(url) {
            return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .cloudOnly)
        }
        if type.conforms(to: .pdf) { return readPDF(url, options: options) }
        if type.conforms(to: .image) {
            guard options.ocr else { return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .noText) }
            guard let image = loadCGImage(url) else { return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .damaged) }
            let key = DocumentOCR.contentKey(url)
            let text = DocumentOCR.recognize(contentKey: key, page: 0) { options.onRecognize?(1, 1); return image }?.text ?? ""
            return DocumentText(url: url, pages: [text], isPaged: false, usedOCR: true, problem: text.isEmpty ? .noText : .none)
        }
        if ext == "eml" { return readMail(url) }
        if type.conforms(to: .html) {
            let raw = readPlain(url) ?? ""
            return DocumentText(url: url, pages: [stripHTML(raw)], isPaged: false, usedOCR: false)
        }
        if ["docx", "doc", "rtf", "rtfd", "odt", "wordml"].contains(ext) || type.conforms(to: .rtf) {
            var docType: NSAttributedString.DocumentType?
            switch ext {
            case "docx": docType = .officeOpenXML
            case "doc": docType = .docFormat
            case "odt": docType = .openDocument
            case "rtf": docType = .rtf
            case "rtfd": docType = .rtfd
            default: docType = nil
            }
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let docType { opts[.documentType] = docType }
            let text = (try? NSAttributedString(url: url, options: opts, documentAttributes: nil))?.string ?? ""
            return DocumentText(url: url, pages: [text], isPaged: false, usedOCR: false, problem: text.isEmpty ? .noText : .none)
        }
        if ext == "xlsx" {
            // Excel: values and formulas per cell, so Pi can check formulas (not just the results).
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let sheet = XLSXReader.read(data) else {
                return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .damaged)
            }
            var result = DocumentText(url: url, pages: [sheet.text], isPaged: false, usedOCR: false, problem: sheet.text.isEmpty ? .noText : .none)
            result.isTruncated = sheet.truncated
            return result
        }
        if type.conforms(to: .text) || ["md", "csv", "txt", "log", "json", "xml"].contains(ext) {
            let text = readPlain(url) ?? ""
            var result = DocumentText(url: url, pages: [String(text.prefix(200_000))], isPaged: false, usedOCR: false, problem: text.isEmpty ? .noText : .none)
            result.isTruncated = text.count > 200_000
            return result
        }
        return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .unsupported)
    }

    static func readPDF(_ url: URL, options: Options) -> DocumentText {
        guard let doc = PDFDocument(url: url) else {
            return DocumentText(url: url, pages: [], isPaged: true, usedOCR: false, problem: .damaged)
        }
        if doc.isLocked || doc.isEncrypted && !doc.unlock(withPassword: "") {
            return DocumentText(url: url, pages: [], isPaged: true, usedOCR: false, problem: .protected)
        }
        var pages: [String] = []
        let reading = min(doc.pageCount, options.maxPages)
        var scanned: [Int] = []
        for i in 0..<reading {
            guard let page = doc.page(at: i) else { pages.append(""); continue }
            let text = orderedText(page) ?? page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 15, options.ocr { scanned.append(i) }
            pages.append(text)
        }
        let usedOCR = !scanned.isEmpty
        if usedOCR {
            for (i, text) in recognizePages(url, doc: doc, indices: scanned, reading: reading, onRecognize: options.onRecognize) {
                pages[i] = text
            }
        }
        var result = DocumentText(url: url, pages: pages, isPaged: true, usedOCR: usedOCR)
        result.pageCount = doc.pageCount
        result.isTruncated = doc.pageCount > pages.count
        if !result.hasText { result.problem = .noText }
        return result
    }

    /// Page text in reading order: lines by their position on the page (top to bottom, left to right).
    /// `page.string` sometimes swaps lines (e.g. the last line of a paragraph before the second-to-last), then
    /// verbatim quotes are no longer in the read text. Used only if the same characters come out.
    static func orderedText(_ page: PDFPage) -> String? {
        guard let raw = page.string, !raw.isEmpty,
              let all = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }
        var lines: [(rect: CGRect, text: String)] = []
        for sel in all.selectionsByLine() {
            guard let t = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
            lines.append((sel.bounds(for: page), t))
        }
        guard !lines.isEmpty else { return nil }
        let rows = lineRows(lines)
        let text = rows.joined(separator: "\n")
        // Safety net: same characters as PDFKit (without whitespace), otherwise prefer PDFKit's order.
        func letters(_ s: String) -> [Character] { s.filter { !$0.isWhitespace }.sorted() }
        return letters(text) == letters(raw) ? text : nil
    }

    /// Merges line pieces into lines (same height on the page) and sorts them top → bottom, left → right.
    /// Coordinates as in PDF and Vision: origin bottom left.
    public static func lineRows(_ pieces: [(rect: CGRect, text: String)]) -> [String] {
        positionedRows(pieces).map(\.text)
    }

    /// Like `lineRows`, with the top edge of each row (for placing tables between rows).
    static func positionedRows(_ pieces: [(rect: CGRect, text: String)]) -> [(top: CGFloat, text: String)] {
        let sorted = pieces.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) / 2 ? a.rect.midY > b.rect.midY : a.rect.minX < b.rect.minX
        }
        var rows: [[(rect: CGRect, text: String)]] = []
        for p in sorted {
            if let last = rows.last?.last, abs(last.rect.midY - p.rect.midY) <= min(last.rect.height, p.rect.height) / 2 {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { row in
            (row.map(\.rect.maxY).max() ?? 0, row.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " "))
        }
    }

    /// Page as image (about 200 dpi) for text recognition.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200.0 / 72.0
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, width < 10_000, height < 10_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 3000,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// A tiny text recognition with the same settings as `recognize`, so Vision loads its models.
    public static func warmUp() {
        let w = 360, h = 72
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attr = NSAttributedString(string: "Summe 23,45 €", attributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 12, y: 20)
        CTLineDraw(line, ctx)
        if let image = ctx.makeImage() { _ = recognize(image) }
    }

    /// Text recognition (German, English): document recognition from macOS 26 (tables as Markdown), otherwise the classic one.
    public static func recognize(_ image: CGImage) -> String {
        DocumentOCR.recognize(image).text
    }

    /// Pages recognized at once. Measured: two in parallel use the Neural Engine and CPU
    /// better than one; more only add memory (one 200-dpi A4 page is about 15 MB).
    static let parallelPages = 2

    /// Scanned pages of a PDF, at most `parallelPages` at a time, started in page order (Thought Line shows
    /// "page 1 of 2", then "page 2 of 2"). Pages already recognized in this session come from the cache.
    static func recognizePages(_ url: URL, doc: PDFDocument, indices: [Int], reading: Int,
                               onRecognize: (@Sendable (_ page: Int, _ pages: Int) -> Void)?) -> [(Int, String)] {
        let key = DocumentOCR.contentKey(url)
        let results = PageResults()
        let slots = DispatchSemaphore(value: parallelPages)
        let group = DispatchGroup()
        let pdf = UncheckedPDF(doc: doc)
        for i in indices {
            slots.wait()
            group.enter()
            // PDFKit is not thread-safe: render here, in order; only recognition runs in parallel.
            var image: CGImage?
            let cached = DocumentOCR.cached(contentKey: key, page: i)
            if cached == nil {
                image = pdf.doc.page(at: i).flatMap(render)
                onRecognize?(i + 1, reading)
            }
            let input = UncheckedImageRef(image: image)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { slots.signal(); group.leave() }
                if let cached { results.set(i, cached.text); return }
                // A page that cannot be rendered keeps whatever PDFKit found.
                if let page = DocumentOCR.recognize(contentKey: key, page: i, image: { input.image }) { results.set(i, page.text) }
            }
        }
        group.wait()
        return results.all()
    }

    static func readPlain(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let slice = data.prefix(2_000_000)
        if let s = String(data: slice, encoding: .utf8) { return s }
        return String(data: slice, encoding: .windowsCP1252) ?? String(data: slice, encoding: .isoLatin1)
    }

    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</tr>|</h\d>|</li>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&euro;": "€",
                        "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mail (.eml)

    static func readMail(_ url: URL) -> DocumentText {
        guard let data = try? Data(contentsOf: url) else {
            return DocumentText(url: url, pages: [], isPaged: false, usedOCR: false, problem: .noText)
        }
        let mail = MailParser.parse(data)
        var head: [String] = []
        for key in ["From", "To", "Date", "Subject"] {
            if let v = mail.headers[key.lowercased()] {
                let label = ["From": "Von", "To": "An", "Date": "Datum", "Subject": "Betreff"][key]!
                head.append("\(label): \(v)")
            }
        }
        if !mail.attachments.isEmpty { head.append("Anhänge: " + mail.attachments.joined(separator: ", ")) }
        let text = head.joined(separator: "\n") + "\n\n" + mail.body
        var result = DocumentText(url: url, pages: [text], isPaged: false, usedOCR: false, attachments: mail.attachments,
                                  headers: mail.headers)
        if mail.body.isEmpty && mail.headers.isEmpty { result.problem = .noText }
        return result
    }
}

private final class PageResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, String)] = []
    func set(_ i: Int, _ text: String) { lock.lock(); values.append((i, text)); lock.unlock() }
    func all() -> [(Int, String)] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.0 < $1.0 } }
}

private struct UncheckedPDF: @unchecked Sendable { let doc: PDFDocument }
private struct UncheckedImageRef: @unchecked Sendable { let image: CGImage? }

/// Minimal MIME reader: header lines, first text/plain part (otherwise text/html), attachment names.
public enum MailParser {
    public struct Mail: Sendable {
        public var headers: [String: String]; public var body: String; public var attachments: [String]
        /// The message has an HTML part but no text/plain alternative: typical for designed bulk mail, rare for letters.
        public var htmlOnly = false
    }

    public static func parse(_ data: Data) -> Mail {
        // Lossless: every byte becomes exactly one character (Latin-1). Only per MIME part is it
        // decoded by its charset (`bytes(_:)` gets the bytes back). So "Kündigung" in Latin-1 never becomes "KÃ¼ndigung".
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var plain: String?
        var html: String?
        var attachments: [String] = []
        let (headers, body) = splitPart(text)
        walk(headers: headers, body: body, plain: &plain, html: &html, attachments: &attachments, depth: 0)
        var decoded: [String: String] = [:]
        for (k, v) in headers { decoded[k] = decodeWords(decode(bytes(v), charset: "utf-8")) }
        let bodyText = plain ?? html.map(TextReader.stripHTML) ?? ""
        return Mail(headers: decoded, body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments,
                    htmlOnly: plain == nil && html != nil)
    }

    static func splitPart(_ text: String) -> ([String: String], String) {
        let parts = text.components(separatedBy: "\n\n")
        let headerBlock = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [String: String] = [:]
        var lastKey: String?
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let key = lastKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                if headers[key] == nil { headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                lastKey = key
            }
        }
        return (headers, body)
    }

    static func param(_ name: String, in header: String) -> String? {
        let pattern = "(?i)\(name)\\*?=\\s*(\"([^\"]*)\"|([^;\\s]+))"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for g in [2, 3] { if let r = Range(m.range(at: g), in: header) { return String(header[r]) } }
        return nil
    }

    static func walk(headers: [String: String], body: String, plain: inout String?, html: inout String?, attachments: inout [String], depth: Int) {
        guard depth < 8 else { return }
        let contentType = headers["content-type"] ?? "text/plain"
        let lowerType = contentType.lowercased()
        let disposition = headers["content-disposition"] ?? ""
        if lowerType.hasPrefix("multipart/"), let boundary = param("boundary", in: contentType) {
            let parts = body.components(separatedBy: "--" + boundary)
            for part in parts.dropFirst() {
                if part.hasPrefix("--") { break }
                let trimmed = part.hasPrefix("\n") ? String(part.dropFirst()) : part
                let (h, b) = splitPart(trimmed)
                walk(headers: h, body: b, plain: &plain, html: &html, attachments: &attachments, depth: depth + 1)
            }
            return
        }
        let filename = param("filename", in: disposition) ?? param("name", in: contentType)
        if disposition.lowercased().hasPrefix("attachment") || (filename != nil && !lowerType.hasPrefix("text/")) {
            attachments.append(filename.map { decodeWords(decode(Self.bytes($0), charset: "utf-8")) } ?? "Anhang")
            return
        }
        guard lowerType.hasPrefix("text/") else { return }
        let charset = param("charset", in: contentType)?.lowercased() ?? "utf-8"
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        var bytes: Data
        if encoding.contains("base64") {
            bytes = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        } else if encoding.contains("quoted-printable") {
            bytes = quotedPrintable(body)
        } else {
            bytes = Self.bytes(body)            // 7bit, 8bit, binary: the original bytes
        }
        let text = decode(bytes, charset: charset)
        if lowerType.hasPrefix("text/plain") { if plain == nil { plain = text } } else if lowerType.hasPrefix("text/html") { if html == nil { html = text } }
    }

    /// Original bytes of a piece from `parse` (there every byte is exactly one Latin-1 character).
    static func bytes(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }

    /// Bytes by the given charset (IANA name). "iso-8859-1" as Windows-1252 like mail programs do (€, „“),
    /// with invalid UTF-8 also Windows-1252, finally Latin-1: never lose text.
    static func decode(_ data: Data, charset: String) -> String {
        var enc = String.Encoding.utf8
        let cf = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
        if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        if enc == .isoLatin1 { enc = .windowsCP1252 }
        return String(data: data, encoding: enc) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func quotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(Self.bytes(s.replacingOccurrences(of: "=\n", with: "")))
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "="), i + 2 < bytes.count,
               let v = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                out.append(v); i += 3
            } else { out.append(bytes[i]); i += 1 }
        }
        return out
    }

    /// RFC 2047: =?utf-8?Q?...?= and =?utf-8?B?...?=
    static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let s = input.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#) else { return input }
        var result = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let cs = Range(m.range(at: 1), in: s),
                  let mode = Range(m.range(at: 2), in: s), let payload = Range(m.range(at: 3), in: s) else { continue }
            let data: Data
            if s[mode].uppercased() == "B" { data = Data(base64Encoded: String(s[payload])) ?? Data() }
            else { data = quotedPrintable(s[payload].replacingOccurrences(of: "_", with: " ")) }
            result.replaceSubrange(whole, with: decode(data, charset: String(s[cs])))
        }
        return result
    }
}
