import Foundation

/// Presentation only. The complete source remains in ConversationMessage for copying and drafts.
public struct AnswerDocument: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case paragraph(String), heading(Int, String), item(Int, String, String), quote(String)
        case code(String, String), table([String], [[String]])
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
        flush(); blocks = result
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
                let label = String(value[range].characters)
                if let host = url.host, !label.localizedCaseInsensitiveContains(host) {
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
