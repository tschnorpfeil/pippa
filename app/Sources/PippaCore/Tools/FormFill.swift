import AppKit
import Foundation
import PDFKit

/// Blanks and form fields of a PDF, and a filled copy with the original unchanged. Approach and parts ported from
/// Hob (MIT, see THIRD_PARTY_NOTICES.md). Points with a top-left origin, like Hob.
public enum PDFForm {
    public struct Line: Sendable, Equatable {
        public var text: String
        public var x, y, w, h: Double
        public init(text: String, x: Double, y: Double, w: Double, h: Double) {
            self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    public struct Blank: Sendable, Equatable {
        public enum Kind: String, Sendable { case line, box }
        public var kind: Kind
        public var x, y, w, h: Double
        public init(kind: Kind, x: Double, y: Double, w: Double, h: Double) {
            self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    public struct Page: Sendable, Equatable {
        public var number: Int
        public var width, height: Double
        /// The text was recognized from the page image (a scan). Rotated pages are not recognized and get no blanks.
        public var recognized: Bool
        public var lines: [Line]
        public var blanks: [Blank]
        public init(number: Int, width: Double, height: Double, recognized: Bool, lines: [Line], blanks: [Blank]) {
            self.number = number; self.width = width; self.height = height; self.recognized = recognized
            self.lines = lines; self.blanks = blanks
        }
    }

    public struct Field: Sendable, Equatable {
        public enum Kind: String, Sendable { case text, checkbox, radio, choice, signature }
        public var name: String
        public var kind: Kind
        /// Text; "on" or "off" for a checkbox; the chosen option of a radio group ("" when none is chosen).
        public var value: String
        /// The entries of a choice, the options of a radio group.
        public var options: [String]
        public var page: Int
        public var x, y, w, h: Double
    }

    public struct Labeled: Sendable, Equatable {
        public var id: String
        public var page: Int
        public var label: String
        public var blank: Blank
        public var isSignature: Bool
    }

    public struct Analysis: Sendable, Equatable {
        public var pageCount: Int
        public var pages: [Page]
        /// Every form field of the document, whichever pages were analyzed.
        public var fields: [Field]
        /// Labeled blanks of the analyzed pages (empty when the document has real form fields, as in Hob).
        public var blanks: [Labeled]
    }

    public struct Mark: Sendable, Equatable {
        public var page: Int
        public var x, y, w, h: Double
        public var text: String
        public var check: Bool
    }

    public struct FillPlan: Sendable, Equatable {
        /// Field name (without "f:") → value.
        public var fields: [String: String]
        public var marks: [Mark]
        public var done: [String]
        public var stillEmpty: [String]
    }

    public enum FillProblem: Error, Sendable, Equatable {
        case unknownIDs([String], valid: [String]), wrongKind([String]), signature([String]), nothingToFill
    }

    public static let instructions = "This is a form. To fill it in: unless the person already gave the details, ask once, in one short list, for the answers to these blanks (skip signatures and parts for someone else). Never make up personal details and never sign. Then call mcp__pippa__fill_pdf with path and answers {id: text}; for boxes use \"yes\". German forms: dates as DD.MM.YYYY."
    static let truthy: Set<String> = ["yes", "ja", "y", "j", "x", "true", "on", "checked", "1", "✓", "✔"]
    static let signatureWords = ["unterschrift", "signature", "signatur", "unterzeichn"]
    /// At most this many pages per analysis (Hob reads the first 40).
    static let maxPages = 40
    /// Pixels per point when looking for blanks.
    static let scale = 2.0

    // MARK: Analysis

    /// nil: not an openable, unlocked PDF. `pages` is clamped to the document (at most `maxPages` from its start).
    public static func analyze(_ url: URL, pages: ClosedRange<Int>) -> Analysis? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = attributes.map { facts -> String in
            let size = (facts[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (facts[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(pages.lowerBound)-\(pages.upperBound)"
        }
        if let key, let hit = AnalysisCache.shared.get(key) { return hit }
        guard let document = PDFDocument(url: url),
              !(document.isLocked || document.isEncrypted && !document.unlock(withPassword: "")), document.pageCount > 0 else { return nil }
        let count = document.pageCount
        let lower = min(max(pages.lowerBound, 1), count)
        let upper = max(lower, min(pages.upperBound, count, lower + maxPages - 1))
        let fields = formFields(document)
        // A document with real fields is filled through them; its blanks are never offered, so they are not looked for.
        let fillable = fields.contains { $0.kind != .signature }
        var contentKey: String?
        var keyed = false
        func ocrKey() -> String? {
            if !keyed { contentKey = DocumentOCR.contentKey(url); keyed = true }
            return contentKey
        }
        var analyzed: [Page] = []
        for number in lower...upper {
            guard let page = document.page(at: number - 1) else { continue }
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation != 0
            let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = own.count >= 15 ? ownLines(page, box: box) : []
            var recognized = false
            if lines.isEmpty, !rotated {
                // The session's text recognition, so a page read_document recognized is not recognized again.
                let ocr = DocumentOCR.recognize(contentKey: ocrKey(), page: number - 1, image: { TextReader.render(page) })
                lines = (ocr?.lines ?? []).compactMap { line -> Line? in
                    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let b = line.box
                    return Line(text: text, x: r1(b.minX * box.width), y: r1((1 - b.maxY) * box.height),
                                w: r1(b.width * box.width), h: r1(b.height * box.height))
                }
                recognized = !lines.isEmpty
            }
            let blanks = rotated || fillable ? [] : findBlanks(page, box: box, lines: lines)
            analyzed.append(Page(number: number, width: r1(box.width), height: r1(box.height), recognized: recognized,
                                 lines: lines, blanks: blanks))
        }
        let analysis = Analysis(pageCount: count, pages: analyzed, fields: fields,
                                blanks: fillable ? [] : analyzed.flatMap { label($0) })
        if let key { AnalysisCache.shared.set(key, analysis) }
        return analysis
    }

    /// The PDF's own text lines. A row can hold labels far apart ("Last name" … "First name") and "Name: ______", so
    /// rows are split at wide gaps and around underscores.
    static func ownLines(_ page: PDFPage, box: CGRect) -> [Line] {
        guard let all = page.selection(for: box) else { return [] }
        let text = (page.string ?? "") as NSString
        var out: [Line] = []
        for row in all.selectionsByLine() {
            for piece in pieces(of: row, page: page, text: text) {
                let t = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !piece.rect.isEmpty else { continue }
                out.append(Line(text: t, x: r1(piece.rect.minX - box.minX), y: r1(box.maxY - piece.rect.maxY),
                                w: r1(piece.rect.width), h: r1(piece.rect.height)))
            }
        }
        return out
    }

    /// Parts of one row: its words, joined while they sit close together, with runs of underscores ("Name: ______") as
    /// parts of their own; the whole row when PDFKit gives no usable ranges. Positions come from selections of the
    /// words' ranges, never from `characterBounds(at:)`: that index does not count the line breaks `page.string` and
    /// the selection ranges have, so it slips one character further with every line.
    private static func pieces(of row: PDFSelection, page: PDFPage, text: NSString) -> [(text: String, rect: CGRect)] {
        let whole = [(text: row.string ?? "", rect: row.bounds(for: page))]
        struct Word { var range: NSRange; var rect: CGRect; var underscore: Bool }
        var words: [Word] = []
        var inStep = true
        func isSpace(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        func add(_ range: NSRange, underscore: Bool) {
            guard range.length > 0 else { return }
            // The selection must hold the same characters as the page text, or the positions are not what they seem.
            guard let selection = page.selection(for: range),
                  selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) == text.substring(with: range) else { inStep = false; return }
            let rect = selection.bounds(for: page)
            if rect.width > 0, rect.height > 0 { words.append(Word(range: range, rect: rect, underscore: underscore)) }
        }
        for r in 0..<row.numberOfTextRanges(on: page) {
            let range = row.range(at: r, on: page)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return whole }
            let end = NSMaxRange(range)
            var index = range.location
            while index < end {
                if isSpace(text.character(at: index)) { index += 1; continue }
                var wordEnd = index
                while wordEnd < end && !isSpace(text.character(at: wordEnd)) { wordEnd += 1 }
                // "Name:______" is two parts: two or more underscores are the blank, the word before them its label.
                var start = index, i = index
                while i < wordEnd {
                    var run = i
                    while run < wordEnd && text.character(at: run) == 0x5F { run += 1 }
                    if run - i >= 2 {
                        add(NSRange(location: start, length: i - start), underscore: false)
                        add(NSRange(location: i, length: run - i), underscore: true)
                        start = run
                        i = run
                    } else {
                        i = max(run, i + 1)
                    }
                }
                add(NSRange(location: start, length: wordEnd - start), underscore: false)
                index = wordEnd
            }
        }
        guard inStep else { return whole }
        var parts: [[Word]] = []
        for word in words {
            if let previous = parts.last?.last, !word.underscore, !previous.underscore,
               word.rect.minX - previous.rect.maxX <= max(8, 1.5 * min(word.rect.height, previous.rect.height)),
               abs(word.rect.midY - previous.rect.midY) < max(word.rect.height, previous.rect.height) / 2 {
                parts[parts.count - 1].append(word)
            } else {
                parts.append([word])
            }
        }
        guard parts.count > 1 else { return whole }
        let split = parts.compactMap { part -> (text: String, rect: CGRect)? in
            guard let first = part.first, let last = part.last else { return nil }
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let string = page.selection(for: range)?.string ?? text.substring(with: range)
            return (string, part.dropFirst().reduce(first.rect) { $0.union($1.rect) })
        }
        // Every part must be text of this row; otherwise the character positions are not what they seem.
        let rowText = whole[0].text
        return split.allSatisfy({ rowText.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) ? split : whole
    }

    /// Real form fields (widgets). Radio buttons that share a name are one field with every option.
    static func formFields(_ document: PDFDocument) -> [Field] {
        var out: [Field] = []
        var byName: [String: Int] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                let kind: Field.Kind
                var value = annotation.widgetStringValue ?? ""
                var options: [String] = []
                switch annotation.widgetFieldType {
                case .button:
                    switch annotation.widgetControlType {
                    case .checkBoxControl:
                        kind = .checkbox
                        value = annotation.buttonWidgetState == .onState ? "on" : "off"
                    case .radioButtonControl:
                        kind = .radio
                        value = annotation.buttonWidgetState == .onState ? annotation.buttonWidgetStateString : ""
                        options = [annotation.buttonWidgetStateString]
                    default: continue
                    }
                case .choice:
                    kind = .choice
                    options = annotation.choices ?? []
                case .signature:
                    kind = .signature
                default:
                    kind = .text
                }
                if let existing = byName[name] {
                    if out[existing].kind == .radio, kind == .radio {
                        for option in options where !option.isEmpty && !out[existing].options.contains(option) { out[existing].options.append(option) }
                        if !value.isEmpty { out[existing].value = value }
                    }
                    continue
                }
                byName[name] = out.count
                let b = annotation.bounds
                out.append(Field(name: name, kind: kind, value: value, options: options.filter { !$0.isEmpty }, page: index + 1,
                                 x: r1(b.minX - box.minX), y: r1(box.maxY - b.maxY), w: r1(b.width), h: r1(b.height)))
            }
        }
        return out
    }

    /// What people see next to a field: the nearest words on its left on the same row, else on its right, else its name.
    static func fieldLabel(_ field: Field, pages: [Page]) -> String {
        guard let page = pages.first(where: { $0.number == field.page }) else { return field.name }
        let middle = field.y + field.h / 2
        let row = page.lines.filter { abs($0.y + $0.h / 2 - middle) < 10 }
        let near = row.filter { $0.x + $0.w <= field.x + 4 }.max { $0.x + $0.w < $1.x + $1.w }
            ?? row.filter { $0.x >= field.x + field.w - 2 }.min { $0.x < $1.x }
        let text = near.map { clean($0.text) } ?? ""
        return text.isEmpty ? field.name : text
    }

    // MARK: Blanks in the page image

    /// The page's pixels; the context stays alive while they are read.
    private struct Pixels {
        let bytes: UnsafePointer<UInt8>
        let rowBytes: Int
        let width: Int
        let height: Int
        /// Scanned rules are often mid-grey: dark below R+G+B 3 × 175, as in Hob.
        @inline(__always) func dark(_ x: Int, _ y: Int) -> Bool {
            let i = y * rowBytes + x * 4
            return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 525
        }
    }

    private struct Segment { var y0, y1, x0, x1: Int }
    private struct Run { var x0, x1: Int }

    /// Underlines to write on and small boxes to tick, found in the page drawn at `scale`.
    static func findBlanks(_ page: PDFPage, box: CGRect, lines: [Line]) -> [Blank] {
        let w = Int(Double(box.width) * scale), h = Int(Double(box.height) * scale)
        guard w > 0, h > 0, w <= 10_000, h <= 10_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return [] }
        return withExtendedLifetime(ctx) {
            let pixels = Pixels(bytes: UnsafePointer(data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)),
                                rowBytes: ctx.bytesPerRow, width: w, height: h)
            return lineBlanks(pixels, lines: lines, pageWidth: Double(box.width)) + boxes(pixels, lines: lines)
        }
    }

    private static func lineBlanks(_ px: Pixels, lines: [Line], pageWidth: Double) -> [Blank] {
        let s = scale, w = px.width, h = px.height
        let minRun = Int(28 * s)
        // Horizontal runs per pixel row (small gaps allowed: scans break lines).
        var runs: [(y: Int, x0: Int, x1: Int)] = []
        for y in 0..<h {
            var x = 0
            while x < w {
                if !px.dark(x, y) { x += 1; continue }
                let start = x
                var end = x, gap = 0
                x += 1
                while x < w {
                    if px.dark(x, y) { end = x; gap = 0 } else { gap += 1; if gap > 2 { break } }
                    x += 1
                }
                if end - start >= minRun { runs.append((y, start, end)) }
            }
        }
        // Runs from neighbouring rows are one line.
        var segments: [Segment] = []
        for r in runs {
            if let i = segments.lastIndex(where: { r.y - $0.y1 <= 1 && r.y >= $0.y0
                && Double(min($0.x1, r.x1) - max($0.x0, r.x0)) > Double(min(r.x1 - r.x0, $0.x1 - $0.x0)) * 0.7 }) {
                segments[i] = Segment(y0: segments[i].y0, y1: r.y, x0: min(segments[i].x0, r.x0), x1: max(segments[i].x1, r.x1))
            } else {
                segments.append(Segment(y0: r.y, y1: r.y, x0: r.x0, x1: r.x1))
            }
        }
        // Scans break long lines into pieces: join pieces on the same row with small gaps.
        segments.sort { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
        let maxGap = Int(12 * s), rowTolerance = Int(2 * s)
        var changed = true
        while changed {
            changed = false
            var joined: [Segment] = []
            for g in segments {
                if let i = joined.firstIndex(where: { abs($0.y0 - g.y0) <= rowTolerance && max(g.x0 - $0.x1, $0.x0 - g.x1) <= maxGap }) {
                    joined[i] = Segment(y0: min(joined[i].y0, g.y0), y1: max(joined[i].y1, g.y1),
                                        x0: min(joined[i].x0, g.x0), x1: max(joined[i].x1, g.x1))
                    changed = true
                } else {
                    joined.append(g)
                }
            }
            segments = joined
        }
        // A box edge: dark pixels going up or down from the line's end for 8 points or more.
        func verticalAt(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            let reach = Int(8 * s)
            for dx in -2...2 {
                let xx = x + dx
                if xx < 0 || xx >= w { continue }
                var up = 0, down = 0
                var y = y0 - 1
                while y >= 0 && px.dark(xx, y) && up < reach { up += 1; y -= 1 }
                y = y1 + 1
                while y < h && px.dark(xx, y) && down < reach { down += 1; y += 1 }
                if up >= reach || down >= reach { return true }
            }
            return false
        }
        var out: [Blank] = []
        for g in segments {
            let thick = Double(g.y1 - g.y0 + 1) / s
            let x = Double(g.x0) / s, y = Double(g.y0) / s, length = Double(g.x1 - g.x0) / s
            if thick > 4 || length > pageWidth * 0.9 { continue }
            // Box and table borders have sides.
            if verticalAt(g.x0, g.y0, g.y1) && verticalAt(g.x1, g.y0, g.y1) { continue }
            // An underline under words (a heading), not a blank to write on.
            if lines.contains(where: { l in
                let bottom = l.y + l.h
                return y - bottom > -6 && y - bottom < 5 && x >= l.x - 4 && x + length <= l.x + l.w + 4 && !l.text.contains("__")
            }) { continue }
            out.append(Blank(kind: .line, x: r1(x), y: r1(y), w: r1(length), h: r1(thick)))
        }
        return out
    }

    /// Checkboxes: small hollow squares (top and bottom edges of the same length, two sides, light inside).
    private static func boxes(_ px: Pixels, lines: [Line]) -> [Blank] {
        let s = scale, w = px.width, h = px.height
        let minSide = Int(6 * s), maxSide = Int(22 * s)
        var edges: [Int: [Run]] = [:]
        for y in 0..<h {
            var x = 0
            while x < w {
                if !px.dark(x, y) { x += 1; continue }
                let start = x
                while x < w && px.dark(x, y) { x += 1 }
                let length = x - start
                if length >= minSide && length <= maxSide { edges[y, default: []].append(Run(x0: start, x1: x - 1)) }
            }
        }
        let markers = ["•", "□", "☐", "■", "o ", "O ", "0 ", "[ ]"]
        var out: [Blank] = []
        for y in edges.keys.sorted() {
            for top in edges[y] ?? [] {
                let side = top.x1 - top.x0
                // The bottom edge: same span, one side-length lower.
                guard (y + side - 2...y + side + 2).contains(where: { yb in
                    (edges[yb] ?? []).contains { abs($0.x0 - top.x0) <= 2 && abs($0.x1 - top.x1) <= 2 }
                }) else { continue }
                let yb = y + side
                var sides = 0, inside = 0, insideLight = 0
                for yy in y...min(yb, h - 1) {
                    let left = (top.x0...top.x0 + 2).contains { px.dark($0, yy) }
                    let right = (top.x1 - 2...top.x1).contains { px.dark($0, yy) }
                    if left && right { sides += 1 }
                }
                let m = max(2, side / 4)
                if yb - m > y + m && top.x1 - m > top.x0 + m {
                    for yy in (y + m)..<(yb - m) {
                        for xx in (top.x0 + m)..<(top.x1 - m) { inside += 1; if !px.dark(xx, yy) { insideLight += 1 } }
                    }
                }
                guard Double(sides) >= Double(side) * 0.8, inside > 0, Double(insideLight) / Double(inside) > 0.6 else { continue }
                let bx = Double(top.x0) / s, by = Double(y) / s, bw = Double(side) / s
                if out.contains(where: { abs($0.x - bx) < 4 && abs($0.y - by) < 4 }) { continue }
                // Letters like "o" or "D" inside a line of text aren't boxes (recognition may read a box at a line's start as "•").
                let cx = bx + bw / 2, cy = by + bw / 2
                if lines.contains(where: { l in
                    guard cx > l.x + 2 && cx < l.x + l.w - 2 && cy > l.y && cy < l.y + l.h else { return false }
                    let atStart = cx < l.x + bw + 3 && markers.contains { l.text.hasPrefix($0) }
                    return !atStart
                }) { continue }
                out.append(Blank(kind: .box, x: r1(bx), y: r1(by), w: r1(bw), h: r1(bw)))
            }
        }
        return out
    }

    // MARK: Labels (port of Hob's labelBlanks)

    /// What each blank is for, from the words around it: a label on its left, a caption under the line, a column header
    /// above it, or the words next to a checkbox. Lines with no words around them are borders or section rules, not
    /// blanks. Ids come from this page alone, so they are the same whichever pages were analyzed.
    public static func label(_ page: Page) -> [Labeled] {
        // Labels are a few words; sentences around a line are instructions, and page footers aren't labels either.
        let words = page.lines.filter { line in
            let t = clean(line.text)
            return !t.isEmpty && t.count <= 60 && line.y < page.height * 0.93 && !isFooter(t)
        }
        let blanks = ordered(page.blanks)
        let lineIndices = blanks.indices.filter { blanks[$0].kind == .line }
        // A caption: small text right under a line (Last name, Date, Signature).
        func captionOf(_ b: Blank) -> Int? {
            words.indices.first { i in
                let l = words[i]
                return l.y >= b.y - 3 && l.y <= b.y + 16 && l.x >= b.x - 8 && l.x <= b.x + b.w * 0.6 && l.w <= b.w * 0.8
            }
        }
        let captions = Set(lineIndices.compactMap { captionOf(blanks[$0]) })
        var found: [(blank: Blank, label: String)] = []
        // A table row's name, shared by every blank on that row.
        var rowLabel: [Int: String] = [:]
        for (index, b) in blanks.enumerated() {
            var parts: [String] = []
            if b.kind == .box {
                let cy = b.y + b.h / 2
                let right = words.filter { $0.y < cy && $0.y + $0.h > cy && $0.x >= b.x - 3 && $0.x - (b.x + b.w) < 40 }.min { $0.x < $1.x }
                let left = words.filter { $0.y < cy && $0.y + $0.h > cy && $0.x + $0.w <= b.x + 2 && b.x - ($0.x + $0.w) < 60 }.max { $0.x < $1.x }
                let t = clean((right ?? left)?.text ?? "")
                if !t.isEmpty { parts.append(t) }
            } else {
                // On the same row, ending before the blank, with no other blank in between.
                let left = words.indices.filter { i in
                    let l = words[i]
                    return l.y + l.h >= b.y - 18 && l.y + l.h <= b.y + 6 && l.x + l.w <= b.x + 8 && b.x - (l.x + l.w) <= 320
                        && !captions.contains(i)
                }.filter { i in
                    let l = words[i]
                    return !lineIndices.contains { o in
                        o != index && abs(blanks[o].y - b.y) < 6 && blanks[o].x >= l.x + l.w - 4 && blanks[o].x + blanks[o].w <= b.x + 4
                    }
                }.max { words[$0].x + words[$0].w < words[$1].x + words[$1].w }
                let previous = lineIndices.filter { o in o != index && abs(blanks[o].y - b.y) < 6 && blanks[o].x + blanks[o].w <= b.x + 4 }
                    .max { blanks[$0].x < blanks[$1].x }
                let row = left.map { clean(words[$0].text) } ?? previous.flatMap { rowLabel[$0] }
                if let row, !row.isEmpty { parts.append(row); rowLabel[index] = row }
                if let caption = captionOf(b) {
                    parts.append(clean(words[caption].text))
                } else if let above = words.indices.filter({ i in
                    let l = words[i]
                    return l.y + l.h <= b.y - 4 && b.y - l.y <= 130 && overlap(l.x, l.w, b.x, b.w) >= min(l.w, b.w) * 0.5 && !captions.contains(i)
                }).max(by: { words[$0].y < words[$1].y }) {
                    // A column header: the nearest words above, with only blanks of the same column in between.
                    let a = words[above]
                    let between = words.indices.contains { i in
                        i != above && words[i].y > a.y + a.h - 2 && words[i].y + words[i].h < b.y && overlap(words[i].x, words[i].w, b.x, b.w) > 0
                    }
                    // Blanks stacked in the same column under it count as part of the column.
                    let stacked = lineIndices.contains { o in
                        o != index && blanks[o].y < b.y - 4 && blanks[o].y > a.y && overlap(blanks[o].x, blanks[o].w, b.x, b.w) >= b.w * 0.7
                            && abs(blanks[o].w - b.w) < b.w * 0.3
                    }
                    if !between && (!(row ?? "").isEmpty || stacked || b.y - a.y <= 60) { parts.append(clean(a.text)) }
                }
            }
            // A page-wide rule is a divider unless something on its left asks for an answer (or a label sits just above
            // its start: "1. Employee's Name" over a writing line).
            let titled = b.kind == .line && words.contains { l in l.y + l.h <= b.y && b.y - l.y < 45 && abs(l.x - b.x) < 20 }
            if b.kind == .line && b.w > page.width * 0.75 && rowLabel[index] == nil && !titled { continue }
            var label = parts.filter { !$0.isEmpty }.joined(separator: " / ")
            if label.isEmpty && b.kind == .line {
                // More lines for the blank above (address line 2, 3).
                if let up = found.filter({ $0.blank.kind == .line && abs($0.blank.x - b.x) < 8 && b.y - $0.blank.y > 4 && b.y - $0.blank.y < 45 })
                    .max(by: { $0.blank.y < $1.blank.y }) {
                    let (base, number) = continuation(up.label)
                    label = "\(base) (line \(number + 1))"
                }
            }
            // "(1)" or "_" alone doesn't say what goes there.
            if letters(label) >= 3 { found.append((b, label)) }
        }
        // Ids say what they are ("p5:home-phone"), so an answer put in the wrong blank stands out.
        var used: [String: Int] = [:]
        var taken = Set<String>()
        return found.map { item -> Labeled in
            let base = "p\(page.number):" + slug(item.label)
            var n = used[base] ?? 0
            var id: String
            repeat { n += 1; id = n == 1 ? base : "\(base)-\(n)" } while taken.contains(id)
            used[base] = n
            taken.insert(id)
            return Labeled(id: id, page: page.number, label: item.label, blank: item.blank, isSignature: isSignature(item.label))
        }
    }

    /// Top to bottom; blanks less than 4 points apart are one row, left to right.
    private static func ordered(_ blanks: [Blank]) -> [Blank] {
        var rows: [[Blank]] = []
        for blank in blanks.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if let first = rows.last?.first, abs(first.y - blank.y) < 4 { rows[rows.count - 1].append(blank) } else { rows.append([blank]) }
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
    }

    private static func overlap(_ ax: Double, _ aw: Double, _ bx: Double, _ bw: Double) -> Double {
        min(ax + aw, bx + bw) - max(ax, bx)
    }

    /// "Home Address (line 2)" → ("Home Address", 2); without a line number the label itself is line 1.
    private static func continuation(_ label: String) -> (String, Int) {
        guard let range = label.range(of: #" \(line (\d+)\)$"#, options: .regularExpression) else { return (label, 1) }
        let number = Int(label[range].filter(\.isNumber)) ?? 1
        return (String(label[..<range.lowerBound]), number)
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"^[•□☐■\s]+|^(?:o|O|0|\[ \]) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[_:.\s]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFooter(_ text: String) -> Bool {
        text.range(of: #"^(?:page \d+(?: of \d+)?|seite \d+(?: von \d+)?)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func letters(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    private static func folded(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// "Straße, Hausnummer" → "strasse-hausnummer" (diacritics folded, ß → ss), at most 48.
    static func slug(_ label: String) -> String {
        var s = folded(label).replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        s = String(s.prefix(48))
        while s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? "blank" : s
    }

    private static func isSignature(_ label: String) -> Bool {
        let text = folded(label)
        return signatureWords.contains { text.contains($0) }
    }

    /// An answer id as the model may send it: spaces or Hob's brackets around it ("[p1:name]").
    static func key(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]")))
    }

    // MARK: Answers

    /// "Musterweg 1, 12345 Köln" written on the first line of a blank that has more lines ("Anschrift (line 2)") is
    /// spread over the empty ones, as a person filling it would.
    public static func spreadLines(_ answers: [String: String], blanks: [Labeled]) -> [String: String] {
        var out = Dictionary(answers.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        for first in blanks {
            guard let raw = out[first.id] else { continue }
            let value = raw.split(whereSeparator: \.isNewline).joined(separator: ", ")
            guard !value.isEmpty, first.label.range(of: #" \(line \d+\)$"#, options: .regularExpression) == nil, value.contains(",") else { continue }
            let more = blanks.filter { $0.page == first.page && $0.label.hasPrefix(first.label + " (line ") }
            guard !more.isEmpty, !more.contains(where: { !(out[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let slots = Array(([first] + more).prefix(parts.count))
            for (i, blank) in slots.enumerated() {
                out[blank.id] = i == slots.count - 1 ? parts[i...].joined(separator: ", ") : parts[i]
            }
        }
        return out
    }

    /// Which answer goes where, checked like Hob's fill_pdf: unknown ids, signatures and "yes" on a line are refused
    /// before anything is written.
    public static func plan(_ answers: [String: String], analysis: Analysis) -> Result<FillPlan, FillProblem> {
        var given: [String: String] = [:]
        for (rawID, raw) in answers {
            // Lines of one answer become one line ("Mustermann,\nMax" → "Mustermann, Max").
            let value = String(raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
                .filter { !$0.isEmpty }.joined(separator: ", ").prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = key(rawID)
            if !value.isEmpty, !id.isEmpty { given[id] = value }
        }
        var fields: [String: String] = [:], marks: [Mark] = [], done: [String] = []
        var wrong: [String] = [], signatures: [String] = [], answered = Set<String>(), touched = Set<Int>()
        for field in analysis.fields {
            let id = "f:" + field.name
            guard let value = given[id] else { continue }
            answered.insert(id)
            let label = fieldLabel(field, pages: analysis.pages)
            switch field.kind {
            case .signature:
                signatures.append(id)
            case .radio:
                guard let option = field.options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { wrong.append(id); continue }
                fields[field.name] = option
                done.append("\(id) \(label): \"\(option)\"")
                touched.insert(field.page)
            case .checkbox:
                fields[field.name] = value
                done.append("\(id) \(label): " + (truthy.contains(value.lowercased()) ? "ticked" : "\"\(value)\""))
                touched.insert(field.page)
            case .text, .choice:
                fields[field.name] = value
                done.append("\(id) \(label): \"\(value)\"")
                touched.insert(field.page)
            }
        }
        for blank in analysis.blanks {
            guard let value = given[blank.id] else { continue }
            answered.insert(blank.id)
            if blank.isSignature { signatures.append(blank.id); continue }
            let b = blank.blank
            if b.kind == .box {
                // Anything but a yes leaves a box empty.
                guard truthy.contains(value.lowercased()) else { continue }
                marks.append(Mark(page: blank.page, x: b.x, y: b.y, w: b.w, h: b.h, text: "X", check: true))
                done.append("\(blank.id) \(blank.label): ticked")
            } else {
                // "yes" on a line meant for writing is almost always a box answer put in the wrong place.
                if ["yes", "ja", "no", "nein"].contains(value.lowercased()) { wrong.append(blank.id); continue }
                marks.append(Mark(page: blank.page, x: b.x, y: b.y, w: b.w, h: b.h, text: value, check: false))
                done.append("\(blank.id) \(blank.label): \"\(value)\"")
            }
            touched.insert(blank.page)
        }
        let unknown = given.keys.filter { !answered.contains($0) }.sorted()
        if !unknown.isEmpty { return .failure(.unknownIDs(unknown, valid: validIDs(analysis))) }
        if !signatures.isEmpty { return .failure(.signature(signatures)) }
        if !wrong.isEmpty { return .failure(.wrongKind(wrong)) }
        if fields.isEmpty && marks.isEmpty { return .failure(.nothingToFill) }
        let emptyFields = analysis.fields.filter { touched.contains($0.page) && given["f:" + $0.name] == nil && $0.value.isEmpty }
            .map { fieldLabel($0, pages: analysis.pages) }
        let emptyBlanks = analysis.blanks.filter { touched.contains($0.page) && given[$0.id] == nil }.map(\.label)
        return .success(FillPlan(fields: fields, marks: marks, done: done, stillEmpty: emptyFields + emptyBlanks))
    }

    static func validIDs(_ analysis: Analysis) -> [String] {
        analysis.fields.map { "f:" + $0.name } + analysis.blanks.map(\.id)
    }

    // MARK: Writing

    /// Writes the copy: field values stay editable; other answers are text boxes the person can move or fix in
    /// Preview. Returns how many answers were placed.
    public static func write(_ plan: FillPlan, source: URL, to destination: URL) throws -> Int {
        guard let document = PDFDocument(url: source),
              !(document.isLocked || document.isEncrypted && !document.unlock(withPassword: "")) else { throw CocoaError(.fileReadCorruptFile) }
        var filled = 0
        for (name, value) in plan.fields.sorted(by: { $0.key < $1.key }) {
            var hit = false
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" && annotation.fieldName == name {
                    switch annotation.widgetFieldType {
                    case .button:
                        switch annotation.widgetControlType {
                        case .radioButtonControl:
                            annotation.buttonWidgetState = annotation.buttonWidgetStateString == value ? .onState : .offState
                        case .checkBoxControl:
                            let on = truthy.contains(value.lowercased()) || value == annotation.buttonWidgetStateString
                            annotation.buttonWidgetState = on ? .onState : .offState
                        default: continue
                        }
                    case .signature: continue
                    default: annotation.widgetStringValue = value
                    }
                    hit = true
                }
            }
            if hit { filled += 1 }
        }
        let ink = NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.35, alpha: 1)
        for mark in plan.marks {
            guard let page = document.page(at: mark.page - 1) else { continue }
            let box = page.bounds(for: .mediaBox)
            var size: CGFloat = mark.check ? CGFloat(min(mark.w, mark.h)) * 0.9 : 10.5
            func font() -> NSFont { NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size) }
            // Long answers shrink to fit the blank.
            if !mark.check && mark.w > 0 {
                while size > 6.5 && (mark.text as NSString).size(withAttributes: [.font: font()]).width > CGFloat(mark.w) - 4 { size -= 0.5 }
            }
            let textWidth = Double((mark.text as NSString).size(withAttributes: [.font: font()]).width)
            let height = Double(size) * 1.35
            // The text box with a top-left origin: centred in a box, or with its baseline on the line.
            let rect = mark.check
                ? CGRect(x: mark.x + mark.w / 2 - textWidth / 2 - 2, y: mark.y + mark.h / 2 - height / 2, width: textWidth + 4, height: height)
                : CGRect(x: mark.x + 2, y: mark.y - 0.5 - height, width: max(textWidth + 6, mark.w), height: height)
            let bounds = CGRect(x: box.minX + rect.minX, y: box.maxY - rect.minY - rect.height, width: rect.width, height: rect.height)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = mark.text
            annotation.font = font()
            annotation.fontColor = ink
            annotation.color = .clear
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.alignment = mark.check ? .center : .left
            annotation.shouldPrint = true
            page.addAnnotation(annotation)
            filled += 1
        }
        guard document.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
        return filled
    }

    // MARK: For read_document (4b)

    /// For read_document (4b): nil unless it is a form (real fields, or at least 2 labeled blanks), so letters stay unchanged.
    public static func modelSummary(_ analysis: Analysis, limit: Int = 80) -> [String: Any]? {
        let fillable = analysis.fields.contains { $0.kind != .signature }
        guard fillable || analysis.blanks.count >= 2 else { return nil }
        let shown = Set(analysis.pages.map(\.number))
        let fields = analysis.fields.filter { shown.contains($0.page) }.map { field -> String in
            let kind = switch field.kind {
            case .text: "text"
            case .checkbox: "box"
            case .radio: "choose one: " + field.options.joined(separator: " | ")
            case .choice: field.options.isEmpty ? "choice" : "choose one: " + field.options.joined(separator: " | ")
            case .signature: "signature, leave empty"
            }
            var line = "f:\(field.name): \(fieldLabel(field, pages: analysis.pages)) (\(kind))"
            if !field.value.isEmpty && field.value != "off" { line += " = \"\(field.value)\"" }
            return line
        }
        let blanks = analysis.blanks.map { blank in
            "\(blank.id): \(blank.label)" + (blank.isSignature ? " (signature, leave empty)" : blank.blank.kind == .box ? " (box)" : "")
        }
        guard !fields.isEmpty || !blanks.isEmpty else { return nil }
        let keptFields = Array(fields.prefix(limit))
        let keptBlanks = Array(blanks.prefix(max(0, limit - keptFields.count)))
        var summary: [String: Any] = [:]
        if !keptBlanks.isEmpty { summary["blanks"] = keptBlanks }
        if !keptFields.isEmpty { summary["fields"] = keptFields }
        if fields.count + blanks.count > limit { summary["truncated"] = true }
        return summary
    }

    static func r1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func r1(_ value: CGFloat) -> Double { r1(Double(value)) }

    /// The same file read twice in a task (read_document, then fill_pdf) is not analyzed twice.
    final class AnalysisCache: @unchecked Sendable {
        static let shared = AnalysisCache()
        private let lock = NSLock()
        private var entries: [String: Analysis] = [:]
        private var order: [String] = []

        func get(_ key: String) -> Analysis? { lock.withLock { entries[key] } }
        func set(_ key: String, _ analysis: Analysis) {
            lock.withLock {
                if entries.updateValue(analysis, forKey: key) == nil { order.append(key) }
                while order.count > 20 { entries[order.removeFirst()] = nil }
            }
        }
    }
}
