import Foundation

/// What Pi actually read in an answer, so that the source check (`PiAnswerReview` → `SourceFidelity`) checks against exactly
/// that text and not against Pippa's own, truncated reading state. Otherwise Pippa says "only read part of it" about a file Pi read
/// completely, and marks correct values with "please check".
///
/// Two ways Pi reads:
/// - `read_document` (Pippa's MCP reader): the text of each result, with pages; read completely if all pages are there
///   and no result was truncated (`PippaMCPTurnTools.readDocument`).
/// - Pi's own `read` (text files): the result including Pi's continuation hint ("[Showing lines 1-2000 of 3100 …]",
///   "[12 more lines in file …]"); read completely if the lines read run from 1 to the end.
///
/// If Pi did not read a shown file in this answer (e.g. short texts were already in the message), Pippa's own reading state
/// remains.
public struct PiReadLedger: Sendable, Equatable {
    struct Chunk: Sendable, Equatable {
        var order: Int
        var text: String
    }
    struct File: Sendable, Equatable {
        var chunks: [Chunk] = []
        /// read_document with pages: pages read and page count.
        var pages: Set<Int> = []
        var pageCount: Int?
        var paged = false
        /// A result was truncated (character limit within a page, or within a document without pages).
        var clipped = false
        /// read_document without pages: the beginning read untruncated.
        var wholeUnpaged = false
        /// Pi's `read`: line ranges read (end `Int.max` = to the end of the file) and the line count according to the hint.
        var lines: [ClosedRange<Int>] = []
        var lineCount: Int?
        var viaRead = false

        var complete: Bool {
            if clipped { return false }
            if viaRead { return Self.covers(lines, total: lineCount) }
            if paged { return pageCount.map { n in n > 0 && (1...n).allSatisfy(pages.contains) } ?? false }
            return wholeUnpaged
        }

        static func covers(_ ranges: [ClosedRange<Int>], total: Int?) -> Bool {
            var reach = 0
            for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if r.lowerBound > reach + 1 { return false }
                reach = max(reach, r.upperBound)
            }
            if reach == Int.max { return true }
            guard let total else { return false }
            return reach >= total
        }
    }

    private(set) var files: [String: File] = [:]
    public init() {}

    public var isEmpty: Bool { files.isEmpty }
    public var paths: [String] { files.keys.sorted() }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// A result of `read_document`. `firstPage`/`lastPage` only for documents with pages. `cut`: the text ends in the middle
    /// of the last page (with pages) or in the middle of the document (without pages).
    public mutating func noteDocument(path: String, text: String, firstPage: Int?, lastPage: Int?, pageCount: Int?, cut: Bool) {
        var file = files[Self.key(path)] ?? File()
        file.chunks.append(Chunk(order: firstPage ?? 0, text: text))
        if let firstPage, let lastPage, lastPage >= firstPage {
            file.paged = true
            // A cut-off last page does not count as read.
            let through = cut ? lastPage - 1 : lastPage
            if through >= firstPage { file.pages.formUnion(firstPage...through) }
            if let pageCount { file.pageCount = pageCount }
        } else if (firstPage ?? 1) == 1 {
            if cut { file.clipped = true } else { file.wholeUnpaged = true }
        }
        files[Self.key(path)] = file
    }

    /// A successful result of Pi's own `read`. `arguments`: the arguments as JSON (`path`, `offset`, `limit`).
    public mutating func notePiRead(arguments: String, result: String) {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty else { return }
        let start = max(1, (args["offset"] as? NSNumber)?.intValue ?? 1)
        // Images come as an attachment, not as text; Pi does not read a first line that is too long at all.
        if result.hasPrefix("Read image file") || result.hasPrefix("[Line ") { return }
        var text = result
        var range: ClosedRange<Int> = start...Int.max
        var total: Int?
        if let notice = Self.trailingNotice(result) {
            text = String(result[..<notice.range.lowerBound])
            switch notice.kind {
            case .showing(let from, let to, let of):
                range = from...max(from, to); total = of
            case .more(let nextOffset):
                range = start...max(start, nextOffset - 1)
            }
        }
        var file = files[Self.key(path)] ?? File()
        file.viaRead = true
        file.chunks.append(Chunk(order: start, text: text))
        file.lines.append(range)
        if let total { file.lineCount = total }
        files[Self.key(path)] = file
    }

    enum NoticeKind: Equatable { case showing(from: Int, to: Int, of: Int), more(nextOffset: Int) }

    /// Pi's continuation hint at the end of a `read` result (pi-coding-agent `tools/read.js`).
    static func trailingNotice(_ text: String) -> (range: Range<String.Index>, kind: NoticeKind)? {
        let showing = #"\n\n\[Showing lines (\d+)-(\d+) of (\d+)[^\]]*\]\s*$"#
        let more = #"\n\n\[\d+ more lines in file\. Use offset=(\d+) to continue\.\]\s*$"#
        if let r = text.range(of: showing, options: .regularExpression) {
            let numbers = text[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 3 else { return nil }
            return (r, .showing(from: numbers[0], to: numbers[1], of: numbers[2]))
        }
        if let r = text.range(of: more, options: .regularExpression) {
            let numbers = text[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 2 else { return nil }
            return (r, .more(nextOffset: numbers[1]))
        }
        return nil
    }

    /// Has Pi read `path` completely in this answer? `nil`: not read at all.
    public func readCompletely(_ path: String) -> Bool? { files[Self.key(path)]?.complete }

    /// Pippa's reading state (`LocalEngine.snapshots`: selection/working state first, the last `files.count` are the
    /// shown files), replaced for every file Pi read by exactly what was read.
    public func adjusting(_ snapshots: [DocumentSnapshot], files shown: [URL]) -> [DocumentSnapshot] {
        guard !files.isEmpty, snapshots.count >= shown.count else { return snapshots }
        var result = snapshots
        let first = snapshots.count - shown.count
        for (index, url) in shown.enumerated() {
            guard let file = files[Self.key(url.path)] else {
                // A shown folder: what Pi read inside it (read_document, search_documents hits) counts as partly read
                // source for this folder, not as "only the names".
                let base = Self.key(url.path) + "/"
                let inside = files.filter { $0.key.hasPrefix(base) }.sorted { $0.key < $1.key }
                let text = inside.map { entry in
                    "[\((entry.key as NSString).lastPathComponent)]\n" + entry.value.chunks.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n")
                }.joined(separator: "\n\n")
                guard !inside.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let old = result[first + index]
                result[first + index] = .init(name: old.name, text: text, truncated: true, focused: old.focused, readStatus: .partial)
                continue
            }
            let text = file.chunks.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let old = result[first + index]
            let complete = file.complete
            result[first + index] = .init(name: old.name, text: text, truncated: !complete, focused: old.focused,
                                          readStatus: complete ? .readable : .partial)
        }
        return result
    }
}
