import CoreGraphics
import CoreText
import Foundation
import Vision

/// A recognized line; `box` normalized (0…1) with origin at bottom left, like Vision and PDF.
struct OCRLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

/// Result slot between the GCD block and the caller.
private final class OCRBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [OCRLine] = []
    func set(_ value: [OCRLine]) { lock.lock(); lines = value; lock.unlock() }
    func get() -> [OCRLine] { lock.lock(); defer { lock.unlock() }; return lines }
}

private struct ImageBox: @unchecked Sendable { let image: CGImage }

/// Invisible text layer over scanned pages so the PDF is searchable (Vision, offline).
enum OCRLayer {
    /// Text recognition on the page image (at most 2500 px). Errors simply yield no text layer.
    static func recognize(_ image: CGImage) -> [OCRLine] {
        // Vision blocks for a long time. Don't compute in the Swift concurrency pool (on Macs with few cores
        // three simultaneous pages blocked all pool threads), but on GCD, with an upper bound:
        // if a page takes too long, it simply gets no text layer.
        let box = OCRBox()
        let input = ImageBox(image: image)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(recognizeNow(input.image))
            done.signal()
        }
        guard done.wait(timeout: .now() + recognizeTimeout) == .success else { return [] }
        return box.get()
    }

    /// Seconds per page before Pippa continues without a text layer.
    static let recognizeTimeout: TimeInterval = 60

    /// Same recognizer as TextReader (`DocumentOCR`); `PIPPA_OCR_FAST=1` (CI runners without a Neural Engine) uses
    /// the fast classic request.
    private static func recognizeNow(_ image: CGImage) -> [OCRLine] {
        DocumentOCR.recognize(image, engine: DocumentOCR.layer).lines
    }

    /// Draws the lines invisibly over `page` (the same area the image fills).
    static func draw(_ lines: [OCRLine], in page: CGRect, context ctx: CGContext) {
        guard !lines.isEmpty else { return }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: page.minX + line.box.minX * page.width, y: page.minY + line.box.minY * page.height,
                             width: line.box.width * page.width, height: line.box.height * page.height)
            guard box.width > 1, box.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [fontKey: font])
            let ctLine = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            // Baseline slightly above the bottom of the box (descenders), width stretched to the box.
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
            ctx.scaleBy(x: box.width / width, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
