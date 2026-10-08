import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// Test files for the one-answer tools, generated in code (no binary files in the repo).
enum ToolFixtures {
    /// White image with large black text, one line per entry (easy for text recognition to read).
    static func textImage(_ lines: [String], width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let size = CGFloat(min(width, height)) / 10
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            ctx.textPosition = CGPoint(x: size * 0.6, y: CGFloat(height) - size * CGFloat(2 + 2 * index))
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    /// Random noise (barely compressible): makes large files.
    static func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state = seed | 1
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in 0..<words.count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[index] = state
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Writes an image; `orientation` sets the EXIF orientation (6 = display rotated by 90°). false if the format is unavailable.
    @discardableResult
    static func writeImage(_ image: CGImage?, type: UTType, to url: URL, orientation: Int? = nil, quality: Double = 0.9) -> Bool {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Can ImageIO write HEIC here?
    static var canWriteHEIC: Bool {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return types.contains("public.heic")
    }

    /// PDF made of noise images (Flate, large).
    static func noisePDF(pages: Int, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            if let image = noiseImage(width: 900, height: 1200, seed: UInt64(page + 7)) { ctx.draw(image, in: box) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Text PDF with user and owner password.
    static func lockedPDF(_ pages: [String], password: String, at url: URL) {
        let plain = url.deletingLastPathComponent().appendingPathComponent(".plain-\(UUID().uuidString).pdf")
        makePDF(pages, at: plain)
        defer { try? FileManager.default.removeItem(at: plain) } // our own temporary file
        guard let doc = PDFDocument(url: plain) else { return }
        _ = doc.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
    }

    /// Byte checksum and fingerprint, to verify "originals unchanged".
    static func identity(_ url: URL) -> (sha: String, fingerprint: FileFingerprint?) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (sha, FileFingerprint.of(url))
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int, orientation: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return (0, 0, 0) }
        let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        return (width, height, orientation)
    }

    static func imageType(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    static func size(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }
}

/// Progress reports of a run (from any thread).
final class ToolProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolProgress] = []
    func add(_ progress: ToolProgress) { lock.withLock { items.append(progress) } }
    var all: [ToolProgress] { lock.withLock { items } }
}
