import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Single-answer tools: one click, one new file in Caches/Pippa/Results/<uuid>/.
// The originals are never touched, only read. No model, no network.

/// Which tool. The raw value is the identifier in the job log.
public enum ToolID: String, Sendable, Codable, CaseIterable {
    case makeOnePDF = "make-one-pdf", makeSmaller = "make-smaller", asPDF = "as-pdf"
    case asJPEG = "as-jpg", asPNG = "as-png"

    /// Plain verb for the button.
    public var title: String {
        switch self {
        case .makeOnePDF: L("Make one PDF", table: "Tools")
        case .makeSmaller: L("Make smaller", table: "Tools")
        case .asPDF: L("As PDF", table: "Tools")
        case .asJPEG: L("As JPG", table: "Tools")
        case .asPNG: L("As PNG", table: "Tools")
        }
    }

    /// For the progress line ("Making one PDF · 2 of 3 pages").
    public var workingTitle: String {
        switch self {
        case .makeOnePDF: L("Making one PDF", table: "Tools")
        case .makeSmaller: L("Making it smaller", table: "Tools")
        case .asPDF: L("Making a PDF", table: "Tools")
        case .asJPEG: L("Making a JPG", table: "Tools")
        case .asPNG: L("Making a PNG", table: "Tools")
        }
    }
}

/// Progress in pages (One PDF) or files (all other tools).
public struct ToolProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// What a tool leaves behind.
public struct ToolOutput: Sendable {
    /// All in `ResultsFolder.directory`.
    public var files: [URL]
    /// Exact source URLs successfully used; names alone are not unique.
    public var consumedInputs: [URL]
    /// What stayed in place, one plain sentence per name.
    public var skipped: [FileReason]
    /// e.g. "Scans 06.10.2026.pdf" or "2 images as JPG".
    public var summary: String

    public init(files: [URL], consumedInputs: [URL], skipped: [FileReason], summary: String) {
        self.files = files; self.consumedInputs = consumedInputs; self.skipped = skipped; self.summary = summary
    }

    /// A sentence under the result when something stayed in place ("I skipped video.mov. I can only turn …"); otherwise nil.
    public var skippedSentence: String? { ToolText.skipped(skipped) }
}

/// Errors the row answers with one sentence (and for passwords with a field).
public enum ToolFailure: Error, Sendable, Equatable, LocalizedError {
    case locked(URL)
    case wrongPassword(URL)
    case nothingUsable(skipped: [FileReason])
    case alreadySmall
    case notEnoughSpace
    case unreadable(name: String)

    public var errorDescription: String? {
        switch self {
        case .locked: L("This PDF is locked. Type the password and I’ll continue.", table: "Tools")
        case .wrongPassword: L("That password didn’t open it. Please try again.", table: "Tools")
        case .nothingUsable(let skipped): ToolText.skipped(skipped) ?? L("There’s nothing here I can use for this.", table: "Tools")
        case .alreadySmall: L("This is already as small as I can make it.", table: "Tools")
        case .notEnoughSpace: L("Not enough space to write this.", table: "Tools")
        case .unreadable(let name): L("I couldn’t open %@.", table: "Tools", name)
        }
    }
}

/// Pippa's own location for results: ~/Library/Caches/Pippa/Results/<uuid>/<name>.
public enum ResultsFolder {
    public static var directory: URL {
        // Checks redirect it (like PIPPA_LOG_DIR) so nothing lands in the real cache.
        if let raw = getenv("PIPPA_RESULTS_DIR") {
            let custom = String(cString: raw)
            if !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        }
        #if DEBUG
        if let snapshot = ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT"], !snapshot.isEmpty {
            return URL(fileURLWithPath: snapshot, isDirectory: true).appendingPathComponent("results", isDirectory: true)
        }
        #endif
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Pippa/Results", isDirectory: true)
    }

    /// A fresh, created subfolder per run.
    public static func fresh() throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Is `url` in Pippa's results folder (then Undo may delete the file instead of moving it to the Trash)?
    public static func contains(_ url: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") && path.count > base.count + 1
    }

    /// Deletes Results/<uuid> folders older than `maxAge` that contain no file from `keeping`.
    @discardableResult
    public static func prune(keeping: [URL], maxAge: TimeInterval = 86_400, now: Date = Date()) -> Int {
        InboxCleanup.prune(directory, keeping: keeping, maxAge: maxAge, now: now)
    }
}

