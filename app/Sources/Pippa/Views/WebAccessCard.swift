import SwiftUI
import PippaCore

/// Pippa asks before every single request to the web and shows exactly what would be sent (WebAccessGate).
/// If something comes from the person's documents, it is marked, a row warns, and Return means "Not now".
struct WebAccessCard: View {
    let ask: WebAccessAsk
    var decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.kind == .search ? T("Look it up online:", table: "App") : T("Read this page:", table: "App"))
                .font(Fonts.hint).foregroundStyle(Theme.ink2)
            Text(highlighted)
                .font(Fonts.body).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if ask.warns {
                Label(T("Contains text from your documents", table: "App"), systemImage: "exclamationmark.triangle")
                    .font(Fonts.hint).foregroundStyle(Theme.ink)
            } else if ask.redacted {
                Text(T("I left out numbers and personal details.", table: "App"))
                    .font(Fonts.hint).foregroundStyle(Theme.ink3)
            }
            Text(T("Only this goes out, once. Nothing else from this Mac goes along.", table: "App"))
                .font(Fonts.hint).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if ask.warns {
                    Button(T("Not Now", table: "App")) { decide(false) }.pippa(.primary).keyboardShortcut(.defaultAction)
                    Button(T("Look It Up", table: "App")) { decide(true) }.pippa(.quiet)
                } else {
                    Button(T("Look It Up", table: "App")) { decide(true) }.pippa(.primary).keyboardShortcut(.defaultAction)
                    Button(T("Not Now", table: "App")) { decide(false) }.pippa(.quiet)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ask.kind == .search ? T("Look it up online:", table: "App") + " " + ask.shown
                            : T("Read this page:", table: "App") + " " + ask.shown)
    }

    /// "..." around the exact request; pieces from the documents bold and underlined.
    private var highlighted: AttributedString {
        var text = AttributedString("„" + ask.shown + "“")
        for piece in ask.copied {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: piece, options: .caseInsensitive) {
                text[range].font = Fonts.body.bold()
                text[range].underlineStyle = .single
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }
}
