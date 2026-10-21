import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit

/// Explicit, bounded choices for a local, ordered PDF. No prompt, shell or model participates.
public struct FilePreparationPlan: Codable, Sendable, Equatable {
    public enum Quality: String, CaseIterable, Codable, Sendable {
        case original, balanced, compact
    }
    public enum SizeGoal: Int64, CaseIterable, Codable, Sendable {
        case fiveMB = 5_000_000, tenMB = 10_000_000, twentyMB = 20_000_000
    }
    public var quality: Quality
    public var sizeGoal: SizeGoal?
    public init(quality: Quality = .original, sizeGoal: SizeGoal? = nil) {
        self.quality = quality; self.sizeGoal = sizeGoal
    }
}

/// Bytes, rather than names or timestamps alone, bind a preview to its input across a restart.
public struct FilePreparationSource: Codable, Sendable, Equatable {
    public let url: URL
    public let fingerprint: FileFingerprint
    public let sha256: String

    public static func capture(_ url: URL) throws -> Self {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let fingerprint = FileFingerprint.of(url), fingerprint.size <= 500_000_000 else {
            throw FilePreparationFailure.unsupported(url.lastPathComponent)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard fingerprint.matches(FileFingerprint.of(url)) else { throw FilePreparationFailure.changed(url.lastPathComponent) }
        return Self(url: url, fingerprint: fingerprint, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func validate() throws {
        guard fingerprint.matches(FileFingerprint.of(url)), try Self.capture(url).sha256 == sha256 else {
            throw FilePreparationFailure.changed(url.lastPathComponent)
        }
    }
}

public enum FilePreparationFailure: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String), changed(String), verification, tooManyPages
    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): L("I can’t prepare %@. Choose PDFs or single photos, up to 50 files and 500 MB each.", table: "FilePreparation", name)
        case .changed(let name): L("%@ changed since you chose it. Review the files again before continuing.", table: "FilePreparation", name)
        case .verification: L("I couldn’t verify every page. Your originals are unchanged; no result was accepted.", table: "FilePreparation")
        case .tooManyPages: L("Please split this into batches of up to 300 pages.", table: "FilePreparation")
        }
    }
}

public enum FilePreparation {
    /// Metadata only; opening and validating the files happens off the main actor after an explicit click.
    public static func accepts(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.count <= 50 && urls.allSatisfy {
            ["pdf", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains($0.pathExtension.lowercased())
        }
    }

    public static func run(sources: [FilePreparationSource], plan: FilePreparationPlan,
                           passwords: [URL: String] = [:],
                           progress: @escaping @Sendable (ToolProgress) -> Void = { _ in }) async throws -> ToolOutput {
        let urls = sources.map(\.url)
        guard accepts(urls) else { throw FilePreparationFailure.unsupported(urls.first?.lastPathComponent ?? "") }
        var expected: [PageProof] = []
        for source in sources {
            try source.validate()
            if source.url.pathExtension.lowercased() == "pdf" {
                let document = try ToolPDF.open(source.url, password: passwords[source.url])
                guard document.pageCount > 0 else { throw ToolFailure.unreadable(name: source.url.lastPathComponent) }
                guard expected.count + document.pageCount <= 300 else { throw FilePreparationFailure.tooManyPages }
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { throw FilePreparationFailure.verification }
                    expected.append(try proof(page))
                }
            } else {
                guard let image = CGImageSourceCreateWithURL(source.url as CFURL, nil), CGImageSourceGetCount(image) == 1,
                      let thumbnail = ToolImages.thumbnail(image, maxPixel: 2500) else {
                    throw ToolFailure.unreadable(name: source.url.lastPathComponent)
                }
                expected.append(try proof(thumbnail))
            }
        }
        guard expected.count <= 300 else { throw FilePreparationFailure.tooManyPages }
        var output = try await MakePDF.combine(urls, passwords: passwords, progress: progress)
        guard let file = output.files.first else { throw FilePreparationFailure.verification }
        do {
            guard output.skipped.isEmpty, output.consumedInputs == urls else { throw FilePreparationFailure.verification }
            try verify(file, expected: expected)
            if plan.quality != .original {
                let reduced = try Shrink.preparedPDF(file, quality: plan.quality, target: plan.sizeGoal?.rawValue)
                if reduced != file {
                    do {
                        try verify(reduced, expected: expected)
                        try FileManager.default.removeItem(at: file)
                        output.files = [reduced]
                        output.summary = reduced.lastPathComponent
                    } catch FilePreparationFailure.verification {
                        try? FileManager.default.removeItem(at: reduced)
                        let fallback = L("I kept the original PDF quality because the smaller version could not be verified.", table: "FilePreparation")
                        output.note = [output.note, fallback].compactMap { $0 }.joined(separator: " ")
                    }
                }
            }
            for source in sources { try source.validate() }
            try Task.checkCancellation()
            let size = ToolFiles.size(output.files[0])
            let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            var notes = [L("%lld pages · %@. Pages and order checked. Your originals are unchanged.", table: "FilePreparation", expected.count, shown)]
            if let target = plan.sizeGoal?.rawValue {
                let goal = ByteCountFormatter.string(fromByteCount: target, countStyle: .file)
                notes.append(size <= target
                    ? L("Within your %@ size limit.", table: "FilePreparation", goal)
                    : L("The %@ limit wasn’t reached at this quality. This is the verified result; try a smaller batch or a lower quality.", table: "FilePreparation", goal))
            }
            if let note = output.note { notes.append(note) }
            output.note = notes.joined(separator: " ")
            return output
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw error
        }
    }

