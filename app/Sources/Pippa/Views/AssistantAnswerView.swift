import SwiftUI
import PippaCore

/// Native, selectable answer content. No HTML, image loading, or model-defined styling.
struct AssistantAnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(AnswerDocument(text).blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.scaled(size: 15, weight: .regular))
        .lineSpacing(5)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            AnswerDocument.safeLink(url) ? .systemAction : .discarded
        })
    }

    private func inline(_ source: String) -> Text { Text(AnswerDocument.inline(source)) }

    @ViewBuilder private func blockView(_ block: AnswerDocument.Block) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inline(value)
                .font(.scaled(size: level == 1 ? 18 : 16, weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .item(let depth, let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker).foregroundStyle(Theme.ink2).frame(minWidth: 15, alignment: .trailing)
                inline(value).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(depth) * 14).accessibilityElement(children: .combine)
        case .quote(let value):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.hair).frame(width: 2)
                inline(value).foregroundStyle(Theme.ink2).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty { Text(verbatim: language).font(.scaled(size: 11)).foregroundStyle(Theme.ink3) }
                ScrollView(.horizontal) {
                    Text(verbatim: value).font(.scaled(size: 13, design: .monospaced)).lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(Theme.fill2, in: RoundedRectangle(cornerRadius: 8))
        case .table(let headers, let rows):
            ViewThatFits(in: .horizontal) {
                table(headers, rows).frame(minWidth: CGFloat(headers.count) * 150, alignment: .leading)
                tableRecords(headers, rows)
            }
        }
    }

    private func table(_ headers: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, value in inline(value).fontWeight(.medium) }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in inline(value).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }.padding(12).background(Theme.fill2, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tableRecords(_ headers: [String], _ rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty { inline(headers.joined(separator: " · ")).fontWeight(.medium) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        VStack(alignment: .leading, spacing: 2) {
                            inline(header).font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
                            inline(row[index])
                        }.accessibilityElement(children: .combine)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Theme.fill2, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
