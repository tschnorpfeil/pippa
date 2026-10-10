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
        HStack(spacing: 5) {
            if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
            } else {
                Image(systemName: "macwindow").font(.scaled(size: 12)).accessibilityHidden(true)
            }
            Text(verbatim: text)
                .font(Fonts.hint)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.scaled(size: 9, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Leave out %@. Pippa then knows nothing about it.", table: "Views", app.name))
            .accessibilityLabel(T("Leave out %@", table: "Views", app.name))
        }
        .foregroundStyle(Theme.ink2)
        .padding(.leading, 9)
        .padding(.trailing, 2)
        .frame(maxWidth: 260 * CGFloat(TextScaleStore.current), minHeight: 28, alignment: .leading)
        .background(Theme.fill2, in: Capsule())
        .help(T("Pippa knows you came from here. She reads what’s open only if you ask about it.", table: "Views"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Pippa knows: %@", table: "Views", text))
    }

    private var text: String { app.shortTitle.map { app.name + " · " + $0 } ?? app.name }
}