/// Names of the results. Always via `Naming.sanitize`, extension separate, so shortening never cuts it off.
public enum ResultNaming {
    /// German locale: "Scans 06.10.2026.pdf", otherwise "Scans 2026-10-06.pdf"; PDFs only merged: "Combined …".
    /// A single input: "<Name> (smaller).pdf", "<Name>.jpg".
    public static func name(for tool: ToolID, inputs: [URL], date: Date = Date(), locale: Locale = .current) -> String {
        name(for: tool, inputs: inputs, ext: nil, date: date, locale: locale)
    }

    /// As above, with the extension the tool actually writes (nil = guessed from the input).
    static func name(for tool: ToolID, inputs: [URL], ext: String?, date: Date = Date(), locale: Locale = .current) -> String {
        let german = locale.language.languageCode?.identifier == "de"
        switch tool {
        case .makeOnePDF:
            let allPDF = !inputs.isEmpty && inputs.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
            let word = allPDF ? (german ? "Zusammengefügt" : "Combined") : "Scans"
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = german ? "dd.MM.yyyy" : "yyyy-MM-dd"
            return compose(word + " " + formatter.string(from: date), ext: "pdf")
        case .makeSmaller:
            return compose(base(inputs) + (german ? " (kleiner)" : " (smaller)"), ext: ext ?? guessedExt(tool, inputs.first))
        case .asPDF:
            return compose(base(inputs), ext: "pdf")
        case .asJPEG:
            return compose(base(inputs), ext: "jpg")
        case .asPNG:
            return compose(base(inputs), ext: "png")
        }
    }

    private static func base(_ inputs: [URL]) -> String {
        inputs.first?.deletingPathExtension().lastPathComponent ?? ""
    }

    private static func compose(_ base: String, ext: String) -> String {
        var clean = Naming.sanitize(base, maxLength: 90)
        if clean.isEmpty { clean = "Pippa" }
        return clean + "." + ext.lowercased()
    }

    /// Extension that shrinking writes for this input (HEIC and unknown become JPG).
    static func guessedExt(_ tool: ToolID, _ input: URL?) -> String {
        let ext = input?.pathExtension.lowercased() ?? ""
        switch ext {
        case "pdf", "png": return ext
        case "tif", "tiff": return "jpg"
        default: return "jpg"
        }
    }
}

/// Entry point for the row and checks.
public enum OneAnswerTools {
    /// Can `tool` do anything with this file?
    public static func accepts(_ tool: ToolID, _ url: URL) -> Bool {
        let kind = ToolFiles.kind(of: url)
        switch tool {
        case .makeOnePDF, .makeSmaller: return kind != .other
        case .asPDF, .asJPEG, .asPNG: return kind == .image
        }
    }

    /// Never touches the inputs; writes only into a fresh subfolder of `ResultsFolder`. Cancellable per page.
    public static func run(_ tool: ToolID, inputs: [URL], passwords: [URL: String] = [:],
                           progress: @escaping @Sendable (ToolProgress) -> Void = { _ in }) async throws -> ToolOutput {
        try Task.checkCancellation()
        switch tool {
        case .makeOnePDF: return try await MakePDF.combine(inputs, passwords: passwords, progress: progress)
        case .makeSmaller: return try await Shrink.run(inputs, passwords: passwords, progress: progress)
        case .asPDF, .asJPEG, .asPNG: return try await Convert.run(tool, inputs: inputs, progress: progress)
        }
    }
}

