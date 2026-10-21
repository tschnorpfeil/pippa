import Foundation
import ImageIO
import PDFKit
import Vision

/// Complete per-page text exports. OCR is labelled separately from embedded PDF text; no model rewrites either.
enum ExtractText {
    static func run(_ inputs: [URL], passwords: [URL: String], progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> ToolOutput {
        var output = try await ToolRun.eachFile(.extractText, inputs: inputs,
            skipWhy: L("I can only extract text from PDFs and photos.", table: "Tools"), progress: progress) { url, folder in
            try NativeFileLimits.check(url)
            var sections = [L("Source: %@", table: "Tools", url.lastPathComponent)]
            var size = 0
            var hasText = false
            func append(_ text: String, page: Int, ocr: Bool) throws {
                size += text.utf8.count
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard size <= NativeFileLimits.textBytes else {
                    throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("The extracted text exceeds 2 MB. Nothing was exported; no text was cut off.", table: "Tools"))
                }
                let method = ocr ? L("Recognized from image (OCR; please check)", table: "Tools") : L("Embedded PDF text", table: "Tools")
                sections.append(L("Page %lld — %@", table: "Tools", page, method) + "\n" + (text.isEmpty ? L("No readable text was recognized on this page.", table: "Tools") : text))
            }
            if ToolFiles.kind(of: url) == .pdf {
                let doc = try ToolPDF.open(url, password: passwords[url])
                guard doc.allowsCopying else {
                    throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("This PDF does not allow text copying.", table: "Tools"))
                }
                guard doc.pageCount > 0, doc.pageCount <= NativeFileLimits.pages else {
                    throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("Text extraction supports 1–200 pages. Nothing was exported.", table: "Tools"))
                }
                for index in 0..<doc.pageCount {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: index) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
                    let embedded = (TextReader.orderedText(page) ?? page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !embedded.isEmpty { try append(embedded, page: index + 1, ocr: false) }
                    // Scans sometimes carry only a page number in the text layer. Preserve that text and also
                    // recognize the page, labelling the two sources separately rather than dropping either.
                    if embedded.count < 15 {
                        guard let image = TextReader.render(page) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
                        try append(try await recognize(image, url: url), page: index + 1, ocr: true)
                    }
                }
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
                try NativeFileLimits.checkImage(source, url: url)
                guard let image = ToolImages.thumbnail(source, maxPixel: 3000) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
                try append(try await recognize(image, url: url), page: 1, ocr: true)
            }
            try Task.checkCancellation()
            guard hasText else {
                throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("No readable text was found. No text file was created.", table: "Tools"))
            }
            let temp = ResultFile.temp(in: folder)
            defer { try? FileManager.default.removeItem(at: temp) }
            try (sections.joined(separator: "\n\n") + "\n").write(to: temp, atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            return try ResultFile.place(temp, as: ResultNaming.name(for: .extractText, inputs: [url]), in: folder)
        }
        output.note = L("Each page names its source: PDF text or OCR. Check recognized text against the original; layout may differ.", table: "Tools")
        return output
    }

    private static func recognize(_ image: CGImage, url: URL) async throws -> String {
        let operation = TextRecognition(image)
        return try await operation.run(timeoutError: ToolFailure.cannotProcess(name: url.lastPathComponent,
            reason: L("Text recognition took too long. Nothing was exported.", table: "Tools")))
    }
}

/// Vision runs off the concurrency pool; Stop cancels its request rather than waiting for the next page.
private final class TextRecognition: @unchecked Sendable {
    private let image: CGImage
    private let request = VNRecognizeTextRequest()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: DispatchWorkItem?
    init(_ image: CGImage) {
        self.image = image
        request.recognitionLevel = DocumentOCR.layer == .fast ? .fast : .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
    }
    /// Only the caller writes files. A stalled native request may finish later, but it cannot resume twice or
    /// publish partial output after the deadline/Stop. No task group waits for an uncooperative Vision request.
    func run(timeoutError: ToolFailure) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(timeoutError))
                    self?.request.cancel()
                }
                let early = lock.withLock { () -> Result<String, Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    timeout = timer
                    return nil
                }
                if let early { continuation.resume(with: early); return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60, execute: timer)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    guard lock.withLock({ self.result == nil }) else { return }
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        let lines = (request.results ?? []).compactMap { observation -> (CGRect, String)? in
                            observation.topCandidates(1).first.map { (observation.boundingBox, $0.string) }
                        }
                        finish(.success(TextReader.lineRows(lines).joined(separator: "\n")))
                    } catch { finish(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            finish(.failure(CancellationError()))
            request.cancel()
        }
    }

    private func finish(_ value: Result<String, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard result == nil else { return nil }
            result = value
            timeout?.cancel(); timeout = nil
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: value)
    }
}
