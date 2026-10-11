import Foundation

/// Presentation only. The complete source remains in ConversationMessage for copying and drafts.
public struct AnswerDocument: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case paragraph(String), heading(Int, String), item(Int, String, String), quote(String)
        case code(String, String), table([String], [[String]])
        /// A "Quellen:" list of links the model wrote, shown as chips (or left out where Pippa shows its own).
        case sources([SourceLink])
    }
    public struct SourceLink: Equatable, Sendable {
        /// What the model called it ("Deutscher Wetterdienst"); `nil` when it only gave the address.
        public var title: String?
        public var url: URL
        /// "dwd.de" (without "www.")
        public var host: String { Self.site(url) }
        public init(title: String?, url: URL) { self.title = title; self.url = url }
        public static func site(_ url: URL) -> String {
            let host = (url.host ?? "").lowercased()
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }
    public let blocks: [Block]

    public init(_ source: String) {
        let lines = source.components(separatedBy: .newlines)
        var result: [Block] = [], paragraph: [String] = [], index = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let fence = Self.fence(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.1)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; index += 1
                while index < lines.count && !Self.closesFence(lines[index], fence) {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(language, code.joined(separator: "\n")))
                if index < lines.count { index += 1 }
                continue
            }
            if index + 1 < lines.count, let headers = Self.cells(line), let separators = Self.cells(lines[index + 1]),
               headers.count == separators.count, separators.allSatisfy(Self.separator) {
                flush(); var rows: [[String]] = []; index += 2
                while index < lines.count, let cells = Self.cells(lines[index]), cells.count == headers.count {
                    rows.append(cells); index += 1
                }
                result.append(.table(headers, rows)); continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); result.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1))))
            } else if trimmed.hasPrefix("> ") {
                flush(); result.append(.quote(String(trimmed.dropFirst(2))))
            } else if let item = Self.listItem(trimmed) {
                flush(); result.append(.item(min(6, line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2), item.0, item.1))
            } else { paragraph.append(line) }
            index += 1
        }
        flush(); blocks = Self.gatherSources(result)
    }

    /// "Quellen:" (or a heading of that name) followed by list items that each hold a web link becomes one sources block.
    static func gatherSources(_ blocks: [Block]) -> [Block] {
        var result: [Block] = [], index = 0
        while index < blocks.count {
            if Self.isSourcesLabel(blocks[index]) {
                var links: [SourceLink] = [], next = index + 1
                while next < blocks.count, case .item(_, _, let text) = blocks[next], let link = Self.sourceLink(text) {
                    links.append(link); next += 1
                }
                if !links.isEmpty { result.append(.sources(links)); index = next; continue }
            }
            result.append(blocks[index]); index += 1
        }
        return result
    }

    private static func isSourcesLabel(_ block: Block) -> Bool {
        let text: String
        switch block {
        case .paragraph(let value), .heading(_, let value): text = value
        default: return false
        }
        let plain = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        return ["quellen", "quelle", "sources", "source", "links"].contains(plain)
    }

    /// One list item that is a source: "Deutscher Wetterdienst: https://…", "[DWD](https://…)" or just the address.
    static func sourceLink(_ text: String) -> SourceLink? {
        if let markdown = try? NSRegularExpression(pattern: #"^\s*\[([^\]]+)\]\((https?://[^\s)]+)\)\s*$"#),
           let match = markdown.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let titleRange = Range(match.range(at: 1), in: text), let urlRange = Range(match.range(at: 2), in: text),
           let url = WebSourcesCard.webURL(String(text[urlRange])) {
            return SourceLink(title: String(text[titleRange]).replacingOccurrences(of: "*", with: ""), url: url)
        }
        let found = WebSourcesCard.links(in: text)
        guard let url = found.first, Set(found.map(WebSourcesCard.key)).count == 1,
              let first = text.range(of: #"[\[<(]?https?://"#, options: .regularExpression) else { return nil }
        // After the title only the address may follow (bare, <…> or [address](address)), nothing else.
        let rest = text[first.lowerBound...].replacingOccurrences(of: #"https?://[^\s<>()\[\]]+"#, with: "", options: .regularExpression)
        guard rest.trimmingCharacters(in: CharacterSet(charactersIn: " []()<>.,;:")).isEmpty else { return nil }
        let title = text[..<first.lowerBound].replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":–—-")))
        return SourceLink(title: title.isEmpty ? nil : title, url: url)
    }

    private static func fence(_ line: String) -> (Character, Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }

    private static func closesFence(_ line: String, _ opening: (Character, Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let closing = fence(trimmed), closing.0 == opening.0, closing.1 >= opening.1 else { return false }
        return trimmed.dropFirst(closing.1).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return ("•", String(line.dropFirst(2))) }
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits) + ".", String(rest.dropFirst(2)))
    }

    private static func cells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|"), value.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0 { value.removeLast() }
        var cells: [String] = [], cell = "", escaped = false, codeTicks = 0
        let chars = Array(value); var position = 0
        while position < chars.count {
            let char = chars[position]
            if escaped { cell.append("\\"); cell.append(char); escaped = false; position += 1; continue }
            if char == "\\" { escaped = true; position += 1; continue }
            if char == "`" {
                var end = position
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - position
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                cell += String(repeating: "`", count: count); position = end; continue
            }
            if char == "|" && codeTicks == 0 { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(char) }
            position += 1
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells.count > 1 ? cells : nil
    }

    private static func separator(_ cell: String) -> Bool {
        let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return value.count >= 3 && value.allSatisfy { $0 == "-" }
    }

    public static func localFile(_ url: URL, files: [URL]) -> URL? {
        guard (url.isFileURL || (url.scheme == nil && url.path.hasPrefix("/"))),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let candidate = URL(fileURLWithPath: url.path).standardizedFileURL
        return files.first { $0.isFileURL && $0.standardizedFileURL == candidate }
    }

    public static func safeLink(_ url: URL, files: [URL] = []) -> Bool {
        if localFile(url, files: files) != nil { return true }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    public static func inline(_ source: String, files: [URL] = []) -> AttributedString {
        // Images are never fetched or presented as trusted visual evidence.
        if source.contains("![") { return AttributedString(source) }
        var value = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        var links: [(Range<AttributedString.Index>, URL)] = []
        for run in value.runs {
            guard let url = run.link else { continue }
            if let previous = links.last, previous.1 == url, previous.0.upperBound == run.range.lowerBound {
                links[links.count - 1] = (previous.0.lowerBound..<run.range.upperBound, url)
            } else { links.append((run.range, url)) }
        }
        for (range, url) in links.reversed() {
            if let file = localFile(url, files: files) {
                value[range].link = file
            } else if safeLink(url) {
                let label = String(value[range].characters).trimmingCharacters(in: .whitespaces)
                // A bare address reads as its site only ("dwd.de"); the whole address stays behind the link.
                if label.lowercased().hasPrefix("http://") || label.lowercased().hasPrefix("https://") || label.lowercased().hasPrefix("www.") {
                    var short = AttributedString(SourceLink.site(url))
                    if let attributes = value[range].runs.first?.attributes { short.mergeAttributes(attributes) }
                    value.replaceSubrange(range, with: short)
                } else if let host = url.host, !label.localizedCaseInsensitiveContains(host) {
                    value.insert(AttributedString(" (\(host))"), at: range.upperBound)
                }
            } else {
                // Show the claimed destination but remove its action.
                value[range].link = nil
                value.insert(AttributedString(" (\(url.absoluteString))"), at: range.upperBound)
            }
        }
        return value
    }
}

/// What the model wrote before its last tool call ("Ich suche jetzt mal …", a question it then answered itself) is
/// narration, not answer. It stays in view while Pippa works and drops out of the finished answer, but only when the
/// text after the tools is a real answer on its own and the text before is short, like an announcement; otherwise
/// everything stays, so nothing said is lost (a summary written before saving it to a file stays).
public enum AnswerNarration {
    /// Shorter than this after the tools ("Erledigt."), the earlier text is kept.
    public static let minimumAnswer = 80
    /// Longer than this before the tools, the earlier text is content, not an announcement.
    public static let maximumNarration = 500

    /// `full`: the whole streamed text; `afterTools`: where the text after the last tool call starts, in UTF-8 bytes.
    public static func finished(_ full: String, afterTools: Int?) -> String {
        let whole = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let afterTools, afterTools > 0, afterTools < full.utf8.count,
              let start = full.utf8.index(full.utf8.startIndex, offsetBy: afterTools, limitedBy: full.utf8.endIndex),
              start.samePosition(in: full.unicodeScalars) != nil else { return whole }
        let tail = full[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        let before = full[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.count >= minimumAnswer && before.count <= maximumNarration ? tail : whole
    }
}
