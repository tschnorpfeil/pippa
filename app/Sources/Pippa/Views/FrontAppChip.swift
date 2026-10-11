import AppKit
import PippaCore
import SwiftUI

/// Above the input: the app the person called Pippa from ("Safari · Mietrecht Kaution"), so they see what Pippa knows.
/// Only this label goes along with a message; the content only when the question is about it (`front_read`).
/// The × leaves it out: then nothing of that app goes anywhere.
struct FrontAppChip: View {
    var app: FrontApp
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 17, height: 17).accessibilityHidden(true)
            } else {
                Image(systemName: "macwindow").font(.scaled(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 17, height: 17).background(Theme.accentTint, in: Circle()).accessibilityHidden(true)
            }
            // Name like the source chips under an answer, the window title quieter: it is a hint, not the point.
            (Text(verbatim: app.name).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                + Text(verbatim: app.shortTitle.map { " · " + $0 } ?? "").font(Fonts.hint).foregroundStyle(Theme.ink3))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.scaled(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Leave out %@. Pippa then knows nothing about it.", table: "Views", app.name))
            .accessibilityLabel(T("Leave out %@", table: "Views", app.name))
        }
        .padding(.leading, 5)
        .padding(.trailing, 1)
        .frame(minHeight: 26)
        // Hugs its content up to the cap: a flexible frame alone stretched the chip to the full cap, an empty grey
        // bar that read like a second input field.
        .frame(maxWidth: 260 * CGFloat(TextScaleStore.current), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(Theme.chatCard, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .help(T("Pippa knows you came from here. She reads what’s open only if you ask about it.", table: "Views"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Pippa knows: %@", table: "Views", text))
    }

    private var text: String { app.shortTitle.map { app.name + " · " + $0 } ?? app.name }
}