// MARK: - Shared (internal)

enum ToolInputKind: Sendable, Equatable { case image, pdf, other }

enum ToolText {
    /// "I skipped video.mov. I can only turn images and PDFs into a PDF." – one sentence, names without path.
    static func skipped(_ reasons: [FileReason]) -> String? {
        guard let first = reasons.first else { return nil }
        let names = ListFormatter.localizedString(byJoining: reasons.map(\.name))
        if reasons.allSatisfy({ $0.why == first.why }) {
            return L("I skipped %@. %@", table: "Tools", names, first.why)
        }
        return L("I skipped %@.", table: "Tools", names)
    }

    static var unreadableWhy: String { L("I couldn’t open this file.", table: "Tools") }

    /// Summary for several results; for one it is its name.
    static func summary(_ tool: ToolID, files: [URL]) -> String {
        if files.count == 1 { return files[0].lastPathComponent }
        let n = files.count
        switch tool {
        case .makeOnePDF, .asPDF: return L("%lld images as PDF", table: "Tools", n)
        case .asJPEG: return L("%lld images as JPG", table: "Tools", n)
        case .asPNG: return L("%lld images as PNG", table: "Tools", n)
        case .makeSmaller: return L("%lld files made smaller", table: "Tools", n)
        }
    }
}

enum ToolFiles {
    static func kind(of url: URL) -> ToolInputKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return .other }
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .other
    }

    static func size(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    /// Throws `.notEnoughSpace` if the volume of `folder` has less than twice the estimate free.
    static func checkSpace(for inputs: [URL], in folder: URL) throws {
        let estimate = inputs.reduce(Int64(0)) { $0 + size($1) }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < estimate * 2 {
            throw ToolFailure.notEnoughSpace
        }
    }
}

enum ResultFile {
    /// Invisible temp file in the results folder; only `place` gives it its name.
    static func temp(in folder: URL) -> URL {
        folder.appendingPathComponent(".\(UUID().uuidString).tmp")
    }

    /// Rename to a free name in the same folder (atomic on the same volume).
    static func place(_ temp: URL, as name: String, in folder: URL) throws -> URL {
        var taken = Set<String>()
        let target = Naming.unique(name, in: folder, taken: &taken)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}

enum ToolRun {
    /// One result per input (shrink, convert, rotate). Unsuitable and unreadable inputs stay with a reason;
    /// password prompts and cancellation pass through. On an error no half-finished results folder remains.
    static func eachFile(_ tool: ToolID, inputs: [URL], skipWhy: String,
                         progress: @escaping @Sendable (ToolProgress) -> Void,
                         make: (URL, URL) async throws -> URL) async throws -> ToolOutput {
        let usable = inputs.filter { OneAnswerTools.accepts(tool, $0) }
        var skipped = inputs.filter { !OneAnswerTools.accepts(tool, $0) }.map { FileReason(name: $0.lastPathComponent, why: skipWhy) }
        guard !usable.isEmpty else { throw ToolFailure.nothingUsable(skipped: skipped) }
        let folder = try ResultsFolder.fresh()
        do {
            try ToolFiles.checkSpace(for: usable, in: folder)
            var files: [URL] = []
            var consumedInputs: [URL] = []
            var small = 0
            progress(ToolProgress(done: 0, total: usable.count))
            for (index, url) in usable.enumerated() {
                try Task.checkCancellation()
                do {
                    files.append(try await make(url, folder))
                    consumedInputs.append(url)
                } catch let failure as ToolFailure {
                    switch failure {
                    case .alreadySmall:
                        small += 1
                        skipped.append(FileReason(name: url.lastPathComponent, why: L("This is already as small as I can make it.", table: "Tools")))
                    case .unreadable:
                        skipped.append(FileReason(name: url.lastPathComponent, why: ToolText.unreadableWhy))
                    default:
                        throw failure
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skipped.append(FileReason(name: url.lastPathComponent, why: ToolText.unreadableWhy))
                }
                progress(ToolProgress(done: index + 1, total: usable.count))
            }
            try Task.checkCancellation()
            guard !files.isEmpty else {
                if small == usable.count { throw ToolFailure.alreadySmall }
                if usable.count == 1 { throw ToolFailure.unreadable(name: usable[0].lastPathComponent) }
                throw ToolFailure.nothingUsable(skipped: skipped)
            }
            return ToolOutput(files: files, consumedInputs: consumedInputs, skipped: skipped, summary: ToolText.summary(tool, files: files))
        } catch {
            try? FileManager.default.removeItem(at: folder) // only Pippa's own, fresh results folder
            throw error
        }
    }
}

enum ToolImages {
    static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

