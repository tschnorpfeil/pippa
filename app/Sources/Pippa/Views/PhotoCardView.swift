import AppKit
import PippaCore
import SwiftUI

/// Photos a search found, as a grid of previews under the answer; a click opens the photo in Photos. Everything comes
/// from Pippa's own search result (PhotoCard), never from the answer text. Without PhotoKit's permission each tile shows
/// its date instead of the picture, and the click still works.
struct PhotoCardView: View {
    var card: PhotoCard

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "photo.on.rectangle").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(card.query.isEmpty ? T("Newest in Photos", table: "Views") : T("“%@” in Photos", table: "Views", card.query)).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(card.items, id: \.id) { item in
                    PhotoTile(item: item, previews: card.previews)
                }
            }
            .padding(.horizontal, 14)
            if let note = card.truncatedNote {
                Text(note).font(Fonts.hint).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 8)
            }
            Text(card.footer).font(.scaled(size: 11)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 11)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
    }
}

private struct PhotoTile: View {
    var item: PhotoCard.Item
    var previews: Bool
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 2).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "photo").font(.scaled(size: 16)).foregroundStyle(Theme.ink3)
                            if !item.dateLabel.isEmpty {
                                Text(item.dateLabel).font(.scaled(size: 10.5)).foregroundStyle(Theme.ink3)
                                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.chatBorder)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: hovering ? 2 : 0) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(T("Open in Photos", table: "Views"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.label, item.dateLabel].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(T("Open in Photos", table: "Views"))
        .accessibilityAddTraits(.isButton)
        .task(id: item.id) {
            // With PIPPA_DEMO=1 no real library (the ids are invented).
            guard previews, image == nil, DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
            image = await PhotosLibrary.preview(id: item.id, side: 280)?.image
        }
    }

    /// The photo itself in Photos; if Photos can't find it, Photos comes to the front. With PIPPA_DEMO=1 nothing.
    private func open() {
        guard DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
        let id = item.id
        Task { await PhotosLibrary.show(id: id) }
    }
}
