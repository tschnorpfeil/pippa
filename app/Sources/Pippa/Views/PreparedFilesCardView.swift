import AppKit
import PippaCore
import SwiftUI

/// A PDF or images Pippa prepared: name, pages, size, and where to find it.
struct PreparedFilesCardView: View {
    var card: PreparedFilesCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(symbol: "doc.richtext", title: T("Your PDF is ready", table: "App"),
                       detail: T("%lld pages · %@", table: "App", card.pageCount,
                                 ByteCountFormatter.string(fromByteCount: card.totalBytes, countStyle: .file)))
            ForEach(card.files, id: \.self) { file in
                HStack(spacing: Space.ml) {
                    CardRowButton(action: { NSWorkspace.shared.open(file) }) {
                        HStack(spacing: Space.m) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Text(verbatim: file.lastPathComponent).font(.scaled(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .help(T("Open", table: "App"))
                    ActionPill(title: T("Show in Finder", table: "App")) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .padding(.trailing, 14)
                }
            }
            Spacer().frame(height: Space.ml)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}
