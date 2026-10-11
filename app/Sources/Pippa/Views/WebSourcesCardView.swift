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
        .resultCard()
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

/// The sources of an answer as small chips, one per site: a click opens the page, the full address is in the tooltip.
/// From Pippa's own record of what was read online, or from a "Quellen:" list the model wrote when there is none.
struct SourceChipsView: View {
    struct Chip: Equatable { var host: String; var url: URL; var title: String? }
    var chips: [Chip]
    var more = 0

    init(chips: [Chip], more: Int = 0) { self.chips = chips; self.more = more }

    /// Pippa's own sources: pages read first, one chip per site across all web cards of the answer.
    init(cards: [WebSourcesCard], limit: Int = 4) {
        let sites = WebSourcesCard.chips(cards, limit: limit)
        chips = sites.shown.map { Chip(host: $0.host, url: $0.url, title: nil) }
        more = sites.more
    }

    var body: some View {
        FlowRow(spacing: 6, maxItemWidth: 220) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in SourceChip(chip: chip) }
            if more > 0 {
                Text(verbatim: "+\(more)").font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 10).frame(minHeight: 26)
                    .overlay { Capsule().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
                    .accessibilityLabel(T("More sources: %lld", table: "Views", more))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Sources", table: "Views"))
    }
}

private struct SourceChip: View {
    var chip: SourceChipsView.Chip
    private let hoverState = State<Bool>(initialValue: false)

    var body: some View {
        Button { NSWorkspace.shared.open(chip.url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.scaled(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 17, height: 17).background(Theme.accentTint, in: Circle())
                Text(chip.host).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 5).padding(.trailing, 11).frame(minHeight: 26)
            .background(hoverState.wrappedValue ? Theme.chatInset : Theme.chatCard, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hoverState.wrappedValue = $0 }
        .help(chip.title.map { $0 + "\n" + chip.url.absoluteString } ?? chip.url.absoluteString)
        .contextMenu {
            Button(T("Open in browser", table: "Views")) { NSWorkspace.shared.open(chip.url) }
            Button(T("Copy", table: "Views")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chip.url.absoluteString, forType: .string)
            }
        }
        .accessibilityLabel(chip.title ?? chip.host)
        .accessibilityHint(T("Open in browser", table: "Views"))
        .accessibilityAddTraits(.isLink)
    }
}
