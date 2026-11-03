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
                Text(card.note).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
            Spacer().frame(height: Space.xxs)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}

private struct PreparedFileRow: View {
    var file: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            NativeFilePreviewButton(url: file) {
                HStack(spacing: Space.l) {
                    NativeFileThumbnail(url: file, size: CGSize(width: 52, height: 64))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.row))
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(verbatim: file.lastPathComponent)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(2).truncationMode(.middle)
                        Text(T("Preview", table: "App"))
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "eye").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            HStack(spacing: Space.m) {
                ActionPill(title: T("Open", table: "App")) { NSWorkspace.shared.open(file) }
                ActionPill(title: T("Show in Finder", table: "App")) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, Space.s)
    }
}
