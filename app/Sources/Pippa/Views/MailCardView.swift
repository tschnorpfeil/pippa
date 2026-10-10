import AppKit
import PippaCore
import SwiftUI

/// Mails a search found, as a card under the answer: sender and date, subject, the start of the text. A click opens
/// the mail in Mail. Everything comes from Pippa's own search result, never from the answer text.
struct MailCardView: View {
    var card: MailCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "envelope").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(T("“%@” in Mail", table: "Views", card.query)).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().padding(.leading, 14) }
                MailCardRow(item: item)
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

private struct MailCardRow: View {
    var item: MailCard.Item
    private let hoverState = State<Bool>(initialValue: false)

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.sender).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = item.dateLabel {
                        Text(date).font(.scaled(size: 11.5).monospacedDigit()).foregroundStyle(Theme.ink3).fixedSize()
                    }
                }
                Text(item.subject).font(.scaled(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                if !item.preview.isEmpty {
                    Text(item.preview).font(.scaled(size: 12)).foregroundStyle(Theme.ink3).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(hoverState.wrappedValue ? Theme.chatBorder : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverState.wrappedValue = $0 }
        .help(T("Open in Mail", table: "Views"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.sender, item.subject, item.dateLabel, item.preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(T("Open in Mail", table: "Views"))
        .accessibilityAddTraits(.isButton)
    }

    /// The mail itself by its Message-ID; without one, Mail opens. With PIPPA_DEMO=1 nothing (no real apps).
    private func open() {
        guard DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
        if let id = item.messageID, let encoded = "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "message://" + encoded), NSWorkspace.shared.open(url) { return }
        Task { await PippaMCPService.showMail() }
    }
}

/// The cards of one answer, in the order the tools ran.
struct ResultCardsView: View {
    var cards: [ResultCard]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                switch card {
                case .calendar(let calendar): CalendarCardView(card: calendar, text: nil)
                case .mail(let mail): MailCardView(card: mail)
                }
            }
        }
    }
}
