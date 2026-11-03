import AppKit
import SwiftUI

/// The answer's Markdown as blocks: paragraphs, headings, lists, quotes, code and tables. Small models write all of
/// these; inline-only parsing showed "## Überblick" and "- item" literally.
struct MarkdownText: View {
    var text: String
    /// Marked in the text: dates the model worked out itself (`DateEvidence`).
    var highlights: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.ink)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 17 : level == 2 ? 15.5 : 14.5, weight: .semibold))
                .padding(.top, Space.xs)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(Theme.ink3).monospacedDigit()
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        Text(inline(item.text)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.fill3).frame(width: 3)
                Text(inline(text)).foregroundStyle(Theme.ink2).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            CodeBlock(text: text)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var result = Self.inline(text)
        for mark in highlights where !mark.isEmpty {
            var start = result.startIndex
            while let range = result[start...].range(of: mark) {
                result[range].backgroundColor = Theme.needTint
                result[range].foregroundColor = Theme.need
                start = range.upperBound
            }
        }
        return result
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Code in a neutral inset with a hairline; Copy appears on hover.
private struct CodeBlock: View {
    var text: String
    private let hoverState = State(initialValue: false)
    private let copiedState = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink).lineSpacing(3)
                .padding(.horizontal, Space.l).padding(.vertical, Space.ml)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chatInset, in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedState.wrappedValue = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedState.wrappedValue = false }
            } label: {
                Image(systemName: copiedState.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                    .frame(width: 26, height: 26)
                    .raised(Radius.row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(Space.s)
            .opacity(hoverState.wrappedValue || copiedState.wrappedValue ? 1 : 0)
            .allowsHitTesting(hoverState.wrappedValue)
            .help(copiedState.wrappedValue ? T("Copied", table: "App") : T("Copy", table: "App"))
            .accessibilityLabel(T("Copy", table: "App"))
        }
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
    }
}

/// A table in a hairline frame: a tinted head, every other row softly filled so long rows stay easy to follow, and
/// columns of amounts, dates or percentages set flush right so their digits line up.
private struct MarkdownTable: View {
    var header: [String]
    var rows: [[String]]

    var body: some View {
        let numeric = (0..<header.count).map { Self.isNumeric(column: $0, in: rows) }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, bold: true, trailing: numeric[column])
                    }
                }
                .background(Theme.chatInset)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Rectangle().fill(Theme.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            cell(column < row.count ? row[column] : "", bold: false, trailing: numeric[column])
                        }
                    }
                    .background(index % 2 == 1 ? Theme.chatInset.opacity(0.5) : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func cell(_ text: String, bold: Bool, trailing: Bool) -> some View {
        Text(MarkdownText.inline(text)).font(.system(size: 13, weight: bold ? .semibold : .regular))
            .monospacedDigit()
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .padding(.horizontal, Space.l).padding(.vertical, 7)
            .frame(maxWidth: 280, alignment: trailing ? .trailing : .leading)
            .gridColumnAlignment(trailing ? .trailing : .leading)
    }

    /// Every filled cell of the column is a number: "184,37 €", "62 %", "−3", "1.200". Dates stay left (they read as text).
    static func isNumeric(column: Int, in rows: [[String]]) -> Bool {
        let cells = rows.compactMap { column < $0.count ? $0[column] : nil }
            .map { $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "–" && $0 != "-" }
        guard !cells.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,+-−%€$£¥ \u{00A0}\u{202F}")
        return cells.allSatisfy { cell in
            cell.rangeOfCharacter(from: .decimalDigits) != nil && cell.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable { var text: String; var indent: Int }
    case paragraph(String)
    case heading(Int, String)
    case list([Item], ordered: Bool)
    case quote(String)
    case code(String)
    case table([String], [[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var ordered = false
        var lines = text.components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items, ordered: ordered)); items = [] }
        }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(next) }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let heading = headingLevel(line) {
                flush()
                blocks.append(.heading(heading, String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("|"), let next = lines.first, isTableSeparator(next) {
                flush()
                lines.removeFirst()
                var rows: [[String]] = []
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(row)); lines.removeFirst()
                }
                blocks.append(.table(cells(line), rows))
                continue
            }
            if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = bullet(line) {
                if !paragraph.isEmpty || (!items.isEmpty && ordered) { flush() }
                ordered = false
                items.append(Item(text: item, indent: indent))
                continue
            }
            if let item = numbered(line) {
                if !paragraph.isEmpty || (!items.isEmpty && !ordered) { flush() }
                ordered = true
                items.append(Item(text: item, indent: indent))
                continue
            }
            // A line right after a list item continues it.
            if !items.isEmpty, indent > 0 { items[items.count - 1].text += " " + line; continue }
            if !items.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