    private struct PageProof {
        let ratio: CGFloat
        let pixels: [UInt8]
        let words: String
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A small rendered readback catches missing resources, rotations and changed page order as well as page loss.
    private static func proof(_ page: PDFPage) throws -> PageProof {
        guard let cg = page.pageRef else { throw FilePreparationFailure.verification }
        let box = ToolPDF.pageBox(cg)
        return PageProof(ratio: box.width / box.height, pixels: try pixels { ctx in
            ToolPDF.draw(cg, in: ctx, box: CGRect(x: 0, y: 0, width: 64, height: 64))
        }, words: normalized(page.string ?? ""))
    }

    private static func proof(_ image: CGImage) throws -> PageProof {
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        let width = ratio > 1 ? CGFloat(64) : 64 * ratio
        let height = ratio > 1 ? 64 / ratio : CGFloat(64)
        return PageProof(ratio: ratio, pixels: try pixels { ctx in
            ctx.draw(image, in: CGRect(x: (64 - width) / 2, y: (64 - height) / 2, width: width, height: height))
        }, words: "")
    }

    private static func pixels(_ draw: (CGContext) -> Void) throws -> [UInt8] {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw FilePreparationFailure.verification }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        draw(ctx)
        let samples = Array(UnsafeBufferPointer(start: data, count: 64 * 64))
        // PDFKit may change image interpolation when copying resources. Average neighboring samples so camera
        // grain does not look like a lost page; page geometry, text and visible low-frequency content remain checked.
        return (0..<samples.count).map { index in
            let x = index % 64, y = index / 64
            var sum = 0, count = 0
            for yy in max(0, y - 1)...min(63, y + 1) {
                for xx in max(0, x - 1)...min(63, x + 1) { sum += Int(samples[yy * 64 + xx]); count += 1 }
            }
            return UInt8(sum / count)
        }
    }

    private static func verify(_ url: URL, expected: [PageProof]) throws {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount == expected.count else {
            throw FilePreparationFailure.verification
        }
        for (index, before) in expected.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw FilePreparationFailure.verification }
            let after = try proof(page)
            let difference = zip(before.pixels, after.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            let contrast = before.pixels.reduce(0) { $0 + 255 - Int($1) }
            guard abs(before.ratio - after.ratio) < 0.02,
                  difference <= max(before.pixels.count * 2, contrast / 5),
                  before.words.isEmpty || before.words == after.words else {
                #if DEBUG
                if ProcessInfo.processInfo.environment["PIPPA_FILE_PREPARATION_CHECKS"] == "1" {
                    print("Readback page \(index): ratio \(before.ratio)/\(after.ratio), difference \(difference), contrast \(contrast), text counts \(before.words.count)/\(after.words.count)")
                }
                #endif
                throw FilePreparationFailure.verification
            }
        }
    }
}
