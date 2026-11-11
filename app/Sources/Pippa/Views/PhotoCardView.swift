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
            CardHeader(symbol: "photo.on.rectangle",
                       title: card.query.isEmpty ? T("Newest in Photos", table: "Views") : T("“%@” in Photos", table: "Views", card.query),
                       detail: nil)
                .padding(.bottom, 2)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(card.items, id: \.id) { item in
                    PhotoTile(item: item, previews: card.previews)
                }
            }
            .padding(.horizontal, Space.card)
            if let note = card.truncatedNote {
                Text(note).font(Typo.caption).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.card).padding(.top, Space.m)
            }
            CardFooter(text: card.footer)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}

private struct PhotoTile: View {
    var item: PhotoCard.Item
    var previews: Bool
    // @State is not available without Xcode (macro plugin): storage by hand.
    private let imageState = State<CGImage?>(initialValue: nil)
    private let hoveringState = State(initialValue: false)
    private var image: CGImage? { imageState.wrappedValue }
    private var hovering: Bool { hoveringState.wrappedValue }

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
                        .background(Theme.fill2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(hovering ? Theme.accent : Theme.hairline, lineWidth: hovering ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoveringState.wrappedValue = hovering } }
        .pointerStyle(.link)
        .help(T("Open in Photos", table: "Views"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.label, item.dateLabel].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(T("Open in Photos", table: "Views"))
        .accessibilityAddTraits(.isButton)
        .task(id: item.id) {
            // With PIPPA_DEMO=1 no real library (the ids are invented).
            guard previews, image == nil, ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
            imageState.wrappedValue = await PhotosLibrary.preview(id: item.id, side: 280)?.image
        }
    }

    /// The photo itself in Photos; if Photos can't find it, Photos comes to the front. With PIPPA_DEMO=1 nothing.
    private func open() {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
        let id = item.id
        Task { await PhotosLibrary.show(id: id) }
    }
}
