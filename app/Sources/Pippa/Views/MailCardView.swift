import AppKit
import PippaCore
import SwiftUI

/// Mails a search found, as a card under the answer: sender and date, subject, the start of the text. A click opens
/// the mail in Mail. Everything comes from Pippa's own search result, never from the answer text.
struct MailCardView: View {
    var card: MailCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(symbol: "envelope", title: title, detail: nil)
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                MailCardRow(item: item)
            }
            Text(card.footer).font(Typo.caption).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 11)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if !card.query.isEmpty { return T("“%@” in Mail", table: "Views", card.query) }
        return card.unread ? T("Unread in Mail", table: "Views") : T("Newest in Mail", table: "Views")
    }
}

private struct MailCardRow: View {
    var item: MailCard.Item
    var body: some View {
        CardRowButton(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.sender).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = item.dateLabel {
                        Text(date).font(.scaled(size: 11.5).monospacedDigit()).foregroundStyle(Theme.ink3).fixedSize()
                    }
                }
                Text(item.subject).font(Typo.callout).foregroundStyle(Theme.ink).lineLimit(1)
                if !item.preview.isEmpty {
                    Text(item.preview).font(Typo.footnote).foregroundStyle(Theme.ink3).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
        .help(T("Open in Mail", table: "Views"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.sender, item.subject, item.dateLabel, item.preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(T("Open in Mail", table: "Views"))
        .accessibilityAddTraits(.isButton)
    }

    /// The mail itself by its Message-ID; without one, Mail opens. With PIPPA_DEMO=1 nothing (no real apps).
    private func open() {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
        if let id = item.messageID, let encoded = "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "message://" + encoded), NSWorkspace.shared.open(url) { return }
        Task { await PippaMCPService.showMail() }
    }
}

/// The cards of one answer, in the order the tools ran. Cards from `arrivingFrom` on came in while the answer was on
/// screen: they arrive one after the other.
struct ResultCardsView: View {
    var cards: [ResultCard]
    var arrivingFrom: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                self.card(card)
                    .arrives(arrivingFrom.map { index >= $0 } ?? false, delay: Double(index - (arrivingFrom ?? 0)) * Theme.stagger)
            }
        }
    }

    @ViewBuilder private func card(_ card: ResultCard) -> some View {
        switch card {
        case .calendar(let calendar): CalendarCardView(card: calendar, text: nil)
        case .mail(let mail) where !mail.items.isEmpty: MailCardView(card: mail)
        case .mail: EmptyView()
        case .photos(let photos) where !photos.items.isEmpty: PhotoCardView(card: photos)
        case .photos: EmptyView()
        case .reminders(let reminders) where !reminders.items.isEmpty: ReminderCardView(card: reminders)
        case .reminders: EmptyView()
        case .web(let web): WebSourcesCardView(card: web)
        case .preparedFiles(let prepared): PreparedFilesCardView(card: prepared)
        }
    }
}
