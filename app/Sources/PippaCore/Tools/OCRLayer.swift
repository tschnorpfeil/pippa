import CoreGraphics
import CoreText
import Foundation
import Vision

/// A recognized line; `box` normalized (0…1) with origin at bottom left, like Vision and PDF.
struct OCRLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

/// Invisible text layer over scanned pages so the PDF is searchable (Vision, offline).
enum OCRLayer {
    /// Vision cancellation can take time to unwind. Keep at most three outstanding optional requests, including
    /// those whose caller has already stopped waiting; subsequent conversions can still make their PDF.
    private static let slots = DispatchSemaphore(value: 3)

    static func recognize(_ image: CGImage, budget: FileTextBudget) throws -> [OCRLine] {
        try Task.checkCancellation()
        guard slots.wait(timeout: .now()) == .success else { budget.markSkipped(); return [] }
        let request = LayerRequest(image)
        // A request rejected before dispatch must also return its slot. The request owns release once it runs.
        defer { request.releaseIfNotStarted() }
        return try budget.run(cancel: { request.cancel() }, work: { request.run() }) ?? []
    }

    private final class LayerRequest: @unchecked Sendable {
        private let image: CGImage
        private let request: VNRecognizeTextRequest
        private let lock = NSLock()
        private var started = false
        private var released = false
        private var cancelled = false

        init(_ image: CGImage) {
            self.image = image
            request = DocumentOCR.classicRequest(level: DocumentOCR.layer == .fast ? .fast : .accurate)
        }

        func run() -> [OCRLine] {
            let allowed = lock.withLock { () -> Bool in
                guard !released, !cancelled else { return false }
                started = true
                return true
            }
            guard allowed else { releaseIfNotStarted(); return [] }
            defer { release() }
            return DocumentOCR.recognizeClassic(image, request: request).lines
        }

        func cancel() { lock.withLock { cancelled = true }; request.cancel() }
        func releaseIfNotStarted() {
            lock.withLock {
                if !started && !released { released = true; OCRLayer.slots.signal() }
            }
        }
        private func release() {
            lock.withLock {
                if !released { released = true; OCRLayer.slots.signal() }
            }
        }
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
