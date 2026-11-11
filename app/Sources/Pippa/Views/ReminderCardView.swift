import AppKit
import PippaCore
import SwiftUI

/// Open reminders as a card under the answer: title, due date (overdue in the warning colour), list when several are
/// involved. Read only: a click brings Reminders forward, ticking off happens there.
struct ReminderCardView: View {
    var card: ReminderCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(symbol: "checklist", title: card.title, detail: nil)
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                ReminderCardRow(item: item, showsList: card.showsList)
            }
            CardFooter(text: card.footer)
        }
        .resultCard()
        .accessibilityElement(children: .contain)
    }
}

private struct ReminderCardRow: View {
    var item: ReminderCard.Item
    var showsList: Bool
    var body: some View {
        CardRowButton(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "circle").font(Typo.footnote).foregroundStyle(item.overdue ? Theme.need : Theme.ink3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(Typo.callout).foregroundStyle(Theme.ink).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsList, !item.list.isEmpty {
                        Text(item.list).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let due = item.dueLabel {
                    Text(due).font(.scaled(size: 11.5).monospacedDigit()).foregroundStyle(item.overdue ? Theme.need : Theme.ink3).fixedSize()
                }
            }
        }
        .help(T("Open in Reminders", table: "Views"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.dueLabel, item.overdue ? T("overdue", table: "Views") : nil, showsList ? item.list : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(T("Open in Reminders", table: "Views"))
        .accessibilityAddTraits(.isButton)
    }

    /// Reminders has no stable link to one reminder: the app comes forward. With PIPPA_DEMO=1 nothing (no real apps).
    private func open() {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1",
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Integration.reminders.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
}
