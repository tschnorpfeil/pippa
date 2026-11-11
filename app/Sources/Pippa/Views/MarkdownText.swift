import AppKit
import PippaCore
import SwiftUI

/// The answer's Markdown as blocks (`MarkdownBlock`). While the answer streams in, only the block still being written
/// is parsed and styled again; finished blocks keep their styled text and SwiftUI skips them.
struct MarkdownText: View {
    var text: String
    /// Marked in the text: dates the model worked out itself (`DateEvidence`).
    var highlights: [String] = []
    /// Sizes and spacing: the chat's reading text, or the smaller rounded text of Pippa Island.
    var style: MarkdownStyle = .chat
    private let renderState = State(initialValue: MarkdownRender())

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(renderState.wrappedValue.blocks(for: text, highlights: highlights)) { block in
                MarkdownBlockView(block: block, style: style).equatable()
            }
        }
        .font(style.body)
        .foregroundStyle(Theme.ink)
        .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The type of an answer. A constant per surface, so blocks never compare it.
struct MarkdownStyle {
    var body: Font
    var heading: (Int) -> Font
    var code: Font
    var cell: Font
    /// Extra space between the lines of a paragraph.
    var lineSpacing: CGFloat
    /// Between paragraphs, lists, tables and code.
    var blockSpacing: CGFloat

    @MainActor static let chat = MarkdownStyle(body: Typo.body, heading: Typo.heading, code: Typo.code, cell: Typo.callout,
                                               lineSpacing: Typo.reading, blockSpacing: Space.l)
    /// Pippa Island: one size, SF Pro Rounded; headings differ by weight only, the panel is 380 pt wide.
    @MainActor static let island = MarkdownStyle(body: .system(size: 13, design: .rounded),
                                                 heading: { _ in .system(size: 13, weight: .semibold, design: .rounded) },
                                                 code: .system(size: 12, design: .monospaced),
                                                 cell: .system(size: 12, design: .rounded),
                                                 lineSpacing: 3, blockSpacing: Space.ml)
}

/// One block with its inline Markdown already styled. `stamp` changes whenever its content does, so comparing two is
/// cheap: a finished block keeps its stamp for good.
struct RenderedBlock: Identifiable, Equatable {
    enum Content {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case list([(text: AttributedString, indent: Int)], ordered: Bool)
        case quote(AttributedString)
        case code(String)
        case table([AttributedString], [[AttributedString]], numeric: [Bool])
        case rule
    }

    let id: Int
    let stamp: Int
    let content: Content

    static func == (a: RenderedBlock, b: RenderedBlock) -> Bool { a.id == b.id && a.stamp == b.stamp }
}

/// Keeps one message's parser and its styled blocks between redraws.
@MainActor
final class MarkdownRender {
    private var stream = MarkdownStream()
    private var restarts = 0
    private var highlights: [String] = []
    private var closed: [RenderedBlock] = []
    private var openSource: [MarkdownBlock] = []
    private var open: [RenderedBlock] = []
    private var nextStamp = 0

    func blocks(for text: String, highlights: [String]) -> [RenderedBlock] {
        stream.update(text)
        if highlights != self.highlights || stream.restarts != restarts {
            self.highlights = highlights
            restarts = stream.restarts
            closed = []
            openSource = []
            open = []
        }
        for index in closed.count..<stream.closed.count {
            closed.append(render(stream.closed[index], id: index))
        }
        if stream.open != openSource || open.first.map({ $0.id != closed.count }) == true {
            openSource = stream.open
            open = stream.open.enumerated().map { render($1, id: closed.count + $0) }
        }
        return closed + open
    }

    private func render(_ block: MarkdownBlock, id: Int) -> RenderedBlock {
        nextStamp += 1
        let content: RenderedBlock.Content
        switch block {
        case .paragraph(let text): content = .paragraph(marked(text))
        case .heading(let level, let text): content = .heading(level, marked(text))
        case .list(let items, let ordered): content = .list(items.map { (marked($0.text), $0.indent) }, ordered: ordered)
        case .quote(let text): content = .quote(marked(text))
        case .code(let text): content = .code(text)
        case .table(let header, let rows):
            content = .table(header.map(MarkdownText.inline), rows.map { $0.map(MarkdownText.inline) },
                             numeric: header.indices.map { MarkdownTable.isNumeric(column: $0, in: rows) })
        case .rule: content = .rule
        }
        return RenderedBlock(id: id, stamp: nextStamp, content: content)
    }

    private func marked(_ text: String) -> AttributedString {
        var result = MarkdownText.inline(text)
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
}

private struct MarkdownBlockView: View, Equatable {
    var block: RenderedBlock
    var style: MarkdownStyle

    nonisolated static func == (a: MarkdownBlockView, b: MarkdownBlockView) -> Bool { a.block == b.block }

    var body: some View {
        switch block.content {
        case .paragraph(let text):
            Text(text).lineSpacing(style.lineSpacing).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text).font(style.heading(level)).padding(.top, Space.xs)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text(verbatim: ordered ? "\(index + 1)." : "•").foregroundStyle(Theme.ink3).monospacedDigit()
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        Text(item.text).lineSpacing(style.lineSpacing).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let text):
            HStack(spacing: Space.ml) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.fill3).frame(width: 3)
                Text(text).foregroundStyle(Theme.ink2).lineSpacing(style.lineSpacing).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            CodeBlock(text: text, font: style.code)
        case .table(let header, let rows, let numeric):
            MarkdownTable(header: header, rows: rows, numeric: numeric, font: style.cell)
        case .rule:
            Divider()
        }
    }
}

/// Code in a neutral inset with a hairline; Copy floats over its corner on hover.
private struct CodeBlock: View {
    var text: String
    var font: Font = Typo.code
    private let hoverState = State(initialValue: false)
    private let copiedState = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let copied = copiedState.wrappedValue
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(font).foregroundStyle(Theme.ink).lineSpacing(3)
                .padding(.horizontal, Space.l).padding(.vertical, Space.ml)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chatInset, in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            Button { CopyButton.copy(text, flag: copiedState) } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, height: 26)
                    .glass(Radius.row, interactive: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(Space.s)
            .opacity(hoverState.wrappedValue || copied ? 1 : 0)
            .allowsHitTesting(hoverState.wrappedValue)
            .help(copied ? T("Copied", table: "App") : T("Copy", table: "App"))
            .accessibilityLabel(T("Copy", table: "App"))
        }
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
    }
}

/// A table in a hairline frame: a tinted head, every other row softly filled so long rows stay easy to follow, and
/// columns of amounts, dates or percentages set flush right so their digits line up.
struct MarkdownTable: View {
    var header: [AttributedString]
    var rows: [[AttributedString]]
    var numeric: [Bool]
    var font: Font = Typo.callout

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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
                            cell(column < row.count ? row[column] : AttributedString(), bold: false, trailing: numeric[column])
                        }
                    }
                    .background(index % 2 == 1 ? Theme.chatInset.opacity(0.5) : .clear)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func cell(_ text: AttributedString, bold: Bool, trailing: Bool) -> some View {
        Text(text).font(bold ? font.weight(.semibold) : font)
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
