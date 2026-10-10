import AppKit
import PippaCore
import SwiftUI

/// A calendar answer as a card: one block per day, each appointment with its calendar's colour, time and title; a click
/// opens it in Calendar. The facts come from code (CalendarDigest), so the card never shows more or less than was read.
struct CalendarCardView: View {
    var card: CalendarCard
    /// Plain text of the same answer, for "Copy"; `nil`: no menu (the card sits under an answer of its own).
    var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(card.title).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                if let range = card.rangeLabel {
                    Text(range).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let empty = card.emptyText {
                Text(empty).font(Fonts.body).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            ForEach(Array(card.days.enumerated()), id: \.offset) { _, day in
                Text(day.label)
                    .font(.scaled(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(day.entries.enumerated()), id: \.offset) { _, entry in
                    CalendarCardRow(entry: entry, showsCalendar: card.showsCalendar)
                }
            }
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
        .contextMenu {
            if let text {
                Button(T("Copy", table: "Views")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}

private struct CalendarCardRow: View {
    var entry: CalendarCard.Entry
    var showsCalendar: Bool
    private let hoverState = State<Bool>(initialValue: false)

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Capsule().fill(color).frame(width: 3, height: 15).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(entry.time)
                    .font(Fonts.hint.monospacedDigit()).foregroundStyle(Theme.ink2)
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.scaled(size: 13.5, weight: .medium)).foregroundStyle(entry.inactive ? Theme.ink3 : Theme.ink)
                        .strikethrough(entry.inactive)
                        .lineLimit(2)
                    let quiet = [entry.note, entry.location].compactMap { $0 }
                    if !quiet.isEmpty {
                        Text(quiet.joined(separator: " · ")).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsCalendar {
                    Text(entry.calendar).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(hoverState.wrappedValue ? Theme.chatBorder : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverState.wrappedValue = $0 }
        .help(T("Open in Calendar", table: "CalendarUI"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.time, entry.title, showsCalendar ? entry.calendar : nil, entry.note, entry.location]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(T("Open in Calendar", table: "CalendarUI"))
        .accessibilityAddTraits(.isButton)
    }

    private var color: Color {
        guard let hex = entry.color, hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return Theme.accent }
        return Color(nsColor: NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                                      blue: CGFloat(value & 0xFF) / 255, alpha: 1))
    }

    /// Calendar shows the appointment itself; if it cannot (an identifier Calendar does not know), Calendar opens.
    private func open() {
        guard DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
        let id = entry.eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.eventID
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
