import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// Text recognition for one page image, shared by reading (TextReader) and the searchable PDF layer (OCRLayer).
/// Classic `VNRecognizeTextRequest` by default; on macOS 26+ optionally Vision's `RecognizeDocumentsRequest`
/// (paragraphs, tables with cells; tables become Markdown), falling back to the classic request when it fails.
public enum DocumentOCR {
    public enum Engine: String, Sendable, CaseIterable {
        /// `VNRecognizeTextRequest`, `.accurate` (macOS 15 path, fallback).
        case accurate
        /// `VNRecognizeTextRequest`, `.fast` (`PIPPA_OCR_FAST=1`, CI runners without a Neural Engine).
        case fast
        /// `RecognizeDocumentsRequest` (macOS 26+).
        case documents
    }

    /// One recognized page: reading-order text (tables as Markdown), the lines with their boxes, and what produced it.
    public struct Page: Sendable {
        public var text: String
        var lines: [OCRLine]
        public var tables: Int
        public var engine: Engine
        public var lineCount: Int { lines.count }
    }

    /// The engine for reading (chat, tools, Thought Line). Classic `.accurate`: measured faster and more exact than the
    /// document request on German letters, invoices and phone photos; the document
    /// request only on `PIPPA_OCR_ENGINE=documents` (macOS 26+), for comparison and table structure.
    public static var preferred: Engine {
        if ProcessInfo.processInfo.environment["PIPPA_OCR_ENGINE"] == Engine.documents.rawValue {
            if #available(macOS 26, *) { return .documents }
        }
        return .accurate
    }

    /// The engine for the searchable text layer: like `preferred`, but `PIPPA_OCR_FAST=1` (CI runners without a Neural
    /// Engine) uses the fast classic request. Reading stays accurate there: its checks need exact text.
    static var layer: Engine {
        ProcessInfo.processInfo.environment["PIPPA_OCR_FAST"] == "1" ? .fast : preferred
    }

    /// Seconds per page before the document request is given up (then the classic request runs).
    static let documentTimeout: TimeInterval = 45

    /// Recognizes one page. Blocks the caller; never throws: a failed document request falls back to the classic one.
    public static func recognize(_ image: CGImage, engine: Engine = preferred) -> Page {
        if engine == .documents, #available(macOS 26, *), let page = recognizeDocument(image) { return page }
        return recognizeClassic(image, level: engine == .fast ? .fast : .accurate)
    }

    // MARK: Classic (macOS 15+)