    /// Shrunk image with orientation applied (EXIF, important for HEIC from iPhone). `maxPixel` nil = full size.
    static func thumbnail(_ source: CGImageSource, maxPixel: Int?) -> CGImage? {
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        if let maxPixel { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func thumbnail(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    /// Full size, rotated per EXIF, first image.
    static func fullImage(_ source: CGImageSource) -> CGImage? {
        let props = properties(source)
        let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let side = max(width, height)
        return thumbnail(source, maxPixel: side > 0 ? side : nil)
    }

    static func properties(_ source: CGImageSource) -> [String: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// On white, without alpha (JPEG would otherwise get black edges).
    static func opaque(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// JPEG-backed image: in a PDF context it stays DCT (a decoded image would become Flate and 5–10× larger).
    static func jpegImage(_ jpeg: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: jpeg as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Source metadata without size entries, orientation 1 (the pixels are already rotated), optionally without location.
    static func cleaned(_ props: [String: Any], dropGPS: Bool) -> [String: Any] {
        var out = props
        if dropGPS { out.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        out.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        out.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        out[kCGImagePropertyOrientation as String] = 1
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return out
    }

    static func write(_ image: CGImage, type: UTType, properties: [String: Any], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url) // own temp file
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Extension for written images ("jpg" instead of "jpeg").
    static func ext(for type: UTType) -> String {
        if type == .png { return "png" }
        if type == .tiff { return "tiff" }
        return "jpg"
    }

    /// Keep the format when rotating: PNG, JPEG, TIFF stay; HEIC and everything else becomes JPEG.
    static func keptType(_ source: CGImageSource) -> UTType {
        guard let raw = CGImageSourceGetType(source), let type = UTType(raw as String) else { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .tiff) { return .tiff }
        return .jpeg
    }
}

enum ToolPDF {
    /// PDFKit document, unlocked with `password`, otherwise `.locked` / `.wrongPassword`.
    static func open(_ url: URL, password: String?) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
        if doc.isLocked {
            guard let password else { throw ToolFailure.locked(url) }
            guard doc.unlock(withPassword: password) else { throw ToolFailure.wrongPassword(url) }
        }
        return doc
    }

    /// The same file as CGPDFDocument (for redrawing), unlocked.
    static func openCG(_ url: URL, password: String?) -> CGPDFDocument? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        if !doc.isUnlocked, let password { _ = doc.unlockWithPassword(password) }
        return doc.isUnlocked ? doc : nil
    }

    /// Page attributes for `beginPDFPage`: the media box as CFData with a CGRect.
    static func pageInfo(_ box: CGRect) -> CFDictionary {
        var rect = box
        let data = withUnsafeBytes(of: &rect) { Data($0) }
        let info: [CFString: Any] = [kCGPDFContextMediaBox: data as CFData]
        return info as CFDictionary
    }

    /// Visible page size after /Rotate.
    static func pageBox(_ page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        return CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width, height: turned ? crop.width : crop.height)
    }

    /// Draws the page upright in `box` (accounts for /Rotate).
    static func draw(_ page: CGPDFPage, in ctx: CGContext, box: CGRect) {
        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
