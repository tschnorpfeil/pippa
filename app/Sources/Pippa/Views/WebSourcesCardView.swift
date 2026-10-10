import AppKit
import PippaCore
import SwiftUI

/// Where an online answer comes from: what was searched for, then one row per page (site, path, "gelesen" when Pi
/// read it). A click opens the page in the browser.
struct WebSourcesCardView: View {
    var card: WebSourcesCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "globe").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(T("Looked up online", table: "Views")).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                if !card.queries.isEmpty {
                    Text(card.queries.map { T("“%@”", table: "Views", $0) }.joined(separator: " · ")).font(.scaled(size: 12)).foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                WebSourceRow(item: item)
            }
            Text(card.footer).font(.scaled(size: 11)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 11)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
    }
}

private struct WebSourceRow: View {
    var item: WebSourcesCard.Item
    private let hoverState = State<Bool>(initialValue: false)

    var body: some View {
        Button { NSWorkspace.shared.open(item.url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.host).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                if let path = item.path {
                    Text(path).font(.scaled(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.read {
                    Text(T("read", table: "Views")).font(.scaled(size: 11, weight: .medium)).foregroundStyle(Theme.ink2).fixedSize()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(hoverState.wrappedValue ? Theme.chatBorder : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverState.wrappedValue = $0 }
        .help(item.url.absoluteString)
        .contextMenu {
            Button(T("Open in browser", table: "Views")) { NSWorkspace.shared.open(item.url) }
            Button(T("Copy", table: "Views")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.host, item.path, item.read ? T("read", table: "Views") : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(T("Open in browser", table: "Views"))
        .accessibilityAddTraits(.isLink)
    }
}
