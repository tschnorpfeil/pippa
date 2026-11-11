import AppKit
import PippaCore
import SwiftUI

/// Native file preparation evidence, with a preview and explicit actions for the finished files.
struct PreparedFilesCardView: View {
    var card: PreparedFilesCard

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            CardHeader(symbol: "doc.richtext", title: T("Your PDF is ready", table: "App"),
                       detail: T("%lld pages · %@", table: "App", card.pageCount,
                                 ByteCountFormatter.string(fromByteCount: card.totalBytes, countStyle: .file)))
            ForEach(card.files, id: \.self) { file in
                PreparedFileRow(file: file)
            }
            if !card.note.isEmpty {
                Text(card.note).font(Typo.footnote).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.card)
            }
            Spacer().frame(height: Space.xxs)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}

private struct PreparedFileRow: View {
    var file: URL

    /// One line: thumbnail and name open the preview, the two actions sit beside them.
    var body: some View {
        HStack(spacing: Space.l) {
            NativeFilePreviewButton(url: file) {
                HStack(spacing: Space.l) {
                    NativeFileThumbnail(url: file, size: CGSize(width: 44, height: 56))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.row))
                        .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Theme.hairline, lineWidth: 1))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(verbatim: file.lastPathComponent)
                            .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
                            .lineLimit(2).truncationMode(.middle)
                        Text(T("Preview", table: "App"))
                            .font(Typo.footnote).foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            ActionPill(title: T("Open", table: "App")) { NSWorkspace.shared.open(file) }
            ActionPill(title: T("Show in Finder", table: "App")) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.bottom, Space.s)
    }
}
