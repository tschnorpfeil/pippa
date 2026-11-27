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
            // Accounts that did not answer are named, so the card never reads as "every inbox checked".
            CardFooter(text: card.notice.map { card.footer + " · " + $0 } ?? card.footer)
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
        if item.account == nil {
            CardRowButton(action: open) { content }
                .help(T("Open in Mail", table: "Views"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint(T("Open in Mail", table: "Views"))
                .accessibilityAddTraits(.isButton)
        } else {
            // A row from one account: Mail's link could open another account's copy, so it is not a button.
            content
                .padding(.horizontal, Space.ml).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xs)
                .help(T("Find this email in Mail in the account shown. Pippa can’t open this exact copy for you.", table: "Views"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint(T("Find this email in Mail in the account shown. Pippa can’t open this exact copy for you.", table: "Views"))
        }
    }

    private var label: String {
        [item.sender, item.subject, item.account, item.dateLabel, item.preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.sender).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let date = item.dateLabel {
                    Text(date).font(.scaled(size: 11.5).monospacedDigit()).foregroundStyle(Theme.ink3).fixedSize()
                }
            }
            Text(item.subject).font(Typo.callout).foregroundStyle(Theme.ink).lineLimit(1)
            if let account = item.account {
                Text(account).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.head)
            }
            if !item.preview.isEmpty {
                Text(item.preview).font(Typo.footnote).foregroundStyle(Theme.ink3).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// The mail itself by its Message-ID; without one, Mail opens. With PIPPA_DEMO=1 nothing (no real apps).
    private func open() {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
        if item.opensByMessageID, let id = item.messageID, let encoded = "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics),
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
        case .mailDraft(let draft): MailDraftCardView(card: draft)
        case .photos(let photos) where !photos.items.isEmpty: PhotoCardView(card: photos)
        case .photos: EmptyView()
        case .reminders(let reminders) where !reminders.items.isEmpty: ReminderCardView(card: reminders)
        case .reminders: EmptyView()
        case .web(let web): WebSourcesCardView(card: web)
        case .preparedFiles(let prepared): PreparedFilesCardView(card: prepared)
        }
    }
}

/// Expandable preview of an unsent Mail draft created by `mail_draft`: recipient, subject, collapsible draft body,
/// status badge, copy button, and "Open in Mail". Never offers a direct Send button.
struct MailDraftCardView: View {
    var card: MailDraftCard
    private let expandedState: State<Bool>
    private let copiedState = State(initialValue: false)

    init(card: MailDraftCard) {
        self.card = card
        expandedState = State(initialValue: card.status == .needsPaste)
    }

    private var expanded: Bool { expandedState.wrappedValue }
    private var copied: Bool { copiedState.wrappedValue }
    private var needsPaste: Bool { card.status == .needsPaste }
    private var lineCount: Int { card.body.split(separator: "\n", omittingEmptySubsequences: false).count }
    private var isCollapsible: Bool { lineCount > 3 || card.body.count > 160 }
    private var needsScroll: Bool { lineCount > 12 || card.body.count > 700 }

    private var title: String {
        switch card.status {
        case .saved: T("Draft in Mail, not sent", table: "Views")
        case .opened: T("Email open in Mail, not sent", table: "Views")
        case .needsPaste: T("Reply open in Mail — paste text", table: "Views")
        }
    }

    private var badgeText: String {
        needsPaste ? T("Paste in Mail", table: "Views") : T("Not sent", table: "Views")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            metadata
            if needsPaste {
                pasteNote
            }
            if !card.body.isEmpty {
                draftBody
            }
            actions
            CardFooter(text: card.footer)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "envelope.badge")
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(needsPaste ? Theme.need : Theme.ok)
                .frame(width: 22, height: 22)
                .background(needsPaste ? Theme.needTint : Theme.okTint,
                            in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Text(badgeText)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(needsPaste ? Theme.need : Theme.ok)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 2)
                .background(needsPaste ? Theme.needTint : Theme.okTint, in: Capsule())
                .fixedSize()
        }
        .padding(.horizontal, Space.card).padding(.top, Space.l).padding(.bottom, Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var metadata: some View {
        if card.recipient != nil || !card.subject.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let recipient = card.recipient {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(T("To", table: "Views"))
                            .font(Typo.footnote)
                            .foregroundStyle(Theme.ink3)
                        Text(recipient)
                            .font(Typo.callout.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if let address = card.recipientAddress {
                            Text(address)
                                .font(Typo.footnote)
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if !card.subject.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(T("Subject", table: "Views"))
                            .font(Typo.footnote)
                            .foregroundStyle(Theme.ink3)
                        Text(card.subject)
                            .font(Typo.callout)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, Space.card)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.s)
        }
    }

    private var pasteNote: some View {
        Text(T("Mail didn’t confirm the text. Copy it below and paste it into the open reply.", table: "Views"))
            .font(Typo.footnote)
            .foregroundStyle(Theme.need)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.ml)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.needTint.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.horizontal, Space.card)
            .padding(.bottom, Space.s)
    }

    private var draftBody: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Group {
                if expanded {
                    if needsScroll {
                        ScrollView {
                            expandedText
                        }
                        .frame(height: 280)
                    } else {
                        expandedText
                    }
                } else {
                    Text(card.body)
                        .font(Typo.callout)
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Space.ml)
            .padding(.vertical, Space.m)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))

            if isCollapsible {
                Button {
                    withAnimation(Theme.quick) { expandedState.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(expanded ? T("Show less", table: "Views") : T("Show full draft", table: "Views"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.scaled(size: 10, weight: .semibold))
                    }
                    .font(Typo.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.bottom, Space.m)
    }

    private var expandedText: some View {
        Text(card.body)
            .font(Typo.callout)
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: Space.s) {
            if !card.body.isEmpty {
                ActionPill(title: copied ? T("Copied", table: "Views") : T("Copy text", table: "Views"),
                           primary: needsPaste) {
                    copyBody()
                }
            }
            ActionPill(title: T("Open in Mail", table: "Views")) {
                openInMail()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.card)
        .padding(.bottom, Space.xs)
    }

    private func copyBody() {
        CopyButton.copy(card.body, flag: copiedState)
    }

    /// Brings Mail to the front; no-op in demo mode.
    private func openInMail() {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
        Task { await PippaMCPService.showMail() }
    }
}
