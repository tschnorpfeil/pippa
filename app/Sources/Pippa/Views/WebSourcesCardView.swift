import AppKit
import PippaCore
import SwiftUI

/// Where an online answer comes from: what was searched for, then one row per page (site, path, "gelesen" when Pi
/// read it). A click opens the page in the browser.
struct WebSourcesCardView: View {
    var card: WebSourcesCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(symbol: "globe", title: T("Looked up online", table: "Views"),
                       detail: card.queries.isEmpty ? nil : card.queries.map { T("“%@”", table: "Views", $0) }.joined(separator: " · "))
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                WebSourceRow(item: item)
            }
            Text(card.footer).font(Typo.caption).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 11)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}

private struct WebSourceRow: View {
    var item: WebSourcesCard.Item

    var body: some View {
        CardRowButton(action: { NSWorkspace.shared.open(item.url) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.host).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                if let path = item.path {
                    Text(path).font(Typo.footnote).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.read {
                    Text(T("read", table: "Views")).font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink2).fixedSize()
                }
            }
        }
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
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in WebSourceChip(chip: chip) }
            if more > 0 {
                Text(verbatim: "+\(more)").font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 10).frame(minHeight: 26)
                    .overlay { Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: 1) }
                    .accessibilityLabel(T("More sources: %lld", table: "Views", more))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Sources", table: "Views"))
    }
}

private struct WebSourceChip: View {
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
            .background(Theme.chatCard, in: Capsule())
            .overlay { if hoverState.wrappedValue { Capsule().fill(Theme.rowHover) } }
            .overlay { Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .pointerStyle(.link)
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
