import AppKit
import PippaCore
import QuickLookThumbnailing
import SwiftUI

/// Files a search found, as a card under the answer: preview, name, folder. A click opens the file; "Show in Finder"
/// selects it in its folder. The list is Pippa's own search result (`message.attachments`), never the model's text;
/// files the answer names come first.
struct FoundFilesCardView: View {
    var files: [URL]
    var answer: String

    var body: some View {
        let all = FoundFiles.ordered(files, answer: answer)
        let shown = all.prefix(FoundFiles.maxRows)
        if !shown.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.on.doc").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(T("Found on this Mac", table: "Views")).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(shown), id: \.self) { file in
                FoundFileRow(file: file)
            }
            Text(all.count > shown.count ? T("Files on this Mac · %lld of %lld", table: "Views", shown.count, all.count)
                                           : T("Files on this Mac", table: "Views"))
                .font(.scaled(size: 11)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 11)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
        }
    }

}

private struct FoundFileRow: View {
    var file: URL
    private let hoverState = State<Bool>(initialValue: false)
    private let thumbnailState = State<NSImage?>(initialValue: nil)

    var body: some View {
        Button { NSWorkspace.shared.open(file) } label: {
            HStack(spacing: 10) {
                Image(nsImage: thumbnailState.wrappedValue ?? NSWorkspace.shared.icon(forFile: file.path))
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: file.lastPathComponent).font(.scaled(size: 13)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: file.deletingLastPathComponent().lastPathComponent).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(hoverState.wrappedValue ? Theme.chatBorder : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverState.wrappedValue = $0 }
        .help(file.path)
        .contextMenu {
            Button(T("Open", table: "Views")) { NSWorkspace.shared.open(file) }
            Button(T("Show in Finder", table: "Views")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        .task(id: file) { thumbnailState.wrappedValue = await Self.thumbnail(file) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(T("%@ in %@", table: "Views", file.lastPathComponent, file.deletingLastPathComponent().lastPathComponent))
        .accessibilityHint(T("Opens the file", table: "Views"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: T("Show in Finder", table: "Views")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    /// Quick Look's preview (pictures, PDFs, documents); `nil` keeps the file's icon.
    private static func thumbnail(_ file: URL) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 34, height: 34), scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
