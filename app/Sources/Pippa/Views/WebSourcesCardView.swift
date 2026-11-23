import AppKit
import PippaCore
import SwiftUI

/// Where an online answer comes from, as one quiet pill: "Looked up on 6 sites" with the sites' letters stacked beside
/// it (they fan out under the pointer). A click opens one small tile per page (path, site, "read" when Pi read it) and
/// what was searched for; a tile opens the page in the browser.
struct WebSourcesCardView: View {
    var card: WebSourcesCard
    @Environment(\.expandsWork) private var expandsWork
    private let openState = State(initialValue: false)
    private let hoverState = State(initialValue: false)

    private var open: Bool { openState.wrappedValue }
    /// One entry per site, in the card's order (pages read first).
    private var sites: [String] {
        var seen = Set<String>()
        return card.items.map(\.host).filter { seen.insert($0).inserted }
    }
    private var title: String {
        sites.count == 1 ? T("Looked up on 1 site", table: "Views") : T("Looked up on %lld sites", table: "Views", sites.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button { toggle() } label: { pill }
                .buttonStyle(.plain)
                .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
                .onAppear { if expandsWork { openState.wrappedValue = true } }
                .help(card.queries.map { T("“%@”", table: "Views", $0) }.joined(separator: " · "))
                .accessibilityLabel(T("Looked up online", table: "Views") + ", " + title)
            // The tiles fade in while this box grows and clips them, like the steps under "Worked for …".
            VStack(alignment: .leading, spacing: 0) {
                if open {
                    VStack(alignment: .leading, spacing: Space.m) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                                WebSourceTile(item: item, number: index + 1, site: sites.firstIndex(of: item.host) ?? 0)
                            }
                        }
                        Text(([card.queries.map { T("“%@”", table: "Views", $0) }.joined(separator: " · ")] + [card.footer])
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Typo.caption).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Opening grows softly; closing is quick, because the conversation below moves up with it.
    private func toggle() {
        let opening = !open
        withAnimation(opening ? Theme.arrive : Theme.leave) { openState.wrappedValue = opening }
    }

    private var pill: some View {
        let hover = hoverState.wrappedValue
        return HStack(spacing: Space.m) {
            Image(systemName: "globe").font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 22).background(Theme.fill, in: Circle())
            Text(title).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
            SiteStack(hosts: Array(sites.prefix(4)), fanned: hover)
            Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.leading, 5).padding(.trailing, Space.l).frame(height: 32)
        .background(Theme.chatCard, in: Capsule())
        .overlay { if hover { Capsule().fill(Theme.rowHover) } }
        .overlay { Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: 1) }
        .contentShape(Capsule())
    }
}

/// Up to four site badges overlapping each other, the first on top; `fanned` (under the pointer) spreads them apart.
struct SiteStack: View {
    var hosts: [String]
    var fanned: Bool

    var body: some View {
        HStack(spacing: fanned ? Space.xxs : -5) {
            ForEach(Array(hosts.enumerated()), id: \.offset) { index, host in
                SiteBadge(host: host, index: index, size: 18).zIndex(Double(-index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One page in the open pill: its path on top, the site and its number (or "read") below. A click opens it.
private struct WebSourceTile: View {
    var item: WebSourcesCard.Item
    var number: Int
    /// The site's place in the stack, for its badge colour.
    var site: Int
    private let hoverState = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button { NSWorkspace.shared.open(item.url) } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(item.path.map(Self.readable) ?? item.host).font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                HStack(spacing: Space.s) {
                    SiteBadge(host: item.host, index: site, size: 14)
                    Text(item.host).font(Typo.caption).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    Text(item.read ? T("read", table: "Views") : "\(number)")
                        .font(Typo.caption.weight(item.read ? .medium : .regular)).monospacedDigit()
                        .foregroundStyle(item.read ? Theme.ink2 : Theme.ink3).fixedSize()
                }
            }
            .padding(.horizontal, Space.ml).padding(.vertical, Space.m)
            .background(Theme.chatCard, in: shape)
            .overlay { if hoverState.wrappedValue { shape.fill(Theme.rowHover) } }
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .pointerStyle(.link)
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

    /// "/deutschland/koeln/morgen.html" reads "deutschland › koeln › morgen".
    static func readable(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if let last = parts.last, let dot = last.lastIndex(of: "."), ["html", "htm", "php", "aspx", "jsp"].contains(last[last.index(after: dot)...].lowercased()) {
            parts[parts.count - 1] = String(last[..<dot])
        }
        let text = parts.filter { !$0.isEmpty }.joined(separator: " › ")
        return text.isEmpty ? path : text
    }
}

/// A site's first letter on a colour of its own, ringed in the card colour so stacked badges stay apart. Pippa loads
/// no favicons: that would ask every site for a file just to draw a list.
struct SiteBadge: View {
    var host: String
    /// The site's place among the sites of one answer: it picks the colour, so up to eight sites never share one and a
    /// site has the same colour in the stack and on its tiles.
    var index: Int
    var size: CGFloat

    /// Eight hues far enough apart that neighbours in a stack read as different sites; white letters on each.
    private static let colors: [Int] = [0x5E6AD2, 0x30A46C, 0xF76B15, 0x8E4EC6, 0x0090FF, 0x12A594, 0xE5484D, 0xAD7F58]

    var body: some View {
        Text(host.first.map { String($0).uppercased() } ?? "·")
            .font(.system(size: size * 0.56, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: Theme.hex(Self.colors[index % Self.colors.count])), in: Circle())
            .overlay { Circle().strokeBorder(Theme.chatCard, lineWidth: 1.5).padding(-1.5) }
    }
}