    static func recognizeClassic(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> Page {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return Page(text: "", lines: [], tables: 0, engine: level == .fast ? .fast : .accurate) }
        let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return OCRLine(text: s, box: obs.boundingBox)
        }
        // Columns (label left, amount right) come back as separate blocks; joined by position into rows so that
        // "SUMME EUR 23,45" stays on one line.
        let text = TextReader.lineRows(lines.map { ($0.box, $0.text) }).joined(separator: "\n")
        return Page(text: text, lines: lines, tables: 0, engine: level == .fast ? .fast : .accurate)
    }

    // MARK: Documents (macOS 26+)

    @available(macOS 26, *)
    static func recognizeDocument(_ image: CGImage) -> Page? {
        let result = ResultBox<DocumentObservation.Container>()
        let input = UncheckedImage(image: image)
        let done = DispatchSemaphore(value: 0)
        // Vision's Swift API is async only. Run it on OCR's own threads, not the shared Swift pool: callers block here
        // (TextReader is synchronous), and blocked pool threads must never be the ones the request needs to finish.
        Task(executorPreference: OCRExecutor.shared) {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
            request.textRecognitionOptions.useLanguageCorrection = true
            request.barcodeDetectionOptions.enabled = false
            if let doc = try? await request.perform(on: input.image).first { result.set(doc.document) }
            done.signal()
        }
        guard done.wait(timeout: .now() + documentTimeout) == .success, let doc = result.get() else { return nil }
        return page(from: doc)
    }

    @available(macOS 26, *)
    static func page(from doc: DocumentObservation.Container) -> Page {
        let lines: [OCRLine] = doc.text.lines.compactMap { line in
            let text = line.transcript
            return text.isEmpty ? nil : OCRLine(text: text, box: line.boundingBox.cgRect)
        }
        var tables: [(box: CGRect, markdown: String)] = []
        for table in doc.tables {
            var cells: [TableCell] = []
            for row in table.rows {
                for cell in row {
                    cells.append(TableCell(row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                                           text: cell.content.text.transcript))
                }
            }
            if let markdown = markdownTable(cells) { tables.append((table.boundingRegion.boundingBox.cgRect, markdown)) }
        }
        return Page(text: layout(lines: lines.map { ($0.box, $0.text) }, tables: tables), lines: lines, tables: tables.count, engine: .documents)
    }

    // MARK: Layout (pure, checked without Vision)

    public struct TableCell: Sendable, Equatable {
        public var row: Int, column: Int, text: String
        public init(row: Int, column: Int, text: String) { self.row = row; self.column = column; self.text = text }
    }

    /// Cells → Markdown table. Only cells Vision found are filled; a spanning cell sits in its first row/column and the
    /// covered positions stay empty. nil for anything smaller than 2 × 2 or without text: then it is plain text.
    public static func markdownTable(_ cells: [TableCell]) -> String? {
        let filled = cells.filter { $0.row >= 0 && $0.column >= 0 }
        guard let rows = filled.map(\.row).max().map({ $0 + 1 }), let columns = filled.map(\.column).max().map({ $0 + 1 }),
              rows >= 2, columns >= 2, rows <= 500, columns <= 50 else { return nil }
        var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
        for cell in filled {
            let text = cell.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespaces)
            grid[cell.row][cell.column] = grid[cell.row][cell.column].isEmpty ? text : grid[cell.row][cell.column] + " " + text
        }
        guard grid.joined().contains(where: { !$0.isEmpty }) else { return nil }
        func line(_ values: [String]) -> String { "| " + values.joined(separator: " | ") + " |" }
        var out = [line(grid[0]), line(Array(repeating: "---", count: columns))]
        out += grid.dropFirst().map(line)
        return out.joined(separator: "\n")
    }

    /// Page text top to bottom: lines outside tables joined into rows like the classic path, each table as one
    /// Markdown block where it stands on the page. Boxes normalized, origin bottom left.
    public static func layout(lines: [(box: CGRect, text: String)], tables: [(box: CGRect, markdown: String)]) -> String {
        func inTable(_ box: CGRect) -> Bool {
            let center = CGPoint(x: box.midX, y: box.midY)
            return tables.contains { $0.box.insetBy(dx: -0.005, dy: -0.005).contains(center) }
        }
        let free = lines.filter { !inTable($0.box) }
        var blocks: [(top: CGFloat, text: String)] = TextReader.positionedRows(free.map { (rect: $0.box, text: $0.text) })
        blocks += tables.map { ($0.box.maxY, "\n" + $0.markdown + "\n") }
        blocks.sort { $0.top > $1.top }
        return blocks.map(\.text).joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }

    // MARK: Session cache

    /// Recognized pages per file content (SHA-256) and page, for this session: the same scan dropped twice, read for
    /// the pill and then for Pi, or put into "Make one PDF" is recognized once.
    static let cache = PageCache()

    final class PageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: Page] = [:]
        private var order: [String] = []
        let limit = 400

        func get(_ key: String) -> Page? { lock.lock(); defer { lock.unlock() }; return pages[key] }
        func set(_ key: String, _ page: Page) {
            lock.lock(); defer { lock.unlock() }
            if pages.updateValue(page, forKey: key) == nil { order.append(key) }
            while order.count > limit { pages[order.removeFirst()] = nil }
        }
        func removeAll() { lock.lock(); pages = [:]; order = []; lock.unlock() }
    }

    /// Content hash of a file (nil if unreadable or over 200 MB).
    static func contentKey(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            total += chunk.count
            if total > 200_000_000 { return nil }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A page recognized before in this session, if any.
    static func cached(contentKey: String?, page index: Int, engine: Engine = preferred) -> Page? {
        contentKey.flatMap { cache.get("\($0)|\(index)|\(engine.rawValue)") }
    }

    /// Recognizes `image` unless the page of this content was recognized before in this session.
    static func recognize(contentKey: String?, page index: Int, engine: Engine = preferred, image: () -> CGImage?) -> Page? {
        if let hit = cached(contentKey: contentKey, page: index, engine: engine) { return hit }
        let key = contentKey.map { "\($0)|\(index)|\(engine.rawValue)" }
        guard let image = image() else { return nil }
        let page = recognize(image, engine: engine)
        if let key, !page.text.isEmpty { cache.set(key, page) }
        return page
    }
}

/// OCR's own threads for Vision's async API (see `DocumentOCR.recognizeDocument`).
final class OCRExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = OCRExecutor()
    private let queue = DispatchQueue(label: "pippa.ocr", qos: .userInitiated, attributes: .concurrent)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

private struct UncheckedImage: @unchecked Sendable { let image: CGImage }
